(** Where a chunk lives while its store is being collected.

    Collecting chunks moves the old chunk root out of the way and moves the live
    set back under the name every writer already uses — see {!Gc} — so during a
    run a chunk may still be in the space on its way out. The two things that
    have to know are a read, which needs a key that works, and a presence check,
    whose [Some] talks a caller out of writing the chunk at all.

    Nothing here redirects a write, which is the point of collecting in this
    direction: new chunks are written to the surviving space by code that has
    never heard of a run. *)

type phase =
  | Opening  (** The chunk root has not been renamed away yet. *)
  | Marking  (** Live chunks are being moved into the new root. *)
  | Abandoning
      (** Like {!Marking}, but keeping everything rather than only what is
          referenced: the collection was called off. *)
  | Closing
      (** What is left of the old root is the garbage: it is being deleted off
          the replicas and backfill targets and discarded here. *)

(** Enough to resume: which step to redo, and how far it got. [started] is for
    reporting how long a run that is still open has been open.

    [cursor] is the last thing finished, by name and not by position: resuming
    re-lists, and a store that has changed in between yields a different list,
    so an index into it would skip or repeat work. Empty means nothing yet. *)
type run = { phase : phase; started : float; cursor : string }

val string_of_phase : phase -> string

(** Where the space on its way out lives, and where a run records itself: both
    siblings of [chunk_prefix], since opening a run renames the chunk root
    itself away.

    Outside the functor because {!Deferred} is built before there is a {!Conf.S}
    to apply one to, and it needs the from-space prefix as well. *)
val from_prefix : chunk_prefix:string -> string

val marker_key : chunk_prefix:string -> string

module Make (C : Conf.S) : sig
  (** The chunk root a run renames away, and where the run records itself. Both
      sit beside {!Conf.S.chunk_prefix}. *)
  val from_prefix : string

  val marker_key : string

  (** The backend key for a chunk key, in the surviving space. *)
  val key : string -> string

  (** The run in progress, or [None] when the store is idle. Costs one read; a
      marker that will not parse logs and reads as idle. *)
  val read_run : unit -> run option Lwt.t

  val write_run : run -> unit Lwt.t
  val clear_run : unit -> unit Lwt.t

  (** Move a chunk into the surviving space. Idempotent, and a no-op when the
      chunk is not in the space on its way out — so a caller can promote
      whatever it names without first asking where any of it is.

      A move rather than a copy, so what is left behind in the outgoing space is
      the garbage itself; it also asks nothing of the filesystem beyond
      [rename].

      [true] when this call is the one that moved it. A collection opens by
      renaming the whole chunk root aside, so every chunk that already existed
      is promoted exactly once — and rename being atomic, exactly one of any
      racing callers is told so. That is what lets [tsync gc --verify] hash each
      live chunk once, without keeping a set of what it has seen. *)
  val promote : string -> bool Lwt.t

  (** {!promote} every chunk a manifest names, addressed rather than listed so a
      terabyte's worth costs no strings. **Call this immediately before
      publishing that manifest**: it is what makes a run safe, and it is the
      only thing that does.

      The invariant is that a manifest becomes visible only once every chunk it
      names has a name in the surviving space, which covers what a presence
      check cannot: a chunk skipped by an uploader's session memo, a chunk
      written before the run opened and moved by the rename since, an upload
      still in flight when the run opened. *)
  val promote_all : count:int -> (int -> string) -> unit Lwt.t

  (** Whether the store holds this chunk. Falls through to the space on its way
      out so an uploader does not re-send a chunk that is merely waiting to be
      promoted. Deliberately does not promote — {!promote_all} is the one
      mechanism for that. *)
  val head : string -> Backend.file_entry option Lwt.t

  (** The chunk body, from whichever space holds it. Does not promote: reading a
      chunk says nothing about what references it, and whatever does is a root
      the mark reaches anyway.

      {!head} and this both look in the surviving space *first* while a run is
      open, that being where every write lands and where marking moves each live
      chunk, so only a chunk marking has not reached yet costs a second lookup.
      A main that can never be mid-run — every object store — is not routed
      through any of this.

      Raises the way a plain backend read does when the chunk is in no space. *)
  val get : string -> Chunk.t Lwt.t
end
