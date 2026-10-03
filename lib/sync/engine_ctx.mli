(** What the engine of one domain is built from: the remote context plus the
    owner's local paths, identity and policies (spec 05 §3). *)

module type S = sig
  include Tsync_remote.Context.S

  val cache_root : string
  val data_dir : string
  val client_uuid : string

  (** The display name in conflicted copies. *)
  val client_name : string

  val cache_chunk_size : int
  val max_cache : int option
  val max_uploads : int
  val read_only : bool
  val symlinks : [ `Keep | `Follow | `Skip ]

  (** A pulled tree (Android): no poller, folders read when listed. *)
  val lazy_tree : bool
end
