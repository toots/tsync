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

include module type of struct
  include Collection_intf
end

val string_of_phase : phase -> string

module Over
    (Io : Io.S)
    (_ : Syscalls.S with type 'a io := 'a Io.t)
    (_ : Fs.S with type 'a io := 'a Io.t) : OVER with type 'a io := 'a Io.t
