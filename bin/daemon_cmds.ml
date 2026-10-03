open Cmdliner
open Tsync_core
open Tsync_ipc
open Tsync_config
open Tsync_owner
open Cli

(* 07 §2.4, §3.1 on macOS: no supervisor. The service process takes the
   governor, starts the store server as its child when a domain is served over
   HTTP, and owns every domain on one socket, which it serves even with no
   domain configured (file-provider §11). *)
(* 07 §2.7: the service log. An agent registered through SMAppService cannot
   name a path under the user's home for its output, so the service opens the
   log itself when it is not run from a terminal. *)
let log_to_service_file () =
  if not (Unix.isatty Unix.stderr) then (
    let dir = Filename.concat (Paths.home ()) "Library/Logs" in
    let rec mkdir_p d =
      if not (Sys.file_exists d) then (
        mkdir_p (Filename.dirname d);
        try Unix.mkdir d 0o755 with Unix.Unix_error (EEXIST, _, _) -> ())
    in
    mkdir_p dir;
    let fd =
      Unix.openfile
        (Filename.concat dir "tsync-daemon.log")
        [O_WRONLY; O_APPEND; O_CREAT; O_CLOEXEC]
        0o644
    in
    Unix.dup2 ~cloexec:false fd Unix.stdout;
    Unix.dup2 ~cloexec:false fd Unix.stderr;
    Unix.close fd)

let macos_service tls (config : Config.t) =
  ignore (Fs.raise_nofile 65536);
  Owner.stop_on_signals ();
  run (fun () ->
      Tsync_store.Uplink.own
        ~state_file:(Filename.concat (Paths.data_dir ()) "uplink.json")
        (fun link -> Config.uplink_settings (Config.link_settings config link));
      let store_server =
        List.filter
          (fun (c : Tsync_supervisor.Supervisor.child) ->
            List.hd c.args = "store-server")
          (Tsync_supervisor.Supervisor.assign ?tls config)
      in
      let children =
        Rt.async (fun () ->
            Tsync_supervisor.Supervisor.keep_running ~exe:Sys.executable_name
              store_server)
      in
      let serve present =
        Owner.run ?present ~shared:true ~socket:(Paths.service_socket ()) config
          config.domains
      in
      Fun.protect
        ~finally:(fun () ->
          Stop.request ();
          Rt.Promise.await children)
        (fun () ->
          match Owner.host_for config.domains with
            | Some host ->
                host ~mount:None config.domains ~run:(fun p -> serve (Some p))
            | None -> serve None))

let no_domains () = Config.of_string {|{"domains":[]}|}

(* 07 §3.1 *)
let start mount tls verbose =
  if Fs.is_macos then log_to_service_file ();
  set_verbose verbose;
  Atomic.set Log.min_level Log.Debug;
  match Paths.read_config () with
    | None when Fs.is_macos ->
        prerr_endline "tsync: no config; serving the menu until one exists";
        macos_service tls (no_domains ())
    | Some text when Fs.is_macos -> (
        match Config.of_string text with
          | exception Config.Invalid e ->
              prerr_endline ("tsync: " ^ e);
              78
          | config -> macos_service tls config)
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
            (* On macOS the service owns every domain and stops its store
               server itself. *)
            let sockets =
              if Fs.is_macos then [Paths.service_socket ()]
              else (
                match config_opt () with
                  | Some c -> owner_sockets c @ [Paths.store_server_socket ()]
                  | None -> [Paths.store_server_socket ()])
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

(* 08 §2.1: [tsync <group> <verb>], resolved to a domain configured with the
   frontend. *)
let frontend_cmds =
  List.filter_map
    (fun name ->
      match Frontend.find name with
        | Some ({ commands = _ :: _; _ } as f) ->
            let group = Option.value ~default:name f.group in
            let verb (c : Frontend.command) =
              let args =
                Arg.(value & pos_all string [] & info [] ~docv:"ARG")
              in
              cmd c.verb ~doc:c.doc
                Term.(
                  const (fun domain_name args verbose ->
                      set_verbose verbose;
                      run (fun () ->
                          let d = domain ?name:domain_name (config ()) in
                          if Config.frontend d name = None then
                            fail "%s is not configured with %s"
                              (Domain_name.to_string d.name)
                              name;
                          c.run ~domain:(Domain_name.to_string d.name) args))
                  $ domain_arg $ args $ verbose)
            in
            Some
              (Cmd.group
                 (Cmd.info group
                    ~doc:("Commands of the " ^ name ^ " frontend."))
                 (List.map verb f.commands))
        | _ -> None)
    (Frontend.names ())

let process_status args =
  match
    Unix.create_process (List.hd args) (Array.of_list args) Unix.stdin
      Unix.stdout Unix.stderr
  with
    | pid -> ( match snd (Unix.waitpid [] pid) with WEXITED n -> n | _ -> 1)
    | exception Unix.Unix_error _ -> 127

(* 07 §2.7: through the service manager, never by signalling a process found
   by name (the macOS service's binary lives in the app bundle). *)
let restart verbose =
  set_verbose verbose;
  if Fs.is_macos then (
    let target =
      Printf.sprintf "gui/%d/org.feverdreamtv.tsync.daemon" (Unix.getuid ())
    in
    if process_status ["/bin/launchctl"; "kickstart"; "-k"; target] <> 0 then
      fail "the tsync service is not installed";
    ignore
      (process_status ["/usr/bin/open"; "-g"; "-b"; "org.feverdreamtv.tsync"]);
    say "Restarted tsync.";
    0)
  else if process_status ["systemctl"; "--user"; "restart"; "tsync"] <> 0 then
    fail "the tsync service is not installed"
  else (
    say "Restarted tsync.";
    0)

let restart_cmd =
  cmd "restart" ~doc:"Restart the service through the service manager."
    Term.(const restart $ verbose)

let cmds =
  [start_cmd; owner_cmd; store_server_cmd; stop_cmd; restart_cmd]
  @ frontend_cmds
