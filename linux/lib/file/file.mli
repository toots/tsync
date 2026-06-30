type store
type buffer = Local_io.buffer

val make_store :
  conf:Conf.t ->
  file_store:File_store.t ->
  sync_queue:Sync_queue.t ->
  auto_evict:bool ref ->
  store

type t

val make : store:store -> key:string -> t
val is_cached : t -> bool
val local_path : t -> string
val ensure_parent_dir : t -> unit
val ensure_cached : t -> unit
val read_manifest : t -> Manifest.state option
val delete_manifest : t -> unit
val upload : ?cancel:bool Atomic.t -> t -> unit
val download : t -> unit
val stat : t -> Unix.LargeFile.stats option
val list_dir : t -> string list
val xattrs : t -> (string * string) list
val evict : t -> unit
val clear_local : t -> unit
val create : t -> unit
val mark_dirty : t -> unit
val read : t -> buffer -> offset:int64 -> int
val write : t -> buffer -> offset:int64 -> int
val truncate : t -> int64 -> unit
val delete : t -> unit
val apply_delete : t -> unit
val queue_put : t -> unit
val cancel_upload : t -> bool
val mkdir : t -> unit
val rmdir : t -> unit
val rename : src:t -> dst:t -> unit
val open_file : t -> unit
val close_file : t -> unit
val on_upload_done : t -> unit
val request_evict : t -> unit
