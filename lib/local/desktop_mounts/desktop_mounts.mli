(** Which of this machine's mounts are tsync's, for a desktop asking whether a
    path it was handed is one of ours.

    Answered here rather than by whatever asks: where a domain mounts and where
    its daemon listens are this project's rules, and a file-manager extension
    that restated them would drift the moment either changed. *)

(** Every configured domain whose filesystem is mounted now, as
    [(mount point, socket path)]. A domain configured but not mounted is absent:
    the question is what a user can right-click, not what the config hopes for.

    Total. Callers reach this across a C boundary where an exception is a crash,
    so an unreadable config or mount table is an empty list. *)
val mount_points : unit -> (string * string) list

(** {!mount_points} with its inputs named, for tests. [mountinfo] is in the
    format of {i /proc/self/mountinfo}. *)
val mount_points_in :
  config_path:string ->
  mountinfo:string ->
  paths:Runtime.paths ->
  (string * string) list
