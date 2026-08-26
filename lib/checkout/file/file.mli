(** The domain file operations backed by the local manifest mirror, the staged
    tree and the chunk store. {!File_ops.S} is the interface they satisfy.

    Every file change writes its own journal record and hands it to whoever
    sends the bytes, which is a worker pool with a width and a retry policy of
    its own. That pool is not here; what is here is the record, and the few
    questions the pool asks back. *)

(** {1 What the store is asked for}

    Signatures rather than the modules that satisfy them, so the operations are
    written against what they call and not against a store: {!File_store.Make},
    {!Store.Make} and {!History.Make} each answer one, and {!Remote.S} is taken
    whole because {!Data_lwt.Make} is given it. {!Make} is where they are built.
*)

(** The shared journal: a file change is recorded there before anyone is told
    about it, and the cursor names the last record a reader should have seen. *)
module type JOURNAL = sig
  val write_journal_entry :
    ?entry_key:Journal.Entry_key.t ->
    Journal.op list ->
    Journal.Entry_key.t Lwt.t

  val bump_cursor : Journal.Entry_key.t -> unit Lwt.t
  val rename_file : src_key:Logical_key.t -> dst_key:Logical_key.t -> unit Lwt.t
  val head_manifest_opt : key:Logical_key.t -> Backend.file_entry option Lwt.t
end

(** A domain's manifests and the folder markers beside them, by logical key, and
    the raw objects a trashed folder is moved through, by backend key. *)
module type OBJECTS = sig
  val put_manifest : key:Logical_key.t -> data:Bigstring.t -> unit Lwt.t
  val delete_manifest : key:Logical_key.t -> unit Lwt.t
  val put_folder_marker : key:Logical_key.t -> unit Lwt.t
  val get_object : bkey:Stored_key.t -> string Lwt.t
  val put_raw : bkey:Stored_key.t -> data:string -> unit Lwt.t
  val delete_raw : bkey:Stored_key.t -> unit Lwt.t
end

(** What a file used to be. Snapshotting is best-effort: a version that is not
    written must not wedge the change that would have been versioned. *)
module type VERSIONS = sig
  val version_dir : key:Logical_key.t -> Stored_key.t option Lwt.t
  val save_version : key:Logical_key.t -> unit Lwt.t
  val list_versions : key:Logical_key.t -> Backend.file_entry list Lwt.t
  val get_version : vkey:Stored_key.t -> string Lwt.t
end

(** What the sending pool needs of the file operations, and what it tells them
    in return. *)
module type Owing = sig
  (** The file a record names, from its ops: a [`Put] or [`Delete] names a file,
      the directory ops a folder. *)
  val record_key : Wal.record -> Logical_key.t option

  (** What a record will cost to send. Only a [`Put] carries bytes. *)
  val record_size : Wal.record -> int64

  (** Send one file's staged content. Called by the pool, not by a frontend. *)
  val upload : ?cancel:bool ref -> Logical_key.t -> unit Lwt.t

  (** Say which files are being sent right now, for
      {!File_ops.S.uploads_in_flight}. *)
  val set_in_flight : (unit -> Logical_key.t list) -> unit

  (** Say how to stop a send. Not only reported: a write to a file being sent
      must stop the send, or a manifest is published for content torn out from
      under it. *)
  val set_canceller : (Logical_key.t -> bool) -> unit
end

(** [L] is still taken: a folder's id is resolved here, not by the store. *)
module Make_with_layout
    (C : Conf.S)
    (L : Layout.S)
    (_ : JOURNAL)
    (_ : OBJECTS)
    (_ : VERSIONS)
    (_ : Remote.S) : sig
  include File_ops.S with type 'a io := 'a Lwt.t
  include Owing
end

module Make (C : Conf.S) : sig
  include File_ops.S with type 'a io := 'a Lwt.t
  include Owing
end
