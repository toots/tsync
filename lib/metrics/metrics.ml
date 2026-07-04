(* Transfer and hashing counters for the stats command. Bytes are counted at
   the chunk put/get choke points (actual data volume, not small metadata);
   hashes count chunks hashed. Each counter keeps a cumulative total (for the
   lifetime mean) and a ring of one-second buckets (for a recent rolling rate).

   Touched only from the Lwt event-loop thread, so no locking is needed. *)

let window = 10 (* seconds in the rolling-rate window *)

type counter = {
  mutable total : int;
  buckets : int array;
  mutable last_sec : int;
}

let make () = { total = 0; buckets = Array.make window 0; last_sec = 0 }
let now_sec () = int_of_float (Unix.gettimeofday ())

(* Clear the buckets for seconds that elapsed since the last update. *)
let advance c sec =
  if sec <> c.last_sec then begin
    let gap = min window (sec - c.last_sec) in
    for i = 1 to gap do
      c.buckets.((c.last_sec + i) mod window) <- 0
    done;
    c.last_sec <- sec
  end

let add c n =
  let sec = now_sec () in
  advance c sec;
  c.buckets.(sec mod window) <- c.buckets.(sec mod window) + n;
  c.total <- c.total + n

let rate c =
  advance c (now_sec ());
  float_of_int (Array.fold_left ( + ) 0 c.buckets) /. float_of_int window

let uploaded_c = make ()
let downloaded_c = make ()
let hashed_c = make ()
let add_uploaded n = add uploaded_c n
let add_downloaded n = add downloaded_c n
let add_hashed n = add hashed_c n
let uploaded () = uploaded_c.total
let downloaded () = downloaded_c.total
let hashed () = hashed_c.total
let upload_rate () = rate uploaded_c
let download_rate () = rate downloaded_c
let hash_rate () = rate hashed_c

(* Cumulative CPU seconds used by this process (user + system). The grapher
   diffs consecutive samples to get CPU%. Cross-platform via stdlib. *)
let cpu_seconds () =
  let t = Unix.times () in
  t.Unix.tms_utime +. t.Unix.tms_stime

(* Current resident set size in bytes. *)
let rss_bytes () = (Mem_usage.info ()).Mem_usage.process_physical_memory
