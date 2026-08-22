open Cmdliner
open Cli

(* Uploads only: a download runs because something is blocked waiting for it. *)
let pause_cmd ~verb ~arg ~done_ ~doc =
  let run domain =
    try
      let name, socket_path = domain_target ?domain () in
      let (_ : (string * Yojson.Safe.t) list) =
        Ipc.action ~socket_path ~domain:name ~arg "pause"
      in
      Printf.printf "Uploads %s for '%s'\n" done_ name
    with e ->
      Printf.eprintf "Error: %s\n" (Printexc.to_string e);
      exit 1
  in
  Cmd.v (Cmd.info verb ~doc) Term.(const run $ domain_arg)

let pause_uploads_cmd : unit Cmd.t =
  pause_cmd ~verb:"pause-uploads" ~arg:"on" ~done_:"paused"
    ~doc:"Pause uploads (queued work is kept)"

let resume_uploads_cmd : unit Cmd.t =
  pause_cmd ~verb:"resume-uploads" ~arg:"off" ~done_:"resumed"
    ~doc:"Resume paused uploads"
