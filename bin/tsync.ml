open Cmdliner
open Tsync_core
open Tsync_ipc
open Tsync_config
open Tsync_owner

exception Exit_with of int

let say fmt = Printf.printf (fmt ^^ "\n%!")

let fail fmt =
  Printf.ksprintf
    (fun m ->
      prerr_endline ("tsync: " ^ m);
      raise (Exit_with 1))
    fmt

let config_opt () =
  Option.map
    (fun s -> try Config.of_string s with Config.Invalid e -> fail "%s" e)
    (Paths.read_config ())

let config () =
  match config_opt () with
    | Some c -> c
    | None -> fail "no config at %s" (Paths.config_file ())

let domain ?name config =
  let default =
    match Paths.default_domain () with
      | Some d when Config.find_domain config d = None ->
          Log.warn "the default domain %s is not configured; ignoring it" d;
          None
      | d -> d
  in
  try Config.resolve ?name ?default config
  with Config.Invalid e -> fail "%s" e

(* failure-model §7.5: a classified failure prints its sentence, never a
   trace. *)
let run body =
  Printexc.record_backtrace true;
  match Rt.run_sync body with
    | code -> code
    | exception Exit_with code -> code
    | exception Config.Invalid e ->
        prerr_endline ("tsync: " ^ e);
        1
    | exception e ->
        let f = Fail.classify e in
        prerr_endline
          ("tsync: " ^ f.reason
          ^ Option.fold ~none:"" ~some:(fun r -> " (" ^ r ^ ")") f.repair);
        if f.kind = Fail.Unexplained then 125 else 1

let checked reply =
  match reply with
    | `Assoc l when List.assoc_opt "ok" l = Some (`Bool true) -> reply
    | _ ->
        let code = Option.value ~default:"internal" (Ipc.field reply "code") in
        raise
          (Fail.E
             (Fail.make (Fail.kind_of_code code)
                (Option.value ~default:"failed" (Ipc.field reply "error"))))

let int_field j k =
  match j with
    | `Assoc l -> ( match List.assoc_opt k l with Some (`Int i) -> i | _ -> 0)
    | _ -> 0

let verbose =
  Arg.(value & flag & info ["v"; "verbose"] ~doc:"Log at info level.")

let set_verbose v = if v then Atomic.set Log.min_level Log.Info

let domain_arg =
  Arg.(
    value
    & opt (some string) None
    & info ["d"; "domain"] ~docv:"NAME" ~doc:"The domain to act on.")

let cmd name ~doc term = Cmd.v (Cmd.info name ~doc) term

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
                    let extra =
                      Option.fold ~none:[] ~some:(fun m -> ["--mount"; m]) mount
                      @ Option.fold ~none:[] ~some:(fun t -> ["--tls"; t]) tls
                    in
                    run (fun () ->
                        Tsync_supervisor.Supervisor.run ~exe:Sys.executable_name
                          (Tsync_supervisor.Supervisor.assign ~extra config))))

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

let owner names mount _tls =
  Atomic.set Log.min_level Log.Debug;
  let config = config_opt () in
  match config with
    | None -> 0
    | Some config -> (
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
        match Ipc.call socket (`Assoc [("action", `String "stop")]) with
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

(* 07 §5.5 *)
let status json verbose =
  set_verbose verbose;
  run (fun () ->
      let report =
        match
          Ipc.call
            (Paths.supervisor_socket ())
            (`Assoc [("action", `String "stats")])
        with
          | r -> r
          | exception Ipc.Not_serving _ ->
              let config = config () in
              let domains =
                Rt.map_concurrently
                  (fun (d : Config.domain) ->
                    let name = Domain_name.to_string d.name in
                    match
                      Ipc.call
                        (Paths.owner_socket d.name)
                        (`Assoc
                           [
                             ("action", `String "stats");
                             ("domain", `String name);
                             ("arg", `String "frontend");
                           ])
                    with
                      | `Assoc l -> (
                          match List.assoc_opt "domains" l with
                            | Some (`List ds) -> ds
                            | _ -> [])
                      | _ | (exception _) ->
                          [
                            `Assoc
                              [
                                ("name", `String name);
                                ("unanswered", `Bool true);
                              ];
                          ])
                  config.domains
              in
              Ipc.ok
                [
                  ("host", `String (Unix.gethostname ()));
                  ("domains", `List (List.concat domains));
                ]
      in
      (if json then
         print_endline
           (Yojson.Safe.pretty_to_string
              (match report with
                | `Assoc l -> `Assoc (("t", `Float (Unix.gettimeofday ())) :: l)
                | j -> j))
       else
         let open Yojson.Safe.Util in
         say "tsync on %s" (report |> member "host" |> to_string);
         List.iter
           (fun d ->
             let name = d |> member "name" |> to_string in
             if d |> member "unanswered" = `Bool true then
               say "  %s: NOT ANSWERING" name
             else (
               let paused = d |> member "paused" = `Bool true in
               let sync = d |> member "sync" in
               let queues = d |> member "queues" in
               say "  %s%s" name (if paused then "  PAUSED" else "");
               (match sync |> member "state" with
                 | `String "hold" ->
                     say "    sync held: %s"
                       (sync |> member "reason" |> to_string_option
                      |> Option.value ~default:"")
                 | _ -> ());
               let n = int_field queues "pendingFiles" in
               if n > 0 then say "    %d uploads pending" n;
               let n = int_field queues "pendingMetadata" in
               if n > 0 then say "    %d metadata changes pending" n))
           (report |> member "domains" |> to_list));
      0)

let status_cmd =
  let json =
    Arg.(value & flag & info ["json"] ~doc:"Print the report as JSON.")
  in
  cmd "status" ~doc:"Report what tsync is doing."
    Term.(const status $ json $ verbose)

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

let show_config () =
  run (fun () ->
      let config = config () in
      let backend (b : Config.backend) =
        let specs =
          Option.fold ~none:[]
            ~some:(fun (d : Tsync_store.Driver.t) -> d.fields)
            (Tsync_store.Driver.find b.btype)
        in
        `Assoc
          ([
             ("type", `String b.btype);
             ("name", `String b.bname);
             ("role", `String (Tsync_store.Composite.role_to_string b.role));
           ]
          @ Option.fold ~none:[] ~some:(fun l -> [("link", `String l)]) b.link
          @ Config.masked_fields ~specs b.fields)
      in
      let frontend (f : Config.frontend) =
        let specs =
          Option.fold ~none:[]
            ~some:(fun (r : Frontend.t) -> r.fields)
            (Frontend.find f.ftype)
        in
        `Assoc
          (("type", `String f.ftype) :: Config.masked_fields ~specs f.options)
      in
      print_endline
        (Yojson.Safe.pretty_to_string
           (`Assoc
              [
                ("name", `String config.client_name);
                ( "domains",
                  `List
                    (List.map
                       (fun (d : Config.domain) ->
                         `Assoc
                           [
                             ("name", `String (Domain_name.to_string d.name));
                             ("readOnly", `Bool d.read_only);
                             ("backends", `List (List.map backend d.backends));
                             ("frontends", `List (List.map frontend d.frontends));
                           ])
                       config.domains) );
              ]));
      0)

let config_cmd =
  cmd "config" ~doc:"Print the config, secrets masked."
    Term.(const show_config $ const ())

let default_domain name clear =
  run (fun () ->
      let file = Paths.default_domain_file () in
      match (name, clear) with
        | _, true ->
            ignore (Fs.release file);
            0
        | Some n, false ->
            let config = config () in
            if Config.find_domain config n = None then
              fail "%s is not configured" n;
            Fs.mkdir_p ~perm:0o700 (Filename.dirname file);
            Fs.durable_replace file (n ^ "\n");
            0
        | None, false -> (
            match Paths.default_domain () with
              | Some d ->
                  say "%s" d;
                  0
              | None -> 1))

let default_domain_cmd =
  let name = Arg.(value & pos 0 (some string) None & info [] ~docv:"NAME")
  and clear = Arg.(value & flag & info ["clear"]) in
  cmd "default-domain" ~doc:"Set, clear or print the default domain."
    Term.(const default_domain $ name $ clear)

let build_info () =
  say "frontends: %s" (String.concat ", " (Frontend.names ()));
  say "drivers: %s" (String.concat ", " (Tsync_store.Driver.names ()));
  say "log sink: stderr";
  say "config: %s" (Paths.config_file ());
  say "data: %s" (Paths.data_dir ());
  say "cache: %s" (Paths.cache_root ());
  say "supervisor socket: %s" (Paths.supervisor_socket ());
  say "store-server socket: %s" (Paths.store_server_socket ());
  0

let build_info_cmd =
  cmd "build-info"
    ~doc:"What this binary includes, and where it keeps its state."
    Term.(const build_info $ const ())

let logs follow lines =
  let args =
    if Fs.is_macos then
      ["tail"; "-n"; string_of_int lines]
      @ (if follow then ["-f"] else [])
      @ [Filename.concat (Paths.home ()) "Library/Logs/tsync-daemon.log"]
    else
      ["journalctl"; "-t"; "tsync"; "-n"; string_of_int lines]
      @ if follow then ["-f"] else []
  in
  try Unix.execvp (List.hd args) (Array.of_list args)
  with Unix.Unix_error (e, _, _) ->
    Printf.eprintf "tsync: cannot run %s: %s\n" (List.hd args)
      (Unix.error_message e);
    1

let logs_cmd =
  let follow = Arg.(value & flag & info ["f"])
  and lines = Arg.(value & opt int 200 & info ["n"]) in
  cmd "logs" ~doc:"Show the daemon's log." Term.(const logs $ follow $ lines)

let () =
  let main =
    Cmd.group
      (Cmd.info "tsync" ~doc:"Synchronise folders through object stores.")
      [
        start_cmd;
        owner_cmd;
        stop_cmd;
        status_cmd;
        pause_cmd "pause" true;
        pause_cmd "resume" false;
        pause_cmd "pause-uploads" true;
        pause_cmd "resume-uploads" false;
        sync_cmd;
        retry_cmd;
        config_cmd;
        default_domain_cmd;
        build_info_cmd;
        logs_cmd;
      ]
  in
  exit (Cmd.eval' main)
