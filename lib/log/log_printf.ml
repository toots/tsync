let implementation = "printf"
let init () = ()

let use_color = Unix.isatty Unix.stderr

let timestamp () =
  let t = Unix.gettimeofday () in
  let tm = Unix.localtime t in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

let log level fmt =
  let label, color =
    match level with
      | `debug -> ("DEBUG", "\027[36m")
      | `info  -> ("INFO ", "\027[32m")
      | `warn  -> ("WARN ", "\027[33m")
      | `err   -> ("ERROR", "\027[31m")
  in
  Printf.ksprintf
    (fun msg ->
      let ts = timestamp () in
      if use_color then
        Printf.eprintf "%s %s%s\027[0m %s\n%!" ts color label msg
      else
        Printf.eprintf "%s %s %s\n%!" ts label msg)
    fmt

let debug fmt = log `debug fmt
let info fmt  = log `info fmt
let warn fmt  = log `warn fmt
let err fmt   = log `err fmt
