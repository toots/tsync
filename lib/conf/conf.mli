module type S = sig
  val bucket : string
  val prefix : string
  val aws_region : string
  val versioning : bool
  val access_key_id : string
  val secret_access_key : string
  val domain_name : string
  val domain_prefix : string
  val chunk_prefix : string
  val trash_prefix : string
  val journal_prefix : string
  val version_key : string
  val client : S3_client.t
  val cache_root : string
  val data_dir : string
  val socket_path : string
  val notify_path : string
end
