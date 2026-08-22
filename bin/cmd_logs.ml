open Cmdliner
open Cli

(* The service manager already keeps and rotates the log, so this hands the
   terminal to the reader it provides rather than shipping lines over IPC. Only
   the daemon's own log — a frontend the OS starts elsewhere (the macOS
   FileProvider extension) logs where the OS decides. *)
let cmd : unit Cmd.t =
  let follow_arg =
    Arg.(
      value & flag & info ["f"; "follow"] ~doc:"Keep printing as lines arrive")
  in
  let lines_arg =
    Arg.(
      value & opt int 200
      & info ["n"; "lines"] ~docv:"N" ~doc:"How many past lines to show")
  in
  let run follow lines =
    let argv = Array.of_list (Runtime.log_command ~follow ~lines) in
    try Unix.execvp argv.(0) argv with
      | Unix.Unix_error (Unix.ENOENT, _, _) ->
          failwith
            (Printf.sprintf
               "%s not found: the daemon logs through syslog, so reading it \
                back needs this system's log reader"
               argv.(0))
      | Unix.Unix_error (e, _, _) ->
          failwith
            (Printf.sprintf "cannot run %s: %s" argv.(0) (Unix.error_message e))
  in
  Cmd.v
    (Cmd.info "logs"
       ~doc:
         "Show the daemon log. On Linux this reads the systemd journal, so it \
          needs systemd-journald; the daemon logs through syslog and keeps no \
          log file of its own. On macOS it reads the LaunchAgent's log file.")
    Term.(const run $ follow_arg $ lines_arg)
