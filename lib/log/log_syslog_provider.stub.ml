(* Selected when the syslog library is absent. Never invoked: Log.Daemon only
   uses this sink when [available] is true. *)

let available = false
let init () = ()
let log (_ : [ `debug | `info | `warn | `err ]) (_ : string) = ()
