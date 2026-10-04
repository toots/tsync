open Cmdliner
open Tsync_core

let main verbose =
  Atomic.set Log.min_level (if verbose then Log.Debug else Log.Warn);
  Atomic.set Log.sink Log.stderr_sink;
  Fs.ignore_sigpipe ();
  Rt.run_sync Tsync_tray_lib.Tray.run

let verbose = Arg.(value & flag & info ["v"; "verbose"] ~doc:"Log debug lines.")

let () =
  let info =
    Cmd.info "tsync-tray" ~version:"%%VERSION%%"
      ~doc:"Show the state of tsync's domains in the notification area."
  in
  match Cmd.eval_value (Cmd.v info Term.(const main $ verbose)) with
    | Ok (`Ok code) -> exit code
    | Ok (`Help | `Version) -> exit 0
    | Error _ -> exit 1
