(** [cache_root domain_name] returns the local cache directory for a domain,
    under [$XDG_CACHE_HOME/tsync/<domain_name>]. *)
val cache_root : string -> string

(** Map an S3 key to its local cache file path, stripping [domain_prefix] from
    the key before appending to the cache root. *)
val cache_path : domain_name:string -> domain_prefix:string -> string -> string

(** Create all directories needed to hold the file at the given path. *)
val ensure_parent_dir : string -> unit

(** [is_cached ~domain_name ~domain_prefix key] returns [true] if the S3 key's
    corresponding local cache file exists. *)
val is_cached : domain_name:string -> domain_prefix:string -> string -> bool

(** [manifest_path ~domain_name ~domain_prefix key] returns the path to the
    chunk manifest sidecar for an S3 key. Sidecars live under
    [~/.cache/../.manifest/<domain_name>/] so they survive cache eviction. *)
val manifest_path :
  domain_name:string -> domain_prefix:string -> string -> string

(** Persist a chunk manifest string to the sidecar path for the given key. *)
val write_manifest :
  domain_name:string -> domain_prefix:string -> string -> string -> unit

(** Read the chunk manifest sidecar for [key]. Returns [Some (json, mtime)]
    where [mtime] is the sidecar file's modification time, or [None] if absent.
*)
val read_manifest :
  domain_name:string ->
  domain_prefix:string ->
  string ->
  (string * float) option

(** Delete the chunk manifest sidecar for [key], ignoring ENOENT. *)
val delete_manifest :
  domain_name:string -> domain_prefix:string -> string -> unit

(** Delete the cached data file for [key]. The manifest sidecar is kept so that
    [getattr] can still serve size and mtime from it. *)
val evict : domain_name:string -> domain_prefix:string -> string -> unit
