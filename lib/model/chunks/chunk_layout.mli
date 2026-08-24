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

val is_shard_name : string -> bool

(** {1 Holding a body against its own name}

    A chunk's key {i is} the hash of its bytes, so a store can check every
    object it takes without being told anything: the name is the expected
    answer. What fails is filed under {!corrupted_prefix}, where any client can
    list it. *)

(** What a collection calls itself in {!gc_job_key}, from its start time. *)
val gc_run_name : float -> string

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
val marker_key : Stored_key.t -> Stored_key.t option

(** Whether [key] is one of {!marker_key}'s answers. False for the directories a
    filesystem store creates to hold markers and lists back, which is why this
    asks for the whole shape rather than for the prefix: an empty shard is not a
    corrupt chunk, and it has no chunk key to name. *)
val is_marker_key : Stored_key.t -> bool

(** The chunk a marker names. *)
val chunk_key_of_marker : Stored_key.t -> string

(** What a chunk store's keys hang off. {!Conf.S} satisfies it, and a caller
    built before there is one — {!Deferred} — passes the prefix alone. *)
module type Store = sig
  val chunk_prefix : string
end

module Make (S : Store) : sig
  (** The backend key for a chunk key, in the space every writer uses. *)
  val key : string -> Stored_key.t

  (** Everything under one shard, which is how a reader learns what a shard
      holds without asking about each chunk in it. *)
  val shard_prefix : string -> string

  (** Where a collection puts the space on its way out, and a chunk's key within
      it. Siblings of the chunk root, since opening a run renames that root
      itself away. *)
  val from_prefix : string

  val from_key : string -> Stored_key.t
  val from_shard_prefix : string -> string

  (** Where this domain's corruption markers are filed, and the marker for one
      chunk. *)
  val corrupted_prefix : string

  val corrupted_key : string -> Stored_key.t

  (** Where a request asking the store to check its chunks is filed, and the key
      of the one naming [shard]. *)
  val verify_jobs_prefix : string

  val verify_job_key : string -> Stored_key.t

  (** The same for a request asking it to drop chunks. The run is in the key,
      not only the cursor: a later collection reaching the same shard would
      otherwise overwrite a request an earlier one left unconsumed. *)
  val gc_jobs_prefix : string

  val gc_job_key : run:string -> string -> Stored_key.t
end
