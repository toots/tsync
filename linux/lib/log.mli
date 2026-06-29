(** Open a syslog connection (facility LOG_DAEMON). Falls back to stderr if
    syslog is unavailable. Call once at daemon startup. *)
val init : unit -> unit

val debug : ('a, unit, string, unit) format4 -> 'a
val err : ('a, unit, string, unit) format4 -> 'a
val warn : ('a, unit, string, unit) format4 -> 'a
val info : ('a, unit, string, unit) format4 -> 'a
