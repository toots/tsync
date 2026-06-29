type t

val make :
  client:S3_client.t ->
  domain_name:string ->
  domain_prefix:string ->
  chunk_prefix:string ->
  trash_prefix:string ->
  versioning:bool ->
  journal_prefix:string ->
  version_key:string ->
  t

(** {2 Local cache helpers} *)

val is_cached : t -> string -> bool
val local_path : t -> string -> string
val cache_root : t -> string
val ensure_parent_dir : string -> unit
val read_manifest : t -> string -> (Chunk_manifest.t * float) option
(** Returns [Some (manifest, sidecar_mtime)] when a chunk manifest sidecar exists. *)
val delete_manifest : t -> string -> unit
val evict : t -> string -> unit
val rename_manifest : t -> src_key:string -> dst_key:string -> unit

(** {2 S3 operations} *)

val upload : t -> key:string -> src_path:string -> ?cancel:bool Atomic.t -> unit -> unit
val download : t -> key:string -> dst_path:string -> unit
val ensure_cached : t -> string -> unit
(** Download [key] from S3 if it is not already in the local cache. *)

val delete_file : t -> key:string -> unit
(** Delete a file from S3, moving it to trash first when versioning is enabled. *)

val delete_dir : t -> prefix:string -> unit
(** Recursively delete all S3 objects under [prefix] (no versioning). *)

val create_directory : t -> key:string -> unit
val rename_file : t -> src_key:string -> dst_key:string -> unit
val rename_directory : t -> src_prefix:string -> dst_prefix:string -> unit

val list_directory : t -> prefix:string -> S3_client.file_entry list * string list
val head_opt : t -> key:string -> S3_client.file_entry option

val stat_file : t -> key:string -> S3_client.file_entry option
(** Like [head_opt] but resolves the true file size for chunked manifest objects. *)

val domain_name : t -> string
val domain_prefix : t -> string
val journal_prefix : t -> string

(** {2 Journal WAL} *)

val write_journal_entry : ?entry_key:string -> Journal.op list -> t -> string
(** Write a journal entry to S3 only; returns the entry key used.
    The version key is NOT updated — call [bump_version] separately. *)

val bump_version : t -> string -> unit
(** Update the version key to point to [entry_key]. *)

val fetch_version : t -> string option
(** Return the latest committed journal entry key from S3, or [None]. *)

val list_journal_keys : ?start_after:string -> t -> unit -> (string * string) list
(** Return [(entry_key_basename, client_uuid)] pairs for all journal entries,
    optionally filtered to those after [start_after]. *)

val get_journal_entry : t -> string -> Journal.op list option

val recover_pending_ops : t -> unit
(** Replay locally-pending WAL entries that did not reach S3 before a crash. *)
