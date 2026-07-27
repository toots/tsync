(** Shared Lwt filesystem helpers for the local cache and local backend. *)

(** Create [path] and any missing parents (mode 0o755); tolerant of races. *)
val mkdir_p : string -> unit Lwt.t

(** [mkdir_p] on the parent directory of [path]. *)
val ensure_parent : string -> unit Lwt.t

(** {!mkdir_p} for callers running before there is an Lwt loop: process startup,
    the CLI, the config writer. *)
val mkdir_p_sync : ?perm:int -> string -> unit

(** [atomic_write path data] writes [data] to a uniquely named temp file in
    [path]'s directory, then renames it over [path]. Safe against concurrent
    writers of the same path, in this process or another. *)
val atomic_write : string -> string -> unit Lwt.t

(** [atomic_write] for a body assembled from pieces: [atomic_write_seq path f]
    calls [f append], and each [append] adds to the temp file. Lets a caller
    build a large body without ever holding it whole in memory. *)
val atomic_write_seq :
  string -> ((string -> unit Lwt.t) -> unit Lwt.t) -> unit Lwt.t

(** [copy_file ~src ~dst] copies [src] over [dst], creating or truncating it. *)
val copy_file : src:string -> dst:string -> unit Lwt.t

(** Directory entries of [path], excluding ["."] and [".."]. *)
val readdir_list : string -> string list Lwt.t

(** [true] if [path] exists and is a directory (following symlinks). *)
val is_directory : string -> bool Lwt.t

(** [stat] as an option: [None] for a path that is absent or cannot be stat'd
    for any other reason. *)
val stat_opt : string -> Unix.stats option Lwt.t

val stat_opt_large : string -> Unix.LargeFile.stats option Lwt.t

(** Delete [path], ignoring a missing file or any other [Unix_error]. *)
val unlink_quiet : string -> unit Lwt.t

(** lstat-based classifier. Returns [`Dir], [`File], [`Symlink target], or
    [`Missing] on any error (dangling link, ENOENT, EACCES, …). *)
val lstat_kind :
  string -> [ `Dir | `File | `Symlink of string | `Missing ] Lwt.t

(** Recursively delete [path]; missing paths and unlink/rmdir errors are
    ignored. Symlinks are removed, not followed. *)
val rm_rf : string -> unit Lwt.t

(** [reap_older_than ~cutoff dir] deletes every file under [dir] whose mtime
    predates [cutoff] and prunes directories left empty, returning [true] when
    [dir] holds nothing afterwards. Best-effort; a missing [dir] reads as empty.
*)
val reap_older_than : cutoff:float -> string -> bool Lwt.t
