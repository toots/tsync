(* Transfer and hashing counters. Bytes are counted at the chunk put/get choke
   points, so they are data volume rather than metadata. Each counter keeps a
   cumulative total and a ring of one-second buckets for a rolling rate.

   Unlocked: every caller runs on the one thread that drives the program. *)

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

(* Counted where the retry happens rather than where a caller notices, so a run
   that recovered every time still says how hard it worked to. *)
let requests_c = make ()
let retries_c = make ()
let timeouts_c = make ()
let failures_c = make ()
let add_request n = add requests_c n
let add_retry n = add retries_c n
let add_timeout n = add timeouts_c n
let add_failure n = add failures_c n
let requests () = requests_c.total
let retries () = retries_c.total
let timeouts () = timeouts_c.total
let failures () = failures_c.total

(* Cumulative CPU seconds (user + system); callers diff consecutive samples for a
   percentage. *)
let cpu_seconds () =
  let t = Unix.times () in
  t.Unix.tms_utime +. t.Unix.tms_stime

(* Anonymous pages are what an out-of-memory kill has to take, and swapped ones
   are still anonymous — under zram they are the same pages compressed, so
   resident alone understates what a process is holding by whatever the kernel
   has pushed out. *)
type mem = {
  rss : int;
  private_ : int;
  swapped : int;
  virt : int;
  system_used : int;
  system_total : int;
}

let mem_stats () =
  let m = Mem_usage.info () in
  {
    rss = m.Mem_usage.process_physical_memory;
    private_ = m.Mem_usage.process_private_memory;
    swapped = m.Mem_usage.process_swapped_memory;
    virt = m.Mem_usage.process_virtual_memory;
    system_used = m.Mem_usage.total_used_physical_memory;
    system_total = m.Mem_usage.total_physical_memory;
  }

(* Read next to the RSS above: a large RSS over a small heap is buffers and
   mapped cache reads, not an OCaml leak. *)
type gc = {
  heap_bytes : int;
  top_heap_bytes : int;
  minor_collections : int;
  major_collections : int;
}

let bytes_of_words w = w * (Sys.word_size / 8)

let gc_stats () =
  let s = Gc.quick_stat () in
  {
    heap_bytes = bytes_of_words s.Gc.heap_words;
    top_heap_bytes = bytes_of_words s.Gc.top_heap_words;
    minor_collections = s.Gc.minor_collections;
    major_collections = s.Gc.major_collections;
  }

(* Separate from {!gc_stats} because it walks the heap: the heap a process holds
   grows in steps and shrinks never, so it says nothing about what is retained,
   and the difference between the two is the difference between a leak and an
   allocator that has not given anything back. *)
let live_bytes () = bytes_of_words (Gc.stat ()).Gc.live_words

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
