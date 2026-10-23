(** The session lock a vault's auto-lock policy may watch on Linux (vault §6.2,
    security-model §10.6), read from logind on the system bus: the [Lock] signal
    of each of this user's sessions, and the manager's [PrepareForSleep] with
    [true]. The [tsync] binary's owner calls it once at start; it starts a fiber
    that calls [on_lock] at each such signal, reconnects after any failure, and
    does nothing when libdbus is not on the system. *)
val watch : on_lock:(unit -> unit) -> unit
