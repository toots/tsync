open Cmdliner
open Cli

let cmd : unit Cmd.t =
  let run () =
    if Runtime.restart_service () then print_endline "Restarted."
    else begin
      prerr_endline "Could not restart: the tsync service is not installed.";
      exit 1
    end
  in
  Cmd.v
    (Cmd.info "restart"
       ~doc:"Restart the background service so it re-reads the config")
    Term.(const run $ const ())
