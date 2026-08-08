(** Chunk store layout, shared by the backend chunk store and the local cache.
*)

(** Number of leading key characters naming a chunk's shard directory. *)
val fanout : int

(** How many shards a store is split into: every key of {!fanout} hex
    characters. Keys are uniformly hashed, so each shard holds about the same
    share of the store — which is what makes counting one and scaling a fair
    estimate of the whole. *)
val shards : int

(** [shard_name n] is the [n]th shard's directory name, for
    [0 <= n < {!shards}]. *)
val shard_name : int -> string

(** [relative_path key] is ["<shard>/<key>"], the chunk's path relative to the
    store root. The key itself is unchanged: {!Filename.basename} recovers it
    from a listing entry. A key shorter than {!fanout} lands under ["_"]. *)
val relative_path : string -> string

(** Whether a name found in a shard is a chunk, and not a write that was in
    flight when a directory moved or anything else that ended up there.

    Stated as what a chunk key is rather than as what it is not, because a caller
    walking a shard must decide about every name it finds, and a rule that lists
    the exceptions admits whatever nobody thought of — which for a caller copying
    what it finds means copying rubbish, and for one deleting what it does not
    recognise would mean worse. *)
val is_chunk_key : string -> bool
