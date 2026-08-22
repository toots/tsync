open Cmdliner
open Common

(* Each registered frontend surfaces its commands as `tsync <cli_group> <verb>`,
   the binary owning [--domain] parsing and checking the frontend is configured
   for that domain before handing over. Groups exist only for frontends linked
   into this binary, so `fileprovider` appears on macOS but not Linux. *)
let frontend_cmds () =
  let args_arg =
    Arg.(
      value & pos_all string []
      & info [] ~docv:"ARG" ~doc:"Arguments for the verb, passed through as-is.")
  in
  let run name (command : Frontend.command) domain args =
    let cfg = load_config () in
    let domain =
      match domain with Some _ -> domain | None -> read_default_domain ()
    in
    let d = Conf_parsing.pick_domain ?domain cfg in
    if not (List.mem name (frontend_names d)) then (
      Printf.eprintf "domain %s has no %s frontend\n" d.Conf_parsing.name name;
      exit 1);
    let (module C : Conf.S) = make_conf ?domain cfg in
    command.Frontend.run (module C) args
  in
  List.filter_map
    (fun (name, cli_group, commands) ->
      match commands with
        | [] -> None
        | _ ->
            (* [Term.(...)] opens a module with a [name] of its own, which would
               otherwise shadow the frontend's. *)
            let frontend_name = name in
            let subs =
              List.map
                (fun (command : Frontend.command) ->
                  Cmd.v
                    (Cmd.info command.Frontend.verb ~doc:command.Frontend.doc)
                    Term.(
                      const (run frontend_name command) $ domain_arg $ args_arg))
                commands
            in
            Some
              (Cmd.group
                 (Cmd.info cli_group
                    ~doc:(Printf.sprintf "%s frontend commands" cli_group))
                 subs))
    (Frontend.entries ())
