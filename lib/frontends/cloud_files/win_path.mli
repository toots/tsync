(** Windows paths as the file system compares them: ignoring case, with either
    separator, and without a trailing one. *)

val same : string -> string -> bool
