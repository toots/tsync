(* Selected when the syslog library is present. *)

let available = true
let logger : Syslog.t option ref = ref None

let init () =
  try
    logger :=
      Some
        (Syslog.openlog ~facility:`LOG_DAEMON ~flags:[`LOG_PID; `LOG_PERROR]
           "tsync")
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
