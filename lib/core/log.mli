(** Logging (spec 07 §5.7). The sink is replaceable (syslog, logcat); the last
    50 warnings and errors are kept for status. *)

type level = Debug | Info | Warn | Err

val name : level -> string
val min_level : level Atomic.t

(** Prefixed to every line, such as ["[Files] "]. *)
val prefix : string Atomic.t

val sink : (level -> string -> unit) Atomic.t
val stderr_sink : level -> string -> unit
val debug : ('a, unit, string, unit) format4 -> 'a
val info : ('a, unit, string, unit) format4 -> 'a
val warn : ('a, unit, string, unit) format4 -> 'a
val err : ('a, unit, string, unit) format4 -> 'a
val f : level -> ('a, unit, string, unit) format4 -> 'a

(** Log once per [key] for the life of the process. *)
val once : string -> level -> ('a, unit, string, unit) format4 -> 'a

(** Time, level and message of recent warnings and errors, newest first. *)
val recent : unit -> (float * level * string) list

val timestamp : float -> string
