open Cmdliner
open Cli

(* What this binary is and where it keeps things, as against [tsync config],
   which is what the operator asked of it. Neither answers the other's question
   and a report usually wants both. *)
let cmd : unit Cmd.t =
  let features () =
    Printf.printf "frontends: %s\ns3 backend: %b\nlog: %s\n"
      (String.concat ", " (Frontend.names ()))
      S3_link.s3_backend_enabled Log.Daemon.implementation
  in
  let paths () =
    let p = runtime_paths in
    Printf.printf "config:  %s\n" p.Runtime.config_path;
    Printf.printf "cache:   %s\n" p.Runtime.cache_root;
    Printf.printf "data:    %s\n" p.Runtime.data_dir;
    (* Per domain, since that is how many there are: one each under FUSE, the
       same one repeated on macOS. *)
    List.iter
      (fun (name, socket) -> Printf.printf "socket:  %s (%s)\n" socket name)
      (try domain_targets () with _ -> [])
  in
  let run () =
    features ();
    print_newline ();
    paths ()
  in
  Cmd.v
    (Cmd.info "build-info"
       ~doc:
         "Show what was compiled into this binary and the filesystem paths it \
          uses.")
    Term.(const run $ const ())
