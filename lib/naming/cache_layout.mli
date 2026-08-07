(** Where a domain's local cache keeps things, in one place:

    {v
    <cache_root>/<domain>/manifests/<real path>   published manifest mirror
                                                  (+ .tsync-dir/.tsync-name markers)
    <cache_root>/<domain>/scratch/<real path>     .fuse_hidden* scratch files
    <cache_root>/<domain>/chunks/<xxx>/<key>      cache-chunk store, one file
                                                  per {!Chunk_group}
    <cache_root>/<domain>/staged/manifests/<path> staged manifests (unsynced edits)
    <cache_root>/<domain>/staged/chunks/<uuid>    staged chunk bodies
    <cache_root>/<domain>/staged/whole/<uuid>     whole files from a frontend
    <cache_root>/<domain>/folders/<folder id>     {parent,name}: the folder tree
                                                  read the other way round
    v}

    The manifest and scratch trees mirror each other by real path. Everything
    under [chunks/] and [staged/] is keyed by content or an opaque id. *)

val manifests_dir : cache_root:string -> string -> string
val scratch_dir : cache_root:string -> string -> string

(** The [.tsync-dir] markers say what id a path has; this tree says where an id
    lives, which is what an item identifier asks. Rebuildable from the markers
    at any time — see {!Folder_ids.rebuild}. *)
val folders_dir : cache_root:string -> string -> string

val chunks_dir : cache_root:string -> string -> string
val staged_manifests_dir : cache_root:string -> string -> string
val staged_chunks_dir : cache_root:string -> string -> string
val staged_whole_dir : cache_root:string -> string -> string

(** A cache chunk's path, sharded by {!Chunk_layout} like the backend store. *)
val chunk_path : cache_root:string -> domain_name:string -> string -> string

(** Drop everything rebuildable, for a resync that restates the domain from the
    backend. Staged edits are kept: nothing else holds those bytes. *)
val clear : cache_root:string -> domain_name:string -> unit Lwt.t
