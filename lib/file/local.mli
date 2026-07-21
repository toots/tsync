val manifest_dir : cache_root:string -> string -> string

(** Remove the domain's entire local cache (manifest mirror + downloaded data),
    for a full resync that rebuilds it from the backend. *)
val clear : cache_root:string -> domain_name:string -> unit Lwt.t

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

(** Rewrite a moved directory's escaped-name marker to its current leaf name, so
    readdir shows the new name (no-op unless the leaf is escaped). *)
val refresh_dir_marker :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  unit Lwt.t

(** All manifest sidecars under the domain's manifest tree, as domain-relative
    paths (unsorted). Empty when the tree does not exist. *)
val walk_manifests :
  cache_root:string -> domain_name:string -> unit -> string list Lwt.t

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

val write_manifest :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  string ->
  unit Lwt.t

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

val list_directory :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  prefix:string ->
  unit ->
  (Backend.file_entry list * string list) Lwt.t

val list_all :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  prefix:string ->
  unit ->
  Backend.file_entry list Lwt.t

val evict :
  cache_root:string ->
  domain_name:string ->
  domain_prefix:string ->
  string ->
  unit Lwt.t
