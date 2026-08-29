(** The domain file operations backed by the local manifest mirror, the staged
    tree and the chunk store. {!File_ops.S} is the interface they satisfy.

    Every file change writes its own journal record and hands it to whoever
    sends the bytes, which is a worker pool with a width and a retry policy of
    its own. That pool is not here; what is here is the record, and the few
    questions the pool asks back. *)

(** What this needs below it. Prose for each member lives with the module that
    implements it: {!Wal}, {!Manifests}, {!Checkout}, {!Staged_manifest},
    {!Data} and {!Remote}. *)
module type REMOTE = sig
  type 'a io

  val chunk_size : unit -> int io
  val get_chunk : chunk_key:string -> Bigstring.t io

  val get_chunk_range :
    chunk_key:string -> offset:int -> length:int -> Bigstring.t io

  val upload :
    key:Logical_key.t ->
    src_path:string ->
    mtime:float ->
    chunk_size:int ->
    ?cancel:bool ref ->
    ?on_progress:(bytes:int -> sent:bool -> unit) ->
    unit ->
    Manifest.t io

  val upload_chunks :
    key:Logical_key.t ->
    size:int64 ->
    chunk_size:int ->
    mtime:float ->
    source:(int -> unit io Chunk_source.t io) ->
    ?cancel:bool ref ->
    unit ->
    Manifest.t io

  val fetch_manifest : key:Logical_key.t -> unit -> Manifest.t option io
end

module type CONTENT = sig
  type 'a io

  module Make
      (C : Conf.S with type 'a io = 'a io)
      (_ : REMOTE with type 'a io := 'a io) : sig
    val pread :
      id:string ->
      ?stream:string ->
      manifest:Manifest.t ->
      Bigstring.t ->
      offset:int64 ->
      int io

    val published : Logical_key.t -> Manifest.t option io
    val pread_key :
      ?stream:string -> Logical_key.t -> Bigstring.t -> offset:int64 -> int io
    val write : Logical_key.t -> Bigstring.t -> offset:int64 -> int io
    val truncate : Logical_key.t -> int64 -> unit io
    val create : Logical_key.t -> unit io
    val sync : Logical_key.t -> ?cancel:bool ref -> unit -> unit io
    val enforce_chunk_cap : unit -> unit io
    val chunk_stats : unit -> (int * int) io
    val downloads_in_flight : unit -> int
    val downloads_completed_count : unit -> int
    val stage_whole : Logical_key.t -> src_path:string -> unit io
    val chunk_residency : Logical_key.t -> (int * int) io
    val ensure_local : Logical_key.t -> unit io
    val assemble_to : Logical_key.t -> dst_path:string -> unit io

    val fetch_range :
      Logical_key.t -> dst_path:string -> offset:int -> length:int -> int io

    val download_progress : Logical_key.t -> (int * int) option

    type pulling = {
      key : string;
      bytes : int;
      size : int;
      seconds : float;
      rate : float;
    }

    val pulling_now : ?now:float -> unit -> pulling list
    val forget_chunks : Logical_key.t -> unit io
    val discard_staged : Logical_key.t -> unit io
    val staged_body_path : Logical_key.t -> string option io
    val reclaim_staged_orphans : unit -> unit io
  end
end

module type Owing = sig
  type 'a io

  (** The file a record names, from its ops: a [`Put] or [`Delete] names a file,
      the directory ops a folder. *)
  val record_key : Wal.record -> Logical_key.t option

  (** What a record will cost to send. Only a [`Put] carries bytes. *)
  val record_size : Wal.record -> int64

  (** Send one file's staged content. Called by the pool, not by a frontend. *)
  val upload : ?cancel:bool ref -> Logical_key.t -> unit io

  (** Say which files are being sent right now, for
      {!File_ops.S.uploads_in_flight}. *)
  val set_in_flight : (unit -> Logical_key.t list) -> unit

  (** Say how to stop a send. Not only reported: a write to a file being sent
      must stop the send, or a manifest is published for content torn out from
      under it. *)
  val set_canceller : (Logical_key.t -> bool) -> unit
end

module type LAYOUT = sig
  type 'a io

  val folder_marker_key : Logical_key.t -> Stored_key.t option io
  val ensure_folder_id : Logical_key.t -> string io
end

module type FOLDERS = sig
  type 'a io

  val lookup_id :
    cache_root:string -> domain_name:string -> Logical_key.t -> string option io

  val write :
    cache_root:string ->
    domain_name:string ->
    Logical_key.t ->
    Folder.marker ->
    unit io
end

module type WAL = sig
  type 'a io

  module Owed : sig
    type 'a t

    val signal : 'a t -> 'a -> unit io
    val consume : 'a t -> ('a -> unit io) -> unit
    val idle : 'a t -> unit
  end

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val owed : (Journal.Entry_key.t * Wal.record) Owed.t
    val record : Journal.Entry_key.t -> Journal.op list -> unit io
    val write : Journal.Entry_key.t -> Wal.record -> unit io
    val complete : Journal.Entry_key.t -> unit io

    val discharge :
      publish:(Journal.Entry_key.t -> Journal.op list -> Journal.Entry_key.t io) ->
      cursor:(Journal.Entry_key.t -> unit io) ->
      Journal.Entry_key.t ->
      Journal.op list ->
      unit io
  end
end

module type MIRROR = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val path : Logical_key.t -> string
    val published : Logical_key.t -> Manifest.t option io
    val write : Logical_key.t -> Manifest.t -> unit io
    val delete : Logical_key.t -> unit io

    val current :
      Logical_key.t ->
      [ `Staged of Staged_manifest.staged * Manifest.t option
      | `Published of Manifest.t ]
      option
      io
  end
end

module type TREE = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val rename : src_key:Logical_key.t -> dst_key:Logical_key.t -> unit io
    val create_dir : Logical_key.t -> unit io
    val delete_dir : Logical_key.t -> unit io

    val list_children :
      prefix:Logical_key.t -> unit -> (Checkout.listed list * string list) io

    val list_tree : prefix:Logical_key.t -> unit -> Checkout.listed list io
  end
end

module type STAGED = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val exists : Logical_key.t -> bool io
    val read_edits : Logical_key.t -> Staged_manifest.staged option io
    val rename : src_key:Logical_key.t -> dst_key:Logical_key.t -> unit io
    val list : unit -> Logical_key.t list io
  end
end

module type FS = sig
  type 'a io

  val stat_opt_large : string -> Unix.LargeFile.stats option io
end

module type SYSCALLS = sig
  type 'a io

  val file_exists : string -> bool io
end

module type LOCKS = sig
  type 'a io
  type mutex

  val mutex : unit -> mutex
  val with_lock : mutex -> (unit -> 'a io) -> 'a io
  val is_locked : mutex -> bool
  val has_waiters : mutex -> bool
end

module Over
    (Io : Io.S)
    (_ : FS with type 'a io := 'a Io.t)
    (_ : SYSCALLS with type 'a io := 'a Io.t)
    (_ : LOCKS with type 'a io := 'a Io.t)
    (_ : WAL with type 'a io := 'a Io.t)
    (_ : MIRROR with type 'a io := 'a Io.t)
    (_ : TREE with type 'a io := 'a Io.t)
    (_ : STAGED with type 'a io := 'a Io.t)
    (_ : CONTENT with type 'a io := 'a Io.t)
    (_ : FOLDERS with type 'a io := 'a Io.t) : sig
  (** {1 What the store is asked for}

      Signatures rather than the modules that satisfy them, so the operations
      are written against what they call and not against a store:
      {!File_store.Make}, {!Store.Make} and {!History.Make} each answer one, and
      {!Remote.S} is taken whole because {!Data.Make} is given it. {!Make} is
      where they are built. *)

  (** The shared journal: a file change is recorded there before anyone is told
      about it, and the cursor names the last record a reader should have seen.
  *)
  module type JOURNAL = sig
    val write_journal_entry :
      ?entry_key:Journal.Entry_key.t ->
      Journal.op list ->
      Journal.Entry_key.t Io.t

    val bump_cursor : Journal.Entry_key.t -> unit Io.t

    val rename_file :
      src_key:Logical_key.t -> dst_key:Logical_key.t -> unit Io.t

    val head_manifest_opt : key:Logical_key.t -> Backend.file_entry option Io.t
  end

  (** A domain's manifests and the folder markers beside them, by logical key,
      and the raw objects a trashed folder is moved through, by backend key. *)
  module type OBJECTS = sig
    val put_manifest : key:Logical_key.t -> data:Bigstring.t -> unit Io.t
    val delete_manifest : key:Logical_key.t -> unit Io.t
    val put_folder_marker : key:Logical_key.t -> unit Io.t
    val get_object : bkey:Stored_key.t -> string Io.t
    val put_raw : bkey:Stored_key.t -> data:string -> unit Io.t
    val delete_raw : bkey:Stored_key.t -> unit Io.t
  end

  (** What a file used to be. Snapshotting is best-effort: a version that is not
      written must not wedge the change that would have been versioned. *)
  module type VERSIONS = sig
    val version_dir : key:Logical_key.t -> Stored_key.t option Io.t
    val save_version : key:Logical_key.t -> unit Io.t
    val list_versions : key:Logical_key.t -> Backend.file_entry list Io.t
    val get_version : vkey:Stored_key.t -> string Io.t
  end

  (** What the sending pool needs of the file operations, and what it tells them
      in return. *)

  (** [L] is still taken: a folder's id is resolved here, not by the store. *)
  module Make_with_layout
      (C : Conf.S with type 'a io = 'a Io.t)
      (L : LAYOUT with type 'a io := 'a Io.t)
      (_ : JOURNAL)
      (_ : OBJECTS)
      (_ : VERSIONS)
      (_ : REMOTE with type 'a io := 'a Io.t) : sig
    include File_ops.S with type 'a io := 'a Io.t
    include Owing with type 'a io := 'a Io.t
  end
end
