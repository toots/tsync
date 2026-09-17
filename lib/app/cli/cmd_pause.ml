open Cmdliner
open Common

(* Downloads are not held: one runs because something is blocked waiting for
   it, which is the reader's own request and not a change to the domain. *)
let pause_cmd ~verb ~arg ~done_ ~doc =
  let run domain =
    try
      let name, socket_path = domain_target ?domain () in
      let (_ : (string * Yojson.Safe.t) list) =
        Ipc.action ~socket_path ~domain:name ~arg "pause"
      in
      Printf.printf "Changes %s for '%s'\n" done_ name
    with e ->
      Printf.eprintf "Error: %s\n" (Printexc.to_string e);
      exit 1
  in
  Cmd.v (Cmd.info verb ~doc) Term.(const run $ domain_arg)

let pause_doc =
  "Hold every change: nothing is uploaded, nothing is published, and what \
   peers did is not applied. Reading a file still fetches it."

let pause_cmds : unit Cmd.t list =
  [
    pause_cmd ~verb:"pause" ~arg:"on" ~done_:"held" ~doc:pause_doc;
    pause_cmd ~verb:"resume" ~arg:"off" ~done_:"resumed"
      ~doc:"Let changes flow again";
    (* The verbs this switch had when it held uploads alone. *)
    pause_cmd ~verb:"pause-uploads" ~arg:"on" ~done_:"held" ~doc:pause_doc;
    pause_cmd ~verb:"resume-uploads" ~arg:"off" ~done_:"resumed"
      ~doc:"Let changes flow again";
  ]
