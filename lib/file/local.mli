val cache_path :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  string

val manifest_path :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  string

val ensure_parent_dir : string -> unit Lwt.t

val is_cached :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  bool Lwt.t

val read_manifest :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  string option Lwt.t

val delete_manifest :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  unit Lwt.t

val rename_manifest :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  src_key:string ->
  dst_key:string ->
  unit Lwt.t

val init : cache_root:string -> domain_name:string -> unit Lwt.t

val create_dir :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  unit Lwt.t

val delete_dir :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  unit Lwt.t

val list_dir :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  string list Lwt.t

val evict :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  unit Lwt.t
