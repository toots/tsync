open Cmdliner
open Tsync_core
open Tsync_owner
open Protocol
open Cli

let owner_request ?bulk ~what name req =
  let config = config () in
  let d = domain ?name config in
  (d, Owner.request ?bulk ~what config d req)

let pause on name verbose =
  set_verbose verbose;
  run (fun () ->
      let d, _ =
        owner_request
          ~what:(if on then "tsync pause" else "tsync resume")
          name (Pause on)
      in
      say "%s %s."
        (if on then "Paused" else "Resumed")
        (Domain_name.to_string d.name);
      0)

let pause_cmd name on =
  cmd name
    ~doc:
      (if on then "Hold every change of the domain." else "Resume the domain.")
    Term.(const (pause on) $ domain_arg $ verbose)

(* 08 §2.1: a pulled tree has no replica to resync. *)
let sync full name verbose =
  match
    try Tsync_domain.Domain.pulled (domain ?name (config ()))
    with Exit_with _ -> None
  with
    | Some refusal ->
        prerr_endline ("tsync: " ^ refusal);
        2
    | None -> run_job ?name verbose (Sync { full })

let sync_cmd =
  let full =
    Arg.(value & flag & info ["full"] ~doc:"Rebuild from the store's tree.")
  in
  cmd "sync" ~doc:"Apply other clients' changes now."
    Term.(const sync $ full $ domain_arg $ verbose)

let retry name verbose =
  set_verbose verbose;
  run (fun () ->
      let _, r = owner_request ~what:"tsync retry" name Retry in
      say "%d parked records re-adopted" r;
      0)

let retry_cmd =
  cmd "retry" ~doc:"Retry every parked record now."
    Term.(const retry $ domain_arg $ verbose)

let cmds =
  [
    pause_cmd "pause" true;
    pause_cmd "resume" false;
    pause_cmd "pause-uploads" true;
    pause_cmd "resume-uploads" false;
    sync_cmd;
    retry_cmd;
  ]
