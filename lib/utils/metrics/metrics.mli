(** A counter keeping both a lifetime total and a rolling per-second rate over a
    short window. The built-in transfer counters below are these; anything else
    wanting a throughput figure (the fuse frontend's read/write volume, for one)
    makes its own rather than reimplementing the ring. Unlocked: every caller
    runs on the one thread that drives the program. *)
type counter

val counter : unit -> counter
val count : counter -> int -> unit
val total : counter -> int
val rate : counter -> float

(** Record bytes sent to / received from the backend, and chunks hashed.

    Counted in {!Backend.make}'s wrapper, where a body crosses a link, so a
    write that fans out to three remote stores is three times its size and a
    command going to a store directly is counted like any other. A local store
    is a filesystem and adds nothing. A frontend measuring what it moved on a
    client's behalf is asking a different question and makes its own {!counter}.
*)
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

(** Backend requests retried, requests that timed out (a subset of the retried),
    and requests that reached their caller as a failure. A run that recovered
    from everything still reports what it recovered from. *)
val add_retry : int -> unit

val add_timeout : int -> unit
val add_failure : int -> unit
val retries : unit -> int
val timeouts : unit -> int
val failures : unit -> int

(** Cumulative CPU seconds (user + system) used by this process. *)
val cpu_seconds : unit -> float

(** [private_] plus [swapped] is what a process actually holds: swapped-out
    anonymous pages are still its own, compressed rather than gone, so [rss]
    alone understates it by however much the kernel has pushed out.
    [system_used] and [system_total] are the headroom that decides whether that
    matters. *)
type mem = {
  rss : int;
  private_ : int;
  swapped : int;
  virt : int;
  system_used : int;
  system_total : int;
}

val mem_stats : unit -> mem

(** [(mem_stats ()).rss]. *)
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

(** Words actually reachable, which {!gc_stats} cannot tell you: the heap grows
    in steps and never shrinks, so it answers "how much has been asked for"
    rather than "how much is held". Walks the heap, so sample it on a slow cycle
    rather than beside {!gc_stats}. *)
val live_bytes : unit -> int

(** A byte count as a person reads it ([1.5 GB]). Shared so every report spells
    a size the same way. *)
val human_bytes : int -> string
