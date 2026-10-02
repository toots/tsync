(** Stored keys and prefixes (spec 01 §2.1, 02 §2.3).

    A key is built only by the namers below or by {!of_string}, the validating
    boundary for names that come from outside (a listing, a peer, a job record);
    no free string reaches a store. *)

type t = private string
type prefix = private string

(** The key grammar of 01 §2.1, else [None]. *)
val of_string : string -> t option

(** Raises INVALID. *)
val v : ?op:string -> string -> t

val prefix_of_string : string -> prefix option
val prefix : ?op:string -> string -> prefix
val to_string : t -> string
val prefix_to_string : prefix -> string

(** [k ^ "/"]. *)
val as_prefix : t -> prefix

val under : prefix -> t -> bool

(** The part of a key after a prefix it lies under. *)
val rel : prefix -> t -> string

val equal : t -> t -> bool
val compare : t -> t -> int

(** {1 Namers} *)

val root : prefix
val domain_prefix : Domain_name.t -> prefix
val manifests : Domain_name.t -> prefix

(** The surviving chunk space. *)
val chunks : Domain_name.t -> prefix

(** The outgoing space of an open collection. *)
val chunks_from : Domain_name.t -> prefix

val versions : Domain_name.t -> prefix
val journal : Domain_name.t -> prefix
val cursor : Domain_name.t -> t
val gc_run : Domain_name.t -> t
val gc_generation : Domain_name.t -> t

(** The collection's run lock file on a filesystem store; not a store object. *)
val gc_lock : Domain_name.t -> t

(** The collection's publish lock file on a filesystem store; not a store
    object. *)
val gc_publish_lock : Domain_name.t -> t

val corrupted : Domain_name.t -> prefix
val verify_jobs : Domain_name.t -> prefix
val gc_jobs : Domain_name.t -> prefix
val shares : prefix
val share_cache : prefix

(** [tsync/shares/<token>] for a token a reader accepts: 1 to 128 lowercase hex
    characters (security §6.1). Anything else in the share space is a cached
    artifact, never a manifest. *)
val share : string -> t option

val shard_prefix : Domain_name.t -> string -> prefix
val chunk : Domain_name.t -> Chunk_key.t -> t
val chunk_from : Domain_name.t -> Chunk_key.t -> t
val namespace : Domain_name.t -> Folder_id.t -> prefix

(** A folder's child slot: the namespace and the dual hash of the leaf. *)
val child : Domain_name.t -> Folder_id.t -> string -> t

val anchor : Domain_name.t -> Folder_id.t -> t
val index : Domain_name.t -> Folder_id.t -> t
val trash_entry : Domain_name.t -> string -> t

(** [versions/<group>/<ns>], the group being [<folder id>/<leaf hash>]. *)
val version : Domain_name.t -> group:string -> ns:int64 -> t

val journal_entry : Domain_name.t -> month:string -> entry:string -> t
val verify_job : Domain_name.t -> string -> t
val discard_job : Domain_name.t -> run:string -> shard:string -> t

(** The corruption marker of a chunk. *)
val marker : Domain_name.t -> Chunk_key.t -> t

(** The four roots a domain owns on a listener. *)
val roots : Domain_name.t -> prefix list

(** {1 Readers} *)

val split_last : string -> string * string
val leaf : t -> string

(** The segment before the leaf: a child key's folder id. *)
val parent_segment : t -> string

(** The chunk a surviving-space key names. *)
val chunk_of : t -> Chunk_key.t option

(** The marker key of a surviving-space chunk key, of any domain. *)
val marker_of : t -> t option

(** A surviving-space chunk key of any domain, split. *)
val chunk_parts : t -> (Domain_name.t * Chunk_key.t) option

(** An outgoing-space chunk key of any domain, split. *)
val outgoing_chunk : t -> (Domain_name.t * Chunk_key.t) option

(** Any key inside an outgoing space, chunk or not. *)
val is_outgoing : t -> bool

(** The outgoing-space prefix matching a prefix inside a surviving space. *)
val outgoing_prefix : prefix -> prefix option

(** The domain of a key in a manifest or version area. *)
val domain_of_reference : t -> Domain_name.t option

val chunk_of_marker : t -> (Domain_name.t * Chunk_key.t) option
val parse_verify_job : t -> (Domain_name.t * string) option

(** Domain, run and shard. *)
val parse_discard_job : t -> (Domain_name.t * string * string) option

(** Leaves a store keeps for itself begin with [.tsync-]. *)
val is_internal_leaf : string -> bool

(** Directly under [namespace], with a leaf that is not internal. *)
val is_child_of : namespace:prefix -> t -> bool

(** The folder id whose namespace holds a key of the manifest area. *)
val folder_of_namespace_key : Domain_name.t -> t -> Folder_id.t option

(** A collection's run name: [started * 1000] rounded, 13 digits. *)
val run_name : float -> string
