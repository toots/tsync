type level = [ `debug | `info | `warn | `err ]

(** Drop messages below this level. Default: [`info]. *)
val set_min_level : level -> unit

(** Prepend [s] to every subsequent message. Set per-process (e.g. to a domain
    name) so per-domain daemon processes are distinguishable in a shared log. *)
val set_prefix : string -> unit

(** The last 50 emitted [`warn]/[`err] messages, newest first, with the time
    each was logged. For a process reporting on itself — see the http-proxy
    status endpoint, which has no log of its own to point at. *)
val recent : unit -> (float * level * string) list

(** Send every message somewhere else, for a frontend linked into a host process
    with neither a stderr anyone reads nor a syslog: the Android app, whose log
    is logcat. *)
val set_sink : (level -> string -> unit) -> unit

val debug : ('a, unit, string, unit) format4 -> 'a
val info : ('a, unit, string, unit) format4 -> 'a
val warn : ('a, unit, string, unit) format4 -> 'a
val err : ('a, unit, string, unit) format4 -> 'a

(** Daemon preset: syslog when the syslog library is available, else stderr. *)
module Daemon : sig
  val implementation : string
  val init : unit -> unit
end
