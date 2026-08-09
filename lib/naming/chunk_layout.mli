(** Chunk store layout, shared by the backend chunk store and the local cache.
*)

(** Number of leading key characters naming a chunk's shard directory. *)
val fanout : int

(** How many shards a store is split into: every key of {!fanout} hex
    characters. Keys are uniformly hashed, so counting one shard and scaling is
    a fair estimate of the whole. *)
val shards : int

(** [shard_name n] is the [n]th shard's directory name, for
    [0 <= n < {!shards}]. *)
val shard_name : int -> string

(** [relative_path key] is ["<shard>/<key>"], the chunk's path relative to the
    store root. The key itself is unchanged: {!Filename.basename} recovers it
    from a listing entry. A key shorter than {!fanout} lands under ["_"]. *)
val relative_path : string -> string

(** Whether a name found in a shard is a chunk, and whether a name found in the
    chunk root is a shard. Both decide whether something met while walking is
    copied or deleted, so both say what the name {i is} — see {!Xxhash.is_hex}.
*)
val is_chunk_key : string -> bool

val is_shard_name : string -> bool
