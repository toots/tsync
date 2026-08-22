open Cmdliner
open Cli

let cmd : unit Cmd.t =
  let mount_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["mount"] ~docv:"PATH" ~doc:"Mount point (default: ~/tsync/DOMAIN)")
  in
  let tls_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["tls"] ~docv:"native|openssl"
          ~doc:
            "Override the TLS backend for S3 connections. OpenSSL is much \
             faster and is used by default when available; native tls is a \
             fallback that resolves connection issues with some endpoints \
             (e.g. Backblaze B2). Default: from config, then the preferred \
             available backend.")
  in
  let run mount tls =
    Log.Daemon.init ();
    Log.debug "loading config from %s" runtime_paths.Runtime.config_path;
    (* Not a failure: the installer starts the service before the user has
       configured anything. Exit 0 so launchd/systemd does not respawn. *)
    if not (Sys.file_exists runtime_paths.Runtime.config_path) then begin
      Printf.eprintf
        "No config at %s. Run `tsync config --edit`, then `tsync restart`.\n"
        runtime_paths.Runtime.config_path;
      exit 0
    end;
    let cfg = load_config () in
    (* CLI --tls wins over the config value applied by make_conf, which is also
       what reports the choice: doing it here would name conduit's default,
       the config not having been read yet. *)
    if tls <> None then Tls_conf.apply tls;
    let domains =
      if cfg.Conf_parsing.domains = [] then begin
        Printf.eprintf
          "No domains configured in %s. Run `tsync config --edit`.\n"
          runtime_paths.Runtime.config_path;
        exit 0
      end;
      cfg.Conf_parsing.domains
    in
    let mount_fn d =
      match (mount, domains) with Some p, [_] -> p | _ -> mount_point_of d
    in
    let per_domain =
      List.map
        (fun (d : Conf_parsing.domain) ->
          let socket_path = Runtime.domain_socket_path runtime_paths d.name in
          (* The only [resume]: the daemon is the process that outlives a
             deferred target's work, so it is the one that picks up what a
             previous run left owed. *)
          let conf = make_conf ~domain:d.name ~socket_path ~resume:true cfg in
          (d, conf, mount_fn d))
        domains
    in
    (* Before the fork, so every frontend inherits it. launchd hands this daemon
       a 256 soft limit against an unlimited hard one, low enough that a burst of
       concurrent work fails accept with EMFILE. *)
    (match Descriptors.current () with
      | Some before ->
          let after = Descriptors.raise_to ~target:8192 in
          if after > before then
            Log.debug "open file limit: %d (was %d)" after before
          else Log.debug "open file limit: %d" after
      | None -> ());
    Log.debug "cache root: %s" runtime_paths.Runtime.cache_root;
    Launcher.run
      ~on_leaf:(fun ~name -> Oneshot.trace_process ~name)
      (List.map
         (fun ((d : Conf_parsing.domain), conf, mount_point) ->
           List.map
             (fun (f : Conf_parsing.frontend_config) ->
               ( f.Conf_parsing.frontend_type,
                 {
                   Frontend.conf;
                   options = f.Conf_parsing.options;
                   mount_point;
                 } ))
             d.Conf_parsing.frontends)
         per_domain)
  in
  Cmd.v
    (Cmd.info "start" ~doc:"Mount the filesystem (run under a service manager)")
    Term.(const run $ mount_arg $ tls_arg)
