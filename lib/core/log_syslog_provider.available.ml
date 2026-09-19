(* Selected when the syslog library is present. *)

let available = true
let logger : Syslog.t option ref = ref None

(* Echoed to stderr only for somebody watching one: under a service manager
   stderr is the journal as well, and every line would be in it twice, the
   second time with the wire format's own priority and date in front. *)
let init () =
  let echo = if Unix.isatty Unix.stderr then [`LOG_PERROR] else [] in
  try
    logger :=
      Some
        (Syslog.openlog ~facility:`LOG_DAEMON ~flags:(`LOG_PID :: echo) "tsync")
  with _ -> ()

let log level msg =
  let level =
    match level with
      | `debug -> `LOG_DEBUG
      | `info -> `LOG_INFO
      | `warn -> `LOG_WARNING
      | `err -> `LOG_ERR
  in
  match !logger with
    | Some l -> ( try Syslog.syslog l level msg with _ -> ())
    | None -> Printf.eprintf "%s\n%!" msg
