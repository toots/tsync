(* Transfer and hashing counters. Bytes are counted at the chunk put/get choke
   points, so they are data volume rather than metadata. Each counter keeps a
   cumulative total and a ring of one-second buckets for a rolling rate.

   Touched only from the Lwt event-loop thread, so no locking. *)

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

(* Exposed so nothing outside reimplements the ring for its own rate. *)
let counter = make
let count = add
let total c = c.total
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

(* Cumulative CPU seconds (user + system); callers diff consecutive samples for a
   percentage. *)
let cpu_seconds () =
  let t = Unix.times () in
  t.Unix.tms_utime +. t.Unix.tms_stime

(* Current resident set size in bytes. *)
let rss_bytes () = (Mem_usage.info ()).Mem_usage.process_physical_memory

(* Read next to the RSS above: a large RSS over a small heap is buffers and
   mapped cache reads, not an OCaml leak. *)
type gc = {
  heap_bytes : int;
  top_heap_bytes : int;
  minor_collections : int;
  major_collections : int;
}

let gc_stats () =
  let s = Gc.quick_stat () in
  let bytes w = w * (Sys.word_size / 8) in
  {
    heap_bytes = bytes s.Gc.heap_words;
    top_heap_bytes = bytes s.Gc.top_heap_words;
    minor_collections = s.Gc.minor_collections;
    major_collections = s.Gc.major_collections;
  }

(* The event loop's load. A server that stopped answering while its CPU is idle
   shows up here as watched descriptors that never drain. *)
type lwt = {
  readable_fds : int;
  writable_fds : int;
  timers : int;
  pool_size : int;
}

let lwt_stats () =
  {
    readable_fds = Lwt_engine.readable_count ();
    writable_fds = Lwt_engine.writable_count ();
    timers = Lwt_engine.timer_count ();
    pool_size = Lwt_unix.pool_size ();
  }

(* Here rather than in the CLI, so every report spells a size the same way. *)
let human_bytes n =
  let units = [| "B"; "KB"; "MB"; "GB"; "TB" |] in
  let v = ref (float_of_int n) and i = ref 0 in
  while !v >= 1024. && !i < Array.length units - 1 do
    v := !v /. 1024.;
    incr i
  done;
  if !i = 0 then Printf.sprintf "%d B" n
  else Printf.sprintf "%.1f %s" !v units.(!i)
