open Cmdliner
open Tsync_core
open Tsync_ipc
open Tsync_config
open Tsync_owner
open Cli

(* 07 §3.1 *)
let start mount tls verbose =
  set_verbose verbose;
  Atomic.set Log.min_level Log.Debug;
  match Paths.read_config () with
    | None ->
        prerr_endline "tsync: no config; nothing to start";
        0
    | Some text -> (
        match Config.of_string text with
          | exception Config.Invalid e ->
              prerr_endline ("tsync: " ^ e);
              78
          | { domains = []; _ } ->
              prerr_endline "tsync: no domains configured; nothing to start";
              0
          | config -> (
              let refusal =
                List.find_map
                  (fun (d : Config.domain) ->
                    List.find_map
                      (fun (f : Config.frontend) ->
                        Option.bind (Frontend.find f.ftype) (fun r ->
                            r.Frontend.commands_only))
                      d.frontends)
                  config.domains
              in
              match (refusal, mount, config.domains) with
                | Some text, _, _ ->
                    prerr_endline ("tsync: " ^ text);
                    78
                | None, Some _, _ :: _ :: _ ->
                    prerr_endline
                      "tsync: --mount needs exactly one configured domain";
                    1
                | None, _, _ ->
                    ignore (Fs.raise_nofile 65536);
                    Owner.stop_on_signals ();
                    run (fun () ->
                        Tsync_supervisor.Supervisor.run ~exe:Sys.executable_name
                          config
                          (Tsync_supervisor.Supervisor.assign ?mount ?tls config))
              ))

let start_cmd =
  let mount =
    Arg.(
      value
      & opt (some string) None
      & info ["mount"] ~docv:"P" ~doc:"The FUSE mount point of the only domain.")
  and tls =
    Arg.(
      value
      & opt (some string) None
      & info ["tls"] ~docv:"IMPL" ~doc:"native or openssl.")
  in
  cmd "start" ~doc:"Start the owners and serve until stopped."
    Term.(const start $ mount $ tls $ verbose)

let owner names mount tls =
  Atomic.set Log.min_level Log.Debug;
  let config = config_opt () in
  match config with
    | None -> 0
    | Some config -> (
        use_tls config tls;
        let domains = List.map (fun n -> domain ~name:n config) names in
        (match domains with
          | [d] ->
              Atomic.set Log.prefix ("[" ^ Domain_name.to_string d.name ^ "] ")
          | _ -> ());
        ignore (Fs.raise_nofile 65536);
        Owner.stop_on_signals ();
        match Owner.host_for domains with
          | Some host ->
              host ~mount domains ~run:(fun present ->
                  run (fun () -> Owner.run ~present config domains))
          | None -> run (fun () -> Owner.run config domains))

let owner_cmd =
  let names = Arg.(non_empty & opt_all string [] & info ["domain"] ~docv:"NAME")
  and mount = Arg.(value & opt (some string) None & info ["mount"])
  and tls = Arg.(value & opt (some string) None & info ["tls"]) in
  Cmd.v
    (Cmd.info "owner" ~doc:"Own domains (started by tsync start)."
       ~docs:"INTERNAL COMMANDS")
    Term.(const owner $ names $ mount $ tls)

let owner_sockets config =
  List.sort_uniq compare
    (List.map
       (fun (d : Config.domain) -> Paths.owner_socket d.name)
       config.Config.domains)

(* 07 §5.4 *)
let wait_gone socket =
  let deadline = Rt.now () +. Stop.grace +. 2. +. Ipc.request_deadline in
  let rec go () =
    match Ipc.Client.connect socket with
      | c ->
          Ipc.Client.close c;
          if Rt.now () < deadline then (
            Rt.sleep 0.1;
            go ())
          else false
      | exception _ -> true
  in
  go ()

let stop verbose =
  set_verbose verbose;
  run (fun () ->
      let ask socket =
        match Protocol.call socket Stop with
          | _ -> `Asked socket
          | exception Ipc.Not_serving _ -> `Absent
          | exception Fail.E { kind = Deadline; _ } ->
              fail "%s did not answer within %.0fs" socket Ipc.client_deadline
      in
      match ask (Paths.supervisor_socket ()) with
        | `Asked s ->
            if wait_gone s then (
              say "Stopped tsync.";
              0)
            else
              fail
                "still stopping after %.0fs; unfinished work is owed on disk \
                 and resumes at the next start"
                (Stop.grace +. 2. +. Ipc.request_deadline)
        | `Absent -> (
            let sockets =
              match config_opt () with
                | Some c -> owner_sockets c @ [Paths.store_server_socket ()]
                | None -> [Paths.store_server_socket ()]
            in
            let asked =
              List.filter_map
                (function `Asked s -> Some s | `Absent -> None)
                (Rt.map_concurrently ask sockets)
            in
            let stopped =
              List.filter Fun.id (Rt.map_concurrently wait_gone asked)
            in
            match asked with
              | [] ->
                  say "tsync is not running.";
                  0
              | _ ->
                  say "Stopped %d process(es)." (List.length stopped);
                  0))

let stop_cmd = cmd "stop" ~doc:"Stop tsync." Term.(const stop $ verbose)

let store_server tls =
  Atomic.set Log.min_level Log.Debug;
  match config_opt () with
    | None -> 0
    | Some config ->
        use_tls config tls;
        Atomic.set Log.prefix "[http-proxy] ";
        ignore (Fs.raise_nofile 65536);
        Owner.stop_on_signals ();
        run (fun () -> Tsync_http_proxy.Store_server.run config)

let store_server_cmd =
  let tls = Arg.(value & opt (some string) None & info ["tls"]) in
  Cmd.v
    (Cmd.info "store-server"
       ~doc:"Serve the domains' stores over HTTP (started by tsync start)."
       ~docs:"INTERNAL COMMANDS")
    Term.(const store_server $ tls)

let cmds = [start_cmd; owner_cmd; store_server_cmd; stop_cmd]
