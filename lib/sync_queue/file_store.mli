module Make (C : Conf.S) : sig
  val rename_file : src_key:string -> dst_key:string -> unit Lwt.t

  (** Heads a *file key*'s manifest object, resolving it through the layout.
      Journal objects are not manifests — see {!journal_entry_published}. *)
  val head_manifest_opt : key:string -> Backend.file_entry option Lwt.t

  val write_journal_entry : ?entry_key:string -> Journal.op list -> string Lwt.t
  val bump_cursor : string -> unit Lwt.t
  val fetch_cursor : unit -> string option Lwt.t

  (** How far this client has applied the shared journal: a journal key, or [""]
      when it has never synced. Local state — it says what we caught up to, not
      what has been published. *)
  val read_last_sync_key : unit -> string

  val write_last_sync_key : string -> unit

  val list_journal_keys :
    ?start_after:string -> unit -> (string * string) list Lwt.t

  val get_journal_entry : string -> Journal.op list option Lwt.t

  (** Whether the entry's object is on the backend, i.e. this entry was
      published. The entry-key-to-backend-key mapping lives here so a caller
      cannot forget the month directory {!Journal.relative_path} adds. *)
  val journal_entry_published : string -> bool Lwt.t
end
