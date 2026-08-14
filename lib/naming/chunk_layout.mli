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

(** {1 Holding a body against its own name}

    A chunk's key {i is} the hash of its bytes, so a store can check every
    object it takes without being told anything: the name is the expected
    answer. What fails is filed under {!corrupted_prefix}, where any client can
    list it. *)

(** The key a body belongs under. The one place this is composed — an uploader
    publishes it through {!Manifest.chunk_entry_of_body} and a check recomputes
    it here, so the two cannot drift into naming the same bytes differently. *)
val key_of_body : string -> string

(** ["<root>chunks/"] becomes ["<root>corrupted/"]: a sibling of the chunk root,
    the same construction as {!Chunk_space.from_prefix}. Sibling rather than
    child so a collection renaming the chunk root away leaves markers alone, and
    so nothing walking chunks meets one. *)
val corrupted_prefix : chunk_prefix:string -> string

(** Where a marker for the chunk object at [key] belongs, [None] when [key]
    names something else. Pure surgery on a backend key: ["…/chunks/abb/<k>"]
    becomes ["…/corrupted/abb/<k>"].

    [None] for a marker key and for anything under [chunks.from/], neither
    spelling the ["/chunks/"] segment this matches. That is what stops a marker
    earning one of its own — the same non-recursion the bucket notification's
    prefix filter buys in the cloud, kept here so the two cannot disagree. *)
val marker_key : string -> string option

(** Whether [key] is one of {!marker_key}'s answers. False for the directories a
    filesystem store creates to hold markers and lists back, which is why this
    asks for the whole shape rather than for the prefix: an empty shard is not a
    corrupt chunk, and it has no chunk key to name. *)
val is_marker_key : string -> bool

(** The chunk a marker names. *)
val chunk_key_of_marker : string -> string
