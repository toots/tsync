(** Shared Lwt filesystem helpers for the local cache and local backend. *)

(** Create [path] and any missing parents (mode 0o755); tolerant of races. *)
val mkdir_p : string -> unit Lwt.t

(** [mkdir_p] on the parent directory of [path]. *)
val ensure_parent : string -> unit Lwt.t

(** Directory entries of [path], excluding ["."] and [".."]. *)
val readdir_list : string -> string list Lwt.t

(** [true] if [path] exists and is a directory (following symlinks). *)
val is_directory : string -> bool Lwt.t

(** Recursively delete [path]; missing paths and unlink/rmdir errors are
    ignored. Symlinks are removed, not followed. *)
val rm_rf : string -> unit Lwt.t
