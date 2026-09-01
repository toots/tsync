open Cmdliner

let run () =
  Printexc.record_backtrace true;
  let cmd =
    Cmd.group
      (Cmd.info "tsync" ~doc:"Cloud-backed filesystem sync")
      ([
         Cmd_build_info.cmd;
         Cmd_config.cmd;
         Cmd_restart.cmd;
         Cmd_default_domain.cmd;
         Cmd_start.cmd;
         Cmd_stop.cmd;
         Cmd_logs.cmd;
         Cmd_pause.pause_uploads_cmd;
         Cmd_pause.resume_uploads_cmd;
         Cmd_status.cmd;
         Cmd_sync.cmd;
         Cmd_data_integrity.cmd;
         Cmd_mirror.cmd;
         Cmd_import.cmd;
         Cmd_export.cmd;
         Cmd_rsync.cmd;
         Cmd_cache.cmd;
         Cmd_ls.cmd;
         Cmd_share.cmd;
         Cmd_versions.cmd;
         Cmd_trash.cmd;
         Cmd_expire.cmd;
         Cmd_gc.cmd;
       ]
      @ Cmd_frontends.frontend_cmds ())
  in
  (* Every [failwith] under [Conf_parsing] is phrased for a user: print it, not
     a stack trace. *)
    match Cmd.eval ~catch:false cmd with
    | code -> exit code
    | exception Failure msg ->
        prerr_endline ("tsync: " ^ msg);
        exit 1
    | exception exn ->
        (* Matches what cmdliner's own catch prints. *)
        Printf.eprintf "tsync: internal error, uncaught exception:\n%s\n"
          (Printexc.to_string exn);
        prerr_string (Printexc.get_backtrace ());
        exit Cmd.Exit.internal_error
