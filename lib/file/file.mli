type buffer = Local_io.buffer

module type S = sig
  type t = string

  val is_cached : t -> bool Lwt.t
  val local_path : t -> string
  val manifest_path : t -> string
  val ensure_parent_dir : t -> unit Lwt.t
  val rel_key : t -> string
  val read_manifest : t -> Manifest.state option Lwt.t

  (** Like {!read_manifest}, but falls back to fetching and parsing the backend
      manifest when there is no local sidecar, so a backend-only file resolves
      to its real logical size/mtime instead of the manifest object's byte size.
  *)
  val resolved_manifest : t -> Manifest.state option Lwt.t

  val write_manifest : t -> Manifest.state -> unit Lwt.t
  val delete_manifest : t -> unit Lwt.t
  val upload : ?cancel:bool ref -> t -> unit Lwt.t
  val download : t -> unit Lwt.t
  val ensure_cached : t -> unit Lwt.t
  val stat : t -> Unix.LargeFile.stats option Lwt.t

  (** Return the symlink target for a key whose manifest is a symlink, or [None]
      if the key is absent or is a regular file. *)
  val readlink : t -> string option Lwt.t

  val list_dir : t -> string list Lwt.t
  val xattrs : t -> (string * string) list Lwt.t
  val is_dirty : t -> bool
  val set_dirty : t -> unit
  val clear_dirty : t -> unit
  val mark_dirty : t -> unit Lwt.t
  val mark_open : t -> unit
  val mark_closed : t -> int
  val is_open : t -> bool

  (** In-flight downloads (files currently being fetched). *)
  val downloading_count : unit -> int

  (** Files with unsaved local changes not yet uploaded. *)
  val dirty_count : unit -> int

  (** Files with at least one open handle. *)
  val open_files_count : unit -> int

  (** Downloads completed since the daemon started. *)
  val downloads_completed_count : unit -> int

  val evict : t -> unit Lwt.t
  val clear_local : t -> unit Lwt.t
  val create : t -> unit Lwt.t
  val read : t -> buffer -> offset:int64 -> int Lwt.t
  val write : t -> buffer -> offset:int64 -> int Lwt.t
  val cancel_upload : t -> bool
  val truncate : t -> int64 -> unit Lwt.t
  val rename_local : src:t -> dst:t -> unit Lwt.t
  val apply_delete : t -> unit Lwt.t
  val queue_put : t -> unit Lwt.t
  val delete : t -> unit Lwt.t
  val mkdir : t -> unit Lwt.t
  val rmdir : t -> unit Lwt.t
  val rename : src:t -> dst:t -> unit Lwt.t
  val revert : ?version:string -> t -> unit Lwt.t
  val symlink : target:string -> t -> unit Lwt.t
  val apply_foreign_ops : Journal.op list -> unit Lwt.t
end

module Make (C : Conf.S) (Sq : Sync_queue.S) : S
