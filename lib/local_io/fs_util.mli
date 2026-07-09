(** Shared Lwt filesystem helpers for the local cache and local backend. *)

(** Percent-encode FAT/exFAT/NTFS-reserved characters and control characters in
    each slash-delimited component of a key, leaving "/" intact. Used so paths
    derived from arbitrary keys are valid on any local filesystem. *)
val encode_key : string -> string

(** Reverse of [encode_key]: decode [%XX] sequences in each component. *)
val decode_key : string -> string

(** Decode a single path component (between slashes). *)
val decode_component : string -> string

(** Create [path] and any missing parents (mode 0o755); tolerant of races. *)
val mkdir_p : string -> unit Lwt.t

(** [mkdir_p] on the parent directory of [path]. *)
val ensure_parent : string -> unit Lwt.t

(** Directory entries of [path], excluding ["."] and [".."]. *)
val readdir_list : string -> string list Lwt.t

(** [true] if [path] exists and is a directory (following symlinks). *)
val is_directory : string -> bool Lwt.t

(** lstat-based classifier. Returns [`Dir], [`File], [`Symlink target], or
    [`Missing] on any error (dangling link, ENOENT, EACCES, …). *)
val lstat_kind :
  string -> [ `Dir | `File | `Symlink of string | `Missing ] Lwt.t

(** Recursively delete [path]; missing paths and unlink/rmdir errors are
    ignored. Symlinks are removed, not followed. *)
val rm_rf : string -> unit Lwt.t
