(** Collecting a store's chunks: the record of a run, the move that carries a
    chunk out of the space on its way out, and the lookups that find one while
    both spaces exist.

    A run renames the chunk root aside and lets the live set accumulate under
    the name every writer already uses, so what is left behind once marking is
    done is the garbage itself, named rather than inferred. Nothing here
    redirects a write: a client that has never heard of a run writes to the
    space that survives.

    {!Make.head} and {!Make.get} are what an upload and a download call, and
    they are here because reading a chunk during a run is the same question as
    where the run has put it. Everything else is done by a collection, or owed
    to one. *)

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

module type S = sig
  type 'a io

  (** Re-exported, so a caller binding this functor's result to [Collection]
      can still name what it reads back. *)
  type nonrec phase = phase = Opening | Marking | Abandoning | Closing

  type nonrec run = run = { phase : phase; started : float; cursor : string }

  val string_of_phase : phase -> string

  (** Where this domain's run records itself. *)
  val marker_key : Stored_key.t

  (** The run in progress, or [None] when the store is idle. Costs one read; a
      marker that will not parse logs and reads as idle.

      A lookup does not go through this: it asks whether the marker is there
      at all, since a run it cannot read is still a run. *)
  val read_run : unit -> run option io

  (** Open a run, or move it to its next phase. *)
  val write_run : run -> unit io

  (** The store is idle again. *)
  val clear_run : unit -> unit io

  (** {1 Where a chunk is, while there are two places it could be}

      What every upload and download calls. A caller passes a chunk key and is
      answered; which space held it, and whether a run is open at all, is not
      something it is told. *)

  (** Whether the store holds this chunk, in either space. *)
  val head : string -> Backend.file_entry option io

  (** The chunk's bytes, from whichever space holds it. Does not promote:
      reading a chunk says nothing about what references it, and whatever does
      is a root the mark reaches anyway.

      Both look in the surviving space {i first} while a run is open, that
      being where every write lands and where marking moves each live chunk,
      so only a chunk marking has not reached yet costs a second lookup. A
      main that can never be mid-run — every object store — is not routed
      through any of this. *)
  val get : string -> Bigstring.t io

  (** [length] bytes of the chunk from [offset], over the same spaces. A
      collection is invisible to a reader either way, which is the point of it
      being here rather than at the caller: a range read that only knew about
      the surviving space would fail mid-run where a whole read succeeds. *)
  val get_range : string -> offset:int -> length:int -> Bigstring.t io

  (** {1 Moving them} *)

  (** Move a chunk into the surviving space. Idempotent, and a no-op when the
      chunk is not in the space on its way out — so a caller can promote
      whatever it names without first asking where any of it is.

      A move rather than a copy, so what is left behind in the outgoing space
      is the garbage itself, which is what lets a collection delete by name.
  *)
  val promote : string -> bool io

  (** Promote every chunk of a manifest about to be published, and the one
      thing a writer owes an open run.

      Tying survival to the publish rather than to how each chunk was found
      covers what a presence check cannot: a chunk skipped by an uploader's
      own session memo, a chunk written before the run opened and moved by the
      rename since, an upload still in flight when the run opened.

      A no-op when no run is open. *)
  val promote_all : count:int -> (int -> string) -> unit io
end

(** The shape a consumer takes: {!S} for whichever domain it is applied to. *)
module type OVER = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : S with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (_ : Syscalls.S with type 'a io := 'a Io.t)
    (_ : Fs.S with type 'a io := 'a Io.t) :
  OVER with type 'a io := 'a Io.t
