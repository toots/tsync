module Make (C : Conf.S) : sig
  val delete_dir : prefix:string -> unit Lwt.t
  val create_directory : key:string -> unit Lwt.t
  val rename_file : src_key:string -> dst_key:string -> unit Lwt.t
  val rename_directory : src_prefix:string -> dst_prefix:string -> unit Lwt.t

  val list_directory :
    prefix:string -> (Backend.file_entry list * string list) Lwt.t

  val list_all_files : prefix:string -> Backend.file_entry list Lwt.t
  val head_opt : key:string -> Backend.file_entry option Lwt.t
  val write_journal_entry : ?entry_key:string -> Journal.op list -> string Lwt.t
  val bump_cursor : string -> unit Lwt.t
  val fetch_cursor : unit -> string option Lwt.t

  val list_journal_keys :
    ?start_after:string -> unit -> (string * string) list Lwt.t

  val get_journal_entry : string -> Journal.op list option Lwt.t
end
