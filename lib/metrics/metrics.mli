(** Record bytes sent to / received from the backend, and chunks hashed. *)
val add_uploaded : int -> unit

val add_downloaded : int -> unit
val add_hashed : int -> unit

(** Cumulative totals since the daemon started. *)
val uploaded : unit -> int

val downloaded : unit -> int
val hashed : unit -> int

(** Recent rate (per second, averaged over a short window). Bytes/s for
    up/download, chunks/s for hashes. *)
val upload_rate : unit -> float

val download_rate : unit -> float
val hash_rate : unit -> float

(** Cumulative CPU seconds (user + system) used by this process. *)
val cpu_seconds : unit -> float

(** Current resident set size in bytes. *)
val rss_bytes : unit -> int

(** OCaml heap figures, to read next to {!rss_bytes}: a large RSS over a small
    heap is buffers and cache reads rather than OCaml allocation. *)
type gc = {
  heap_bytes : int;
  top_heap_bytes : int;
  minor_collections : int;
  major_collections : int;
}

val gc_stats : unit -> gc

(** The Lwt event loop's load: descriptors watched, timers pending, and the
    blocking-syscall pool ceiling. *)
type lwt = {
  readable_fds : int;
  writable_fds : int;
  timers : int;
  pool_size : int;
}

val lwt_stats : unit -> lwt

(** A byte count as a person reads it ([1.5 GB]). Shared so every report spells
    a size the same way. *)
val human_bytes : int -> string
