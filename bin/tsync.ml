open Cmdliner

let () =
  exit
    (Cmd.eval'
       (Cmd.group
          (Cmd.info "tsync" ~doc:"Synchronise folders through object stores.")
          (Daemon_cmds.cmds @ Status_cmd.cmds @ Domain_cmds.cmds @ Setup_cmds.cmds)))
