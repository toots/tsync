val cache_path :
  cache_root:string -> domain_name:string -> domain_prefix:string -> string -> string

val manifest_path :
  cache_root:string -> domain_name:string -> domain_prefix:string -> string -> string

val ensure_parent_dir : string -> unit

val is_cached :
  cache_root:string -> domain_name:string -> domain_prefix:string -> string -> bool

val read_manifest :
  cache_root:string -> domain_name:string -> domain_prefix:string -> string -> string option

val delete_manifest :
  cache_root:string -> domain_name:string -> domain_prefix:string -> string -> unit

val rename_manifest :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  src_key:string ->
  dst_key:string ->
  unit

val init : cache_root:string -> domain_name:string -> unit
val create_dir : cache_root:string -> domain_name:string -> domain_prefix:string -> string -> unit
val delete_dir : cache_root:string -> domain_name:string -> domain_prefix:string -> string -> unit
val list_dir : cache_root:string -> domain_name:string -> domain_prefix:string -> string -> string list
val evict : cache_root:string -> domain_name:string -> domain_prefix:string -> string -> unit
