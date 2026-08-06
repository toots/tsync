(** The shared journal on the backend, and the local mark saying how far it has
    been read. The only module that turns an entry key into a backend key. *)
module Make (C : Conf.S) : sig
  val rename_file : src_key:string -> dst_key:string -> unit Lwt.t

  (** Heads a *file key*'s manifest object, resolving it through the layout.
      Journal objects are not manifests — see {!journal_entry_published}. *)
  val head_manifest_opt : key:string -> Backend.file_entry option Lwt.t

  val write_journal_entry :
    ?entry_key:Journal.Entry_key.t ->
    Journal.op list ->
    Journal.Entry_key.t Lwt.t

  val bump_cursor : Journal.Entry_key.t -> unit Lwt.t
  val fetch_cursor : unit -> Journal.Entry_key.t option Lwt.t

  (** How far this client has applied the shared journal. [None] when it has
      never synced. Local state — it says what we caught up to, not what has
      been published. *)
  val read_last_sync_key : unit -> Journal.Entry_key.t option

  val write_last_sync_key : Journal.Entry_key.t -> unit

  (** Chronological. [start_after] is exclusive. Entries whose name no client
      wrote are skipped. *)
  val list_journal_keys :
    ?start_after:Journal.Entry_key.t -> unit -> Journal.Entry_key.t list Lwt.t

  val get_journal_entry : Journal.Entry_key.t -> Journal.op list option Lwt.t

  (** Whether the entry's object is on the backend, i.e. this entry was
      published. The entry-key-to-backend-key mapping lives here so a caller
      cannot forget the month directory {!Journal.Entry_key.relative_path} adds.
  *)
  val journal_entry_published : Journal.Entry_key.t -> bool Lwt.t
end
