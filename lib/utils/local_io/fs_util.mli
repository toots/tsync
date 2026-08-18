(** Shared Lwt filesystem helpers for the local cache and local backend. *)

(** Create [path] and any missing parents (mode 0o755); tolerant of races. *)
val mkdir_p : string -> unit Lwt.t

(** [mkdir_p] on the parent directory of [path]. *)
val ensure_parent : string -> unit Lwt.t

(** {!mkdir_p} for callers running before there is an Lwt loop: process startup,
    the CLI, the config writer. *)
val mkdir_p_sync : ?perm:int -> string -> unit

(** A scratch name in [path]'s directory, unique per process and per call. *)
val temp_path : string -> string

(** Whether a name was produced by {!temp_path}.

    Callers walk directories the user also writes to, so the only safe test is
    the one matching what {!temp_path} generates: a wider test — the ".tmp"
    suffix, say — matches a Syncthing download in flight, which the walkers both
    hide and delete. *)
val is_temp_name : string -> bool

(** [atomic_write path data] writes [data] to a uniquely named temp file in
    [path]'s directory, then renames it over [path]. Safe against concurrent
    writers of the same path, in this process or another. *)
val atomic_write : string -> string -> unit Lwt.t

(** [atomic_write] for a body assembled from pieces, each known by position.
    [atomic_write_at path ~size f] sizes the temp file to [size] up front — so a
    full disk fails before the pieces are produced — then calls [f put], where
    [put ~offset data] writes one range. Writes go through [pwrite] and carry
    their own offset, so pieces may be produced and written concurrently and out
    of order, and a large body is never held whole in memory. The rename happens
    only once [f] returns, so a reader never sees a partial body. Every byte of
    [size] must be covered exactly once. *)
val atomic_write_at :
  string ->
  size:int ->
  ((offset:int -> Local_io.buffer -> unit Lwt.t) -> unit Lwt.t) ->
  unit Lwt.t

(** [copy_file ~src ~dst] copies [src] over [dst], creating or truncating it. *)
val copy_file : src:string -> dst:string -> unit Lwt.t

(** Directory entries of [path], excluding ["."] and [".."]. *)
val readdir_list : string -> string list Lwt.t

(** {!readdir_list}, answering [[]] for a directory that is missing or cannot be
    read. For a caller sweeping a layout, where an absent directory and an empty
    one mean the same thing. Only [Unix_error] is swallowed. *)
val readdir_list_quiet : string -> string list Lwt.t

(** [true] if [path] exists and is a directory (following symlinks). *)
val is_directory : string -> bool Lwt.t

(** [stat] as an option: [None] for a path that is absent or cannot be stat'd
    for any other reason. *)
val stat_opt : string -> Unix.stats option Lwt.t

val stat_opt_large : string -> Unix.LargeFile.stats option Lwt.t

(** Delete [path], ignoring a missing file or any other [Unix_error]. *)
val unlink_quiet : string -> unit Lwt.t

(** lstat-based classifier. Returns [`Dir], [`File size], [`Symlink target], or
    [`Missing] on any error (dangling link, ENOENT, EACCES, …). A symlink's own
    size is its target's length and is read with the target instead. *)
val lstat_kind :
  string -> [ `Dir | `File of int64 | `Symlink of string | `Missing ] Lwt.t

(** Recursively delete [path]; missing paths and unlink/rmdir errors are
    ignored. Symlinks are removed, not followed. *)
val rm_rf : string -> unit Lwt.t

(** [reap_older_than ~cutoff dir] deletes every file under [dir] whose mtime
    predates [cutoff] and prunes directories left empty, returning [true] when
    [dir] holds nothing afterwards. Best-effort; a missing [dir] reads as empty.
*)
val reap_older_than : cutoff:float -> string -> bool Lwt.t

(** Capacity of a filesystem, in bytes. [avail] is what an unprivileged writer
    can still use; [free] also counts the margin reserved for root, and is the
    one a used-space figure must be derived from. *)
type disk_space = { avail : int64; free : int64; total : int64 }

(** [disk_space path] is the capacity of the filesystem holding [path], or
    [None] when [path] cannot be stat'd. One syscall: cheap enough to call per
    status request. *)
val disk_space : string -> disk_space option
