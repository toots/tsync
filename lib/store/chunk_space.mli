(** Where a chunk lives while its store is being collected.

    Collecting chunks moves the old chunk root out of the way and lets the live
    set accumulate under the name every writer already uses — see {!Gc}. So
    during a run a chunk may still be in the space on its way out, and the two
    things that have to know are a read, which needs a key that works, and a
    presence check, whose [Some] talks a caller out of writing the chunk at all.

    Nothing here redirects a write. That is the point of collecting in this
    direction: new chunks are written to the surviving space by code that has
    never heard of a run, so there is no barrier to install and no client to
    keep informed. *)

type phase =
  | Opening  (** The chunk root has not been renamed away yet. *)
  | Marking  (** Live chunks are being given names in the new root. *)
  | Abandoning
      (** Like {!Marking}, but keeping everything rather than only what is
          referenced: the collection was called off and the chunks are being
          given names in the new root regardless. *)
  | Closing  (** The old root is being discarded. *)
  | Reconciling
      (** The main is settled; the replicas and backfill targets are being
          brought into line with it. *)

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
    to apply one to, and it needs the from-space prefix as well. One definition,
    so the two cannot disagree about where the space is. *)
val from_prefix : chunk_prefix:string -> string

val marker_key : chunk_prefix:string -> string

(** The marker's body, for a reader holding it as bytes rather than going
    through a functor — a test dumping a store, a tool inspecting one. [None]
    for anything that is not a marker. *)
val of_string : string -> run option

module Make (C : Conf.S) : sig
  (** The chunk root a run renames away, and where the run records itself. Both
      sit beside {!Conf.S.chunk_prefix}. *)
  val from_prefix : string

  val marker_key : string

  (** Backend keys for a chunk key, in the surviving space and in the space on
      its way out. *)
  val key : string -> string

  val from_key : string -> string

  (** The run in progress, or [None] when the store is idle. Costs one read; a
      marker that will not parse logs and reads as idle. *)
  val read_run : unit -> run option Lwt.t

  val write_run : run -> unit Lwt.t
  val clear_run : unit -> unit Lwt.t

  (** Give a chunk a name in the surviving space. Idempotent, and a no-op when
      the chunk is not in the space on its way out — so a caller can promote
      whatever it names without first asking where any of it is. *)
  val promote : string -> unit Lwt.t

  (** {!promote} every chunk a manifest names. **Call this immediately before
      publishing that manifest**: it is what makes a run safe, and it is the
      only thing that does.

      Hanging survival on the publish rather than on how each chunk was found
      covers what a presence check cannot — a chunk skipped by an uploader's
      session memo, a chunk written before the run opened and moved by the
      rename since, an upload still in flight when the run opened. The invariant
      is that a manifest becomes visible only once every chunk it names has a
      name in the surviving space.

      Costs one marker read when the store is idle. *)
  val promote_all : string list -> unit Lwt.t

  (** Whether the store holds this chunk. Falls through to the space on its way
      out so an uploader does not re-send a chunk that is merely waiting to be
      promoted. Deliberately does not promote — {!promote_all} is the one
      mechanism for that. *)
  val head : string -> Backend.file_entry option Lwt.t

  (** The chunk body, from whichever space holds it. Does not promote: reading a
      chunk says nothing about what references it, and whatever does is a root
      the mark reaches anyway.

      {!head} and this both look in the space on its way out *first* while a run
      is open, since it holds everything that existed when the run started. So a
      read costs one lookup as usual, and only a chunk written during the run
      needs a second. A main that can never be mid-run — every object store — is
      not routed through any of this and keeps the single lookup it always had.

      Raises the way a plain backend read does when the chunk is in no space. *)
  val get : string -> string Lwt.t
end
