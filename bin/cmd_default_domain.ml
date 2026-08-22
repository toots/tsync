open Cmdliner
open Cli

let cmd : unit Cmd.t =
  let name_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"NAME")
  in
  let clear_arg =
    Arg.(value & flag & info ["clear"] ~doc:"Forget the default domain")
  in
  let show () =
    match read_default_domain () with
      | Some name -> print_endline name
      | None ->
          Printf.eprintf "No default domain set.\n";
          exit 1
  in
  let forget () =
    (try Unix.unlink (default_domain_file ())
     with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
    print_endline "Default domain cleared."
  in
  let set name =
    let cfg = load_config () in
    match
      List.find_opt
        (fun (d : Conf_parsing.domain) -> d.name = name)
        cfg.Conf_parsing.domains
    with
      | None ->
          Printf.eprintf "Domain not found: %s\n" name;
          exit 1
      | Some _ ->
          let file = default_domain_file () in
          Fs_util.mkdir_p_sync (Filename.dirname file);
          let oc = open_out file in
          output_string oc (name ^ "\n");
          close_out oc;
          Printf.printf "Default domain set to: %s\n" name
  in
  let run name clear =
    match (name, clear) with
      | None, false -> show ()
      | None, true -> forget ()
      | Some _, true -> failwith "--clear takes no domain name."
      | Some name, false -> set name
  in
  Cmd.v
    (Cmd.info "default-domain"
       ~doc:
         "Print the domain used when $(b,--domain) is omitted. Name one to set \
          it, or $(b,--clear) to forget it.")
    Term.(const run $ name_arg $ clear_arg)
