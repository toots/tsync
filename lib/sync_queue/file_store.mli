module Make(C : Conf.S) : sig
  val delete_dir : prefix:string -> unit
  val create_directory : key:string -> unit
  val rename_file : src_key:string -> dst_key:string -> unit
  val rename_directory : src_prefix:string -> dst_prefix:string -> unit
  val list_directory : prefix:string -> S3_client.file_entry list * string list
  val list_all_files : prefix:string -> S3_client.file_entry list
  val head_opt : key:string -> S3_client.file_entry option
  val write_journal_entry : ?entry_key:string -> Journal.op list -> string
  val bump_version : string -> unit
  val fetch_version : unit -> string option
  val list_journal_keys : ?start_after:string -> unit -> (string * string) list
  val get_journal_entry : string -> Journal.op list option
end
