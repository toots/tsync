type t = {
  resident : int;
  private_ : int;
  swapped : int;
  anonymous : int option;
  file_backed : int option;
  heap : int;
  top_heap : int;
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
    minor_collections = g.minor_collections;
    major_collections = g.major_collections;
    cpu_seconds = t.tms_utime +. t.tms_stime;
  }

let to_json t =
  let opt k = function Some v -> [(k, `Int v)] | None -> [] in
  `Assoc
    ([
       ("cpuSeconds", `Float t.cpu_seconds);
       ("rssBytes", `Int t.resident);
       ("privateBytes", `Int t.private_);
       ("swappedBytes", `Int t.swapped);
     ]
    @ opt "anonymousBytes" t.anonymous
    @ opt "fileBackedBytes" t.file_backed
    @ [
        ("heapBytes", `Int t.heap);
        ("topHeapBytes", `Int t.top_heap);
        ("minorCollections", `Int t.minor_collections);
        ("majorCollections", `Int t.major_collections);
      ])
