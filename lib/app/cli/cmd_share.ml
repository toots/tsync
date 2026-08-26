open Cmdliner
open Common

(* "<N>d" / "<N>h" -> seconds *)
let cmd : unit Cmd.t =
  let path_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let clear_cache_arg =
    Arg.(
      value & flag
      & info ["clear-cache"]
          ~doc:
            "Delete the files the share server has assembled and cached, \
             instead of publishing a link. Published links are not touched and \
             keep working: the next download rebuilds what it needs.")
  in
  let expires_arg =
    Arg.(
      value & opt string "7d"
      & info ["expires"] ~docv:"DUR"
          ~doc:"Link lifetime as $(b,<N>d) or $(b,<N>h) (default 7d)")
  in
  let token_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["token"] ~docv:"HEX"
          ~doc:
            "Reuse this share id instead of generating a random one, keeping \
             an existing link stable. Overwrites any share already at that id. \
             Must be lowercase hex.")
  in
  let clear_cache domain =
    let cfg = load_config () in
    let domain =
      match domain with Some _ -> domain | None -> read_default_domain ()
    in
    let (module C : Conf_lwt.S) = make_conf ?domain cfg in
    let module S = Share_lwt.Make (C) in
    match run_lwt (S.clear_cache ()) with
      | Error msg ->
          Printf.eprintf "%s\n" msg;
          exit 1
      | Ok (0, _) -> print_endline "Nothing cached."
      | Ok (n, bytes) ->
          Printf.printf "Deleted %d cached object%s (%s).\n" n
            (if n = 1 then "" else "s")
            (human_bytes bytes)
  in
  let publish path expires domain token =
    (match token with
      | Some t
        when t = ""
             || String.exists
                  (fun c -> not (String.contains "0123456789abcdef" c))
                  t ->
          Printf.eprintf "--token must be non-empty lowercase hex\n";
          exit 1
      | _ -> ());
    let cfg = load_config () in
    let domain =
      match domain with Some _ -> domain | None -> read_default_domain ()
    in
    let ttl = parse_duration expires in
    let (module C : Conf_lwt.S) = make_conf ?domain cfg in
    let expires = int_of_float (Unix.time () +. ttl) in
    (* Resolve PATH to a domain-relative path; accept an absolute path under the
       mount point too. Empty rel means the whole domain. *)
    let mount_point = mount_point_of (Conf_parsing.pick_domain ?domain cfg) in
    let rel =
      let mp = mount_point ^ "/" in
      if
        String.length path >= String.length mp
        && String.sub path 0 (String.length mp) = mp
      then
        String.sub path (String.length mp)
          (String.length path - String.length mp)
      else path
    in
    let rel =
      if rel <> "" && rel.[String.length rel - 1] = '/' then
        String.sub rel 0 (String.length rel - 1)
      else rel
    in
    let module S = Share_lwt.Make (C) in
    match run_lwt (S.create ?token ~expires ~rel ()) with
      | Error msg ->
          Printf.eprintf "%s\n" msg;
          exit 1
      | Ok url ->
          let tm = Unix.localtime (float_of_int expires) in
          Printf.eprintf "Expires %04d-%02d-%02d %02d:%02d\n"
            (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
            tm.Unix.tm_hour tm.Unix.tm_min;
          print_endline url
  in
  let run path expires domain token clear =
    match (path, clear) with
      | Some path, false -> publish path expires domain token
      | None, true -> clear_cache domain
      | None, false -> failwith "share needs a PATH, or --clear-cache."
      | Some _, true -> failwith "--clear-cache takes no PATH."
  in
  Cmd.v
    (Cmd.info "share"
       ~doc:
         "Print a shareable download URL for a file or folder, or with \
          $(b,--clear-cache), drop what the share server has assembled.")
    Term.(
      const run $ path_arg $ expires_arg $ domain_arg $ token_arg
      $ clear_cache_arg)
