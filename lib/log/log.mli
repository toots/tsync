type level = [ `debug | `info | `warn | `err ]

(** Drop messages below this level. Default: [`info]. *)
val set_min_level : level -> unit

(** Swap the active sink: a function receiving the level and the fully formatted
    message. Default sink is [printf]. *)
val use : (level -> string -> unit) -> unit

(** Built-in sink: timestamped, colorized lines on stderr. *)
val printf : level -> string -> unit

val debug : ('a, unit, string, unit) format4 -> 'a
val info : ('a, unit, string, unit) format4 -> 'a
val warn : ('a, unit, string, unit) format4 -> 'a
val err : ('a, unit, string, unit) format4 -> 'a

(** Daemon preset: syslog when the syslog library is available, else stderr. *)
module Daemon : sig
  val available : bool
  val implementation : string
  val init : unit -> unit
end
