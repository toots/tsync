type t = Conf.t

val make : Conf.t -> t
val domain_name : t -> string
val domain_prefix : t -> string
val journal_prefix : t -> string
val client : t -> S3_client.t
val chunk_prefix : t -> string
val trash_prefix : t -> string
val versioning : t -> bool
val cache_root : t -> string
val socket_path : t -> string
val notify_path : t -> string

(** {2 Directory operations} *)

val delete_dir : t -> prefix:string -> unit
val create_directory : t -> key:string -> unit
val rename_file : t -> src_key:string -> dst_key:string -> unit
val rename_directory : t -> src_prefix:string -> dst_prefix:string -> unit

val list_directory :
  t -> prefix:string -> S3_client.file_entry list * string list

val list_all_files : t -> prefix:string -> S3_client.file_entry list
val head_opt : t -> key:string -> S3_client.file_entry option

(** {2 Journal WAL} *)

val write_journal_entry : ?entry_key:string -> Journal.op list -> t -> string
val bump_version : t -> string -> unit
val fetch_version : t -> string option

val list_journal_keys :
  ?start_after:string -> t -> unit -> (string * string) list

val get_journal_entry : t -> string -> Journal.op list option
