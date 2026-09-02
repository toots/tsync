(** Where a domain's local cache keeps things, in one place:

    {v
    <cache_root>/<domain>/manifests/<real path>   published manifest mirror
                                                  (+ .tsync-dir/.tsync-name markers)
    <cache_root>/<domain>/scratch/<real path>     .fuse_hidden* scratch files
    <cache_root>/<domain>/chunks/<xxx>/<key>      cache-chunk store, one file
                                                  per {!Manifest.Group}
    <cache_root>/<domain>/chunks/<xxx>/<key>.manifest   what a partly filled
                                                  one holds; absent once whole
    <cache_root>/<domain>/staged/manifests/<path> staged manifests (unsynced edits)
    <cache_root>/<domain>/staged/chunks/<uuid>    staged bodies, one per
                                                  {!Manifest.Group} in that
                                                  group's own byte layout
    <cache_root>/<domain>/staged/whole/<uuid>     whole files from a frontend
    <cache_root>/<domain>/folders/<folder id>     {parent,name}: the folder tree
                                                  read the other way round
    <cache_root>/<domain>/applied/<YYYY-MM>.log   journal entries this client
                                                  has published or applied
    v}

    The manifest and scratch trees mirror each other by real path. Everything
    under [chunks/] and [staged/] is keyed by content or an opaque id. *)

val manifests_dir : cache_root:string -> string -> string

(** The [.tsync-dir] markers say what id a path has; this tree says where an id
    lives, which is what an item identifier asks. Rebuildable from the markers
    at any time by whoever keeps both. *)
val folders_dir : cache_root:string -> string -> string

val chunks_dir : cache_root:string -> string -> string

(** Where {!Applied_entries} keeps the journal entries this client has already
    published or applied, so "what changed since" is answered without going back
    to the store for entries it once held. *)
val applied_dir : cache_root:string -> string -> string

val staged_manifests_dir : cache_root:string -> string -> string
val staged_chunks_dir : cache_root:string -> string -> string
val staged_whole_dir : cache_root:string -> string -> string

(** Where the trees that mirror real paths keep an item. Each component is
    handed to a filesystem, so {!Stored_key.escape} is applied here and no
    caller spells it; the domain root is the tree itself. *)
val manifest_path :
  cache_root:string -> domain_name:string -> Logical_key.t -> string

val staged_manifest_path :
  cache_root:string -> domain_name:string -> Logical_key.t -> string

val scratch_path :
  cache_root:string -> domain_name:string -> Logical_key.t -> string

(** A cache chunk's path, sharded by {!Chunk_layout} like the backend store. *)
val chunk_path : cache_root:string -> domain_name:string -> string -> string

(** Beside the body, and only while it is incomplete: what a cache chunk holds
    of each stored chunk in it. Its absence is what says a body is whole, so a
    sweep over this tree has to take the pair together or leave a partial body
    reading as a complete one. *)
val chunk_manifest_path :
  cache_root:string -> domain_name:string -> string -> string

(** What {!chunk_manifest_path} adds, for a walk that has to tell the two apart.
*)
val manifest_suffix : string

(** {1 The three that touch the disk}

    A component the filesystem cannot hold is stored as a handle, which is
    lossy, so a directory's real name is written beside it. A file needs no
    marker: its manifest body carries the name. *)

(** {!Fs.S} plus the two marker questions {!Make} answers, which is what a
    module of the checkout takes as its filesystem. *)
module type FS = sig
  include Fs.S

  val record_dir_name : string -> string -> unit io
  val real_dir_name : string -> string -> string io
end

module type S = sig
  type 'a io

  (** Record what a directory stored under a handle is really called, unless it
      is already recorded. Both trees that mirror real paths keep these. *)
  val record_dir_name : string -> string -> unit io

  (** [real_dir_name dir_path name] is [name] itself, or what the marker in
      [dir_path] records when [name] is a handle. *)
  val real_dir_name : string -> string -> string io

  (** Drop everything rebuildable, for a resync that restates the domain from
      the backend. Staged edits are kept: nothing else holds those bytes. *)
  val clear : cache_root:string -> domain_name:string -> unit io
end

module Make
    (Io : Io.S)
    (_ : Fs.S with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t) :
  S with type 'a io := 'a Io.t
