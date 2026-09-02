(** What a partly filled cache-chunk body holds.

    A body is a run of stored chunks kept as one file, and a read wanting a few
    bytes of one of them has no use for the rest. So a body may hold part of
    each chunk in it, and this is the record of which part: written beside the
    body, and gone once the body is whole — its absence is what says so, which
    is what the body's own name has always meant to {!Chunk_cache}.

    A sweep over the store has to take the two together: a record evicted on its
    own leaves a body with holes that every reader takes for whole, and those
    holes reach a caller as content. *)

(** One interval per stored chunk in the body, in chunk-local coordinates.
    [nothing] is what a body no record is about holds. *)
type held

val nothing : held
val interval : held -> int -> (int * int) option

(** The one range to ask a store for so that [want] is held afterwards, and
    [None] when it already is.

    One interval per chunk and never a set: where the two leave a hole between
    them the hole comes too, and where [want] surrounds what is held the middle
    is fetched again rather than split into a request either side. So the worst
    a read costs is one gap inside one stored chunk, and there is no interval
    algebra to get wrong at three in the morning. *)
val missing : have:(int * int) option -> want:int * int -> (int * int) option

(** Whether a name in the store names a record rather than a body. *)
val is_record : string -> bool

module Make
    (Io : Io.S)
    (_ : Fs.S with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t) : sig
  (** Whether anything stands beside the body at [body], which is what says it
      is not whole. *)
  val recorded : body:string -> bool Io.t

  (** What the body holds, from memory or from beside it. [key] is the body's
      content name, under which this is remembered. *)
  val load : key:string -> body:string -> held Io.t

  (** Forget what was remembered: the bytes under that name are not the ones the
      record was about. *)
  val reset : key:string -> unit

  (** Declare a body incomplete before a byte of it is written. A body with
      nothing beside it is whole, so this has to land first — what survives a
      crash then claims less than the disk holds, and being wrong that way costs
      a re-fetch.

      Says only that the body is incomplete, never what it holds: two reads can
      both find no body and both start it, and the second must not take back
      what the first recorded. *)
  val start : body:string -> unit Io.t

  (** Take in [span] of chunk [i], once those bytes are on the disk.
      Synchronous, so two fills of one body cannot each record what it read
      before the other landed. *)
  val take : key:string -> int -> int * int -> unit

  (** Put what is held beside the body, or take the record away entirely when
      [complete] says every chunk is whole. One writer at a time per body. *)
  val publish :
    key:string -> body:string -> complete:(held -> bool) -> unit Io.t

  (** Take the record away, for a caller replacing or deleting the body it is
      about. [drop_beside] is the same for one holding a path and not a name — a
      sweep over the store, which knows what it deletes only by where it sits.
  *)
  val drop : key:string -> body:string -> unit Io.t

  val drop_beside : body:string -> unit Io.t
end
