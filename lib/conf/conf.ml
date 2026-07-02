module type S = sig
  val versioning : bool
  val client_name : string
  val domain_name : string
  val domain_prefix : string
  val chunk_prefix : string
  val trash_prefix : string
  val journal_prefix : string
  val version_key : string
  (** Ordered list of backends. First element is primary (used for reads).
      Writes fan out to all elements. *)
  val backends : (module Backend.S) list
  val cache_root : string
  val data_dir : string
  val socket_path : string
  val notify_path : string
end
