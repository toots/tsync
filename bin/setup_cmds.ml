open Cmdliner
open Tsync_core
open Tsync_config
open Cli

(* The printed config's JSON form; secrets read ***. *)
let shown fields =
  List.map
    (fun (k, (v : Config.shown)) ->
      ( k,
        match v with
          | Secret -> `String "***"
          | Shown (S s) -> `String s
          | Shown (B b) -> `Bool b
          | Shown (I i) -> `Int i
          | Shown (F f) -> `Float f
          | Shown (L l) -> `List (List.map (fun s -> `String s) l) ))
    fields

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
          @ shown (Config.masked_fields ~specs b.fields))
      in
      let frontend (f : Config.frontend) =
        let specs =
          Option.fold ~none:[]
            ~some:(fun (r : Frontend.t) -> r.fields)
            (Frontend.find f.ftype)
        in
        `Assoc
          (("type", `String f.ftype)
          :: shown (Config.masked_fields ~specs f.options))
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

(* 07 §5.9: secrets are read with the terminal's echo off. *)
let terminal_io : Config_wizard.io =
  let ask (p : Config_wizard.prompt) =
    Printf.printf "%s%s: %!" p.label
      (match p.default with Some d -> " [" ^ d ^ "]" | None -> "");
    let echo_off = p.secret && Unix.isatty Unix.stdin in
    let saved = if echo_off then Some (Unix.tcgetattr Unix.stdin) else None in
    Option.iter
      (fun a -> Unix.tcsetattr Unix.stdin TCSANOW { a with c_echo = false })
      saved;
    let line =
      Fun.protect
        ~finally:(fun () ->
          Option.iter (fun a -> Unix.tcsetattr Unix.stdin TCSANOW a) saved;
          if echo_off then print_newline ())
        (fun () ->
          try input_line stdin with End_of_file -> raise (Exit_with 1))
    in
    line
  in
  { ask; say = print_endline }

let edit_config () =
  run (fun () ->
      let path = Paths.config_file () in
      let current =
        match Fs.read_file_opt path with
          | None -> None
          | Some text -> (
              match Yojson.Safe.from_string text with
                | j -> Some j
                | exception Yojson.Json_error e ->
                    fail "%s is not valid JSON (%s); fix it by hand first" path
                      e)
      in
      match Config_wizard.edit terminal_io current with
        | None ->
            say "nothing written";
            0
        | Some j -> (
            match Config_wizard.prepare j with
              | Error e -> fail "not written: %s" e
              | Ok j ->
                  Fs.mkdir_p (Filename.dirname path);
                  Fs.durable_replace ~perm:0o600 path
                    (Yojson.Safe.pretty_to_string j ^ "\n");
                  say "written to %s; run tsync restart to apply it" path;
                  0))

let config_cmd =
  let edit =
    Arg.(value & flag & info ["edit"] ~doc:"Edit the config through prompts.")
  in
  cmd "config" ~doc:"Print the config, secrets masked, or edit it."
    Term.(
      const (fun edit -> if edit then edit_config () else show_config ()) $ edit)

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
