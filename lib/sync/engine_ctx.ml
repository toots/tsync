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
  val lazy_tree : bool

  (** This owner's domain is served by a listener that projects (frontends/
      http-proxy, [projectCommits]): it is the projector of every entry. *)
  val projects_all : bool

  (** The advanced settings and the symlink policy in force, given what the main
      states (05 §2.1); INVALID when the configuration differs from it. *)
  val settings :
    Tsync_store.Store.domain_settings option ->
    Tsync_core.Tuning.t * [ `Keep | `Follow | `Skip ]
end
