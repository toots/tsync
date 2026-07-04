(** Fraction (0..1) of the filesystem holding [path] that is free, as seen by an
    unprivileged process ([f_bavail / f_blocks]). Raises [Unix.Unix_error] when
    [path] cannot be examined. *)
val free_fraction : string -> float
