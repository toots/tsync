type buffer = Local_io.buffer

module type S = sig
  type t = string

  val is_cached : t -> bool
  val local_path : t -> string
  val manifest_path : t -> string
  val ensure_parent_dir : t -> unit
  val rel_key : t -> string
  val read_manifest : t -> Manifest.state option
  val write_manifest : t -> Manifest.state -> unit
  val delete_manifest : t -> unit
  val upload : ?cancel:bool Atomic.t -> t -> unit
  val download : t -> unit
  val ensure_cached : t -> unit
  val stat : t -> Unix.LargeFile.stats option
  val list_dir : t -> string list
  val xattrs : t -> (string * string) list
  val is_dirty : t -> bool
  val set_dirty : t -> unit
  val clear_dirty : t -> unit
  val mark_dirty : t -> unit
  val evict : t -> unit
  val clear_local : t -> unit
  val create : t -> unit
  val read : t -> buffer -> offset:int64 -> int
  val write : t -> buffer -> offset:int64 -> int
  val cancel_upload : t -> bool
  val truncate : t -> int64 -> unit
  val rename_local : src:t -> dst:t -> unit
  val apply_delete : t -> unit
  val queue_put : t -> unit
  val delete : t -> unit
  val mkdir : t -> unit
  val rmdir : t -> unit
  val rename : src:t -> dst:t -> unit
end

module Make (C : Conf.S) (Sq : Sync_queue.S) : S
