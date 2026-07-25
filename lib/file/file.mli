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
  val upload : ?cancel:bool ref -> t -> unit Lwt.t
  val ensure_cached : t -> unit Lwt.t

  (** Prepare a not-yet-complete file for reading: demand-page it (sparse file,
      no download) when it is a real chunked file, else fall back to a whole
      download. Idempotent. *)
  val prepare_read : t -> unit Lwt.t

  (** Ensure the bytes in the range [offset, offset+len] are on disk, fetching
      only the chunks that back them for a partial file. *)
  val ensure_readable : t -> offset:int64 -> len:int -> unit Lwt.t

  (** Mark the chunks a write at the range [offset, offset+len] touches dirty,
      fetching a partially-overwritten absent chunk first (read-modify-write).
  *)
  val dirty_range : t -> offset:int64 -> len:int -> unit Lwt.t

  val stat : t -> Unix.LargeFile.stats option Lwt.t

  (** Return the symlink target for a key whose manifest is a symlink, or [None]
      if the key is absent or is a regular file. *)
  val readlink : t -> string option Lwt.t

  val list_dir : t -> string list Lwt.t

  (** Directory listing served from the local manifest mirror: files (with real
      keys derived from each manifest's [path]) and subdirectory names (mtime
      unavailable locally, hence [None]). *)
  val list_directory :
    prefix:string ->
    (Backend.file_entry list * (string * float option) list) Lwt.t

  (** Recursive file listing under [prefix], served from the local mirror. *)
  val list_all_files : prefix:string -> Backend.file_entry list Lwt.t

  val mark_dirty : t -> unit Lwt.t
  val mark_open : t -> unit
  val mark_closed : t -> int

  (** Last-handle-close policy: queue a dirty file for upload, drop a file
      flagged for eviction, else persist. Decrements the open count. *)
  val release : t -> unit Lwt.t

  (** Evict [key] now if closed, else defer the eviction to its last close. *)
  val request_evict : t -> unit Lwt.t

  (** In-flight downloads (files currently being fetched). *)
  val downloading_count : unit -> int

  (** Files with unsaved local changes not yet uploaded. *)
  val dirty_count : unit -> int

  (** Files with at least one open handle. *)
  val open_files_count : unit -> int

  (** Downloads completed since the daemon started. *)
  val downloads_completed_count : unit -> int

  (** [Some (bytes_done, total_bytes)] while [key] is being downloaded; [None]
      when idle or already cached. *)
  val download_progress : t -> (int * int) option

  val evict : t -> unit Lwt.t
  val create : t -> unit Lwt.t
  val read : t -> buffer -> offset:int64 -> int Lwt.t
  val write : t -> buffer -> offset:int64 -> int Lwt.t
  val cancel_upload : t -> bool
  val truncate : t -> int64 -> unit Lwt.t
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
