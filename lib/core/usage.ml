type t = {
  resident : int;
  private_ : int;
  swapped : int;
  anonymous : int option;
  file_backed : int option;
  heap : int;
  top_heap : int;
  stacks : int;
  minor_collections : int;
  major_collections : int;
  cpu_seconds : float;
}

external memory_split : unit -> int * int = "tsync_memory_split"
external trim : unit -> unit = "tsync_malloc_trim"

let known n = if n < 0 then None else Some n

let sample () =
  let m = Mem_usage.info () in
  let g = Gc.quick_stat () in
  let anonymous, file_backed = memory_split () in
  let t = Unix.times () in
  let word = Sys.word_size / 8 in
  {
    resident = m.process_physical_memory;
    private_ = m.process_private_memory;
    swapped = m.process_swapped_memory;
    anonymous = known anonymous;
    file_backed = known file_backed;
    heap = g.heap_words * word;
    top_heap = g.top_heap_words * word;
    stacks = g.live_stacks_words * word;
    minor_collections = g.minor_collections;
    major_collections = g.major_collections;
    cpu_seconds = t.tms_utime +. t.tms_stime;
  }

let bytes words = words * (Sys.word_size / 8)
let compacted_heap = Atomic.make 0

let release () =
  Gc.compact ();
  trim ();
  Atomic.set compacted_heap (bytes (Gc.quick_stat ()).heap_words)

let release_if_fragmented ?(free = 16 * 1024 * 1024) () =
  let before = Gc.quick_stat () in
  if bytes before.free_words > free then (
    release ();
    Log.info "compacted the heap from %s to %s (%s live)"
      (Narrate.size (bytes before.heap_words))
      (Narrate.size (bytes (Gc.quick_stat ()).heap_words))
      (Narrate.size (bytes before.live_words)))
  else trim ()

let release_growth = Atomic.make (64 * 1024 * 1024)
let set_release_growth bytes = Atomic.set release_growth bytes

let compact_if_grown () =
  if
    bytes (Gc.quick_stat ()).heap_words
    > Atomic.get compacted_heap + Atomic.get release_growth
  then release ()
