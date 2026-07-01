let implementation = "syslog"
let logger : Syslog.t option ref = ref None

let init () =
  try
    logger :=
      Some
        (Syslog.openlog ~facility:`LOG_DAEMON ~flags:[`LOG_PID; `LOG_PERROR]
           "tsync")
  with _ -> ()

let log level fmt =
  Printf.ksprintf
    (fun msg ->
      match !logger with
        | Some l -> ( try Syslog.syslog l level msg with _ -> ())
        | None -> Printf.eprintf "%s\n%!" msg)
    fmt

let debug fmt = log `LOG_DEBUG fmt
let info fmt = log `LOG_INFO fmt
let warn fmt = log `LOG_WARNING fmt
let err fmt = log `LOG_ERR fmt
