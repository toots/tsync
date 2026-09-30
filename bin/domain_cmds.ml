open Cmdliner
open Tsync_core
open Tsync_ipc
open Tsync_owner
open Cli

let owner_request ?bulk ~what name req =
  let config = config () in
  let d = domain ?name config in
  (d, checked (Owner.request ?bulk ~what config d req))

let pause on name verbose =
  set_verbose verbose;
  run (fun () ->
      let d, _ =
        owner_request
          ~what:(if on then "tsync pause" else "tsync resume")
          name
          (`Assoc
             [
               ("action", `String "pause");
               ("arg", `String (if on then "on" else "off"));
             ])
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

let sync full name verbose =
  set_verbose verbose;
  run (fun () ->
      let _, r =
        owner_request ~bulk:true
          ~what:(if full then "tsync sync --full" else "tsync sync")
          name
          (`Assoc
             [
               ("action", `String "sync");
               ("arg", `String (if full then "full" else ""));
             ])
      in
      match Ipc.field r "mode" with
        | Some "full" ->
            let failed = int_field r "failed" in
            say "full resync: %d manifests%s" (int_field r "manifests")
              (if failed > 0 then Printf.sprintf " (%d failed)" failed else "");
            if failed > 0 then 1 else 0
        | _ ->
            say "%d journal entries from other clients" (int_field r "applied");
            0)

let sync_cmd =
  let full =
    Arg.(value & flag & info ["full"] ~doc:"Rebuild from the store's tree.")
  in
  cmd "sync" ~doc:"Apply other clients' changes now."
    Term.(const sync $ full $ domain_arg $ verbose)

let retry name verbose =
  set_verbose verbose;
  run (fun () ->
      let _, r =
        owner_request ~what:"tsync retry" name
          (`Assoc [("action", `String "retry")])
      in
      say "%d parked records re-adopted" (int_field r "readopted");
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
