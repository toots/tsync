val cache_root : string -> string
val manifest_root : string -> string
val cache_path : domain_name:string -> domain_prefix:string -> string -> string

val manifest_path :
  domain_name:string -> domain_prefix:string -> string -> string

val ensure_parent_dir : string -> unit
val is_cached : domain_name:string -> domain_prefix:string -> string -> bool

val read_manifest :
  domain_name:string -> domain_prefix:string -> string -> string option

val delete_manifest :
  domain_name:string -> domain_prefix:string -> string -> unit

val rename_manifest :
  domain_name:string ->
  domain_prefix:string ->
  src_key:string ->
  dst_key:string ->
  unit

val init : domain_name:string -> unit
val create_dir : domain_name:string -> domain_prefix:string -> string -> unit
val delete_dir : domain_name:string -> domain_prefix:string -> string -> unit

val list_dir :
  domain_name:string -> domain_prefix:string -> string -> string list

val evict : domain_name:string -> domain_prefix:string -> string -> unit
