open Cmdliner
open Tsync_core
open Tsync_config
open Cli

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

let cmds = [config_cmd; default_domain_cmd; build_info_cmd; logs_cmd]
