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

(** [shard_of key] is the shard the key lives in, which is the first segment of
    {!relative_path}. Asked of this module rather than recovered from that path,
    so a caller wanting the shard alone does not have to know how deep the
    layout goes. *)
val shard_of : string -> string

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
    publishes it through {!Manifest.key_of_body} and a check recomputes it here,
    so the two cannot drift into naming the same bytes differently. *)
val key_of_body : Bigstring.t -> string

(** ["tsync/corrupted/<domain>/"]. Beside the domains rather than inside one,
    with the domain as its first segment, so one literal prefix covers every
    domain. *)
val corrupted_prefix : chunk_prefix:string -> string

(** Where a domain's shard-check requests are filed, beside the domains like
    {!corrupted_prefix} so nothing walking chunks meets one. *)
val verify_jobs_prefix : chunk_prefix:string -> string

(** The request to check one shard. The bucket is the queue: a client writes one
    of these per shard, the store's own object-created notification carries it
    to the function that checks chunks, and the function deletes it when that
    shard is done. *)
val verify_job_key : chunk_prefix:string -> string -> string

(** Where a domain's discard requests are filed, beside {!verify_jobs_prefix}
    and for the same reason. *)
val gc_jobs_prefix : chunk_prefix:string -> string

(** The request to drop one batch of chunks. Like {!verify_job_key} the bucket
    is the queue, but the body carries the keys: a copy has no from-space of its
    own to be pointed at, so the request has to say which ones.

    Named by collection and then by cursor, so a repeated flush overwrites its
    own request while a later collection reaching the same shard cannot
    overwrite one an earlier collection left unconsumed. *)
val gc_job_key : chunk_prefix:string -> run:string -> string -> string

(** What a collection calls itself in {!gc_job_key}, from its start time. *)
val gc_run_name : float -> string

(** The domain a chunk prefix belongs to: its second path segment, so
    ["tsync/<domain>/chunks/"] yields [<domain>]. *)
val domain_of : chunk_prefix:string -> string

(** The shard a request names — either kind — and [None] for anything else found
    under the prefix, which on a filesystem store means the directory it filed
    one under and lists back. Counting one of those as a request outstanding is
    a false alarm about the one thing that reports a copy nobody is emptying. *)
val shard_of_job : string -> string option

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
