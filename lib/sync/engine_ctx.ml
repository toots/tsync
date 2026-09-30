module type S = sig
  include Tsync_remote.Context.S

  val cache_root : string
  val data_dir : string
  val client_uuid : string
  val client_name : string
  val cache_chunk_size : int
  val max_cache : int option
  val max_uploads : int
  val read_only : bool
  val symlinks : [ `Keep | `Follow | `Skip ]
  val lazy_tree : bool
end
