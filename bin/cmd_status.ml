open Cmdliner
open Cli

let cmd : unit Cmd.t =
  let watch_arg =
    Arg.(
      value
      & opt (some float) None
      & info ["w"; "watch"] ~docv:"SECONDS"
          ~doc:"Poll and redraw every $(docv) seconds")
  in
  let json_arg =
    Arg.(
      value & flag
      & info ["json"]
          ~doc:"Output raw JSON, one object per answering daemon per line")
  in
  let totals_arg =
    Arg.(
      value & flag
      & info ["totals"]
          ~doc:
            "Also report what each backend holds. The chunk count is estimated \
             from a sample of the store's shards; the manifest count is a full \
             listing. See $(b,--exact).")
  in
  let exact_arg =
    Arg.(
      value & flag
      & info ["exact"]
          ~doc:
            "With $(b,--totals), count every chunk instead of estimating from \
             a sample. Enumerates the whole chunk namespace, so it costs a \
             full listing per backend.")
  in
  let reload_arg =
    Arg.(
      value & flag
      & info ["reload"]
          ~doc:
            "With $(b,--totals), recount instead of reporting what was counted \
             before. A store is counted once and that figure served from then \
             on, with its age, until this asks for a new one.")
  in
  let run json totals exact reload watch =
    (* The daemon counts a store once and serves that until asked again, so the
       flags travel as a set, not a mode. *)
    let arg =
      match totals || exact || reload with
        | false -> None
        | true ->
            Some
              (String.concat ","
                 (["totals"]
                 @ (if exact then ["exact"] else [])
                 @ if reload then ["reload"] else []))
    in
    (* Resolved once: [--watch] must not re-read the config per tick, and a
       config error should surface before the screen starts clearing. *)
    let sync_socket = Runtime.sync_socket_path runtime_paths in
    let targets =
      List.filter (fun (_, s) -> s <> sync_socket) (domain_targets ())
    in
    (* The process converging the domains holds the whole picture and answers
       with it. Asking every frontend instead costs each of them a probe of
       every backend for the same figures, so that is what a machine without one
       falls back to, not what it does. *)
    let collect () =
      let open Lwt.Syntax in
      Lwt_main.run
        (let* sync =
           Status_report.ask ?arg ~frontend:"sync" ~domain:""
             ~socket_path:sync_socket ()
         in
         (* The finished report, recognised by carrying one: a daemon too old to
            assemble it answers for itself instead, and falls to the sweep
            below with every other frontend. *)
           match sync.Status_report.reply with
           | `Assoc fields when List.mem_assoc "processes" fields ->
               Lwt.return (`Assoc (List.remove_assoc "ok" fields))
           | _ ->
               (* One round trip per configured frontend, each under
                  {!Status_report.ask}'s deadline: the width is the config's,
                  not a caller's. *)
               let+ answers =
                 Lwt_list.map_p
                   (fun (name, socket_path) ->
                     Status_report.ask ?arg ~frontend:"" ~domain:name
                       ~socket_path ())
                   targets
               in
               Status_report.of_answers answers)
    in
    let show () =
      let report = collect () in
      if json then
        print_endline
          (Yojson.Safe.to_string
             (`Assoc
                (("t", `Float (Unix.gettimeofday ()))
                :: (match report with `Assoc obj -> obj | _ -> []))))
      else print_string (Status_report.text report)
    in
    match watch with
      | None -> show ()
      | Some interval ->
          while true do
            if not json then print_string "\027[2J\027[H";
            show ();
            flush stdout;
            Unix.sleepf interval
          done
  in
  Cmd.v
    (Cmd.info "status"
       ~doc:
         "Report on the running daemons: transfer metrics, config as resolved, \
          cache, journal backlog and each backend's health. Covers every \
          configured domain.")
    Term.(
      const run $ json_arg $ totals_arg $ exact_arg $ reload_arg $ watch_arg)
