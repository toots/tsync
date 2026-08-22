open Cmdliner

let verbose = ref false

(* Progress goes through Log at info level, which --verbose reveals. Command
   results stay on stdout via Printf. *)
let set_verbose v =
  verbose := v;
  Log.set_min_level (if v then `info else `warn)

let vprintf fmt = Log.info fmt

let verbose_arg =
  Arg.(value & flag & info ["verbose"; "v"] ~doc:"Print detailed progress")

let runtime_paths = Runtime.default_paths ()
let mount_point_of = Conf_parsing.mount_point_of
let frontend_names = Daemons.frontend_names
let resolve_frontend = Daemons.frontend_for


let domain_arg =
  Arg.(
    value
    & opt (some string) None
    & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")

let load_config () = Conf_parsing.load runtime_paths.Runtime.config_path

(* Conduit picks its TLS backend once per process, so it is set here rather
   than inside a per-domain constructor. *)
let make_conf ?domain ?socket_path ?resume cfg =
  Tls_conf.apply cfg.Conf_parsing.tls;
  Domain.of_config ?domain ?socket_path ?resume ~paths:runtime_paths cfg

let load_conf ?domain () = make_conf ?domain (load_config ())
let reading_from = Domain.reading_from
let read_default_domain () = Domain.default_domain ~paths:runtime_paths
let default_domain_file () = Domain.default_domain_file ~paths:runtime_paths

let domain_target ?domain () =
  Domain.target ?domain ~paths:runtime_paths (load_config ())

let domain_socket ?domain () = snd (domain_target ?domain ())

let domain_socket_for_path path =
  Daemons.socket_for_path ~paths:runtime_paths (load_config ()) path

let domain_targets () = Daemons.all ~paths:runtime_paths (load_config ())


(* What the deferred targets still owe, summed: whether work is outstanding is
   the question, and which target holds it is answered by [tsync status]'s own
   per-backend listing. [None] where no target defers at all, so a domain
   writing straight through reports no queue rather than an empty one. *)
let deferred_totals members =
  let sum f =
    List.fold_left
      (fun acc m -> acc + match f m with Some g -> g () | None -> 0)
      0 members
  in
  if not (List.exists (fun m -> m.Backend.pending <> None) members) then None
  else
    Some
      ( sum (fun m -> m.Backend.pending),
        sum (fun m -> m.Backend.in_flight),
        List.exists
          (fun m ->
            match m.Backend.degraded with Some g -> g () | None -> false)
          members )

(* The half of a job report that is every command's alike: where to send it,
   which domain it belongs to, and what that domain's targets still owe. A
   command passes only what is its own.

   It goes to the process converging the domains, which is the one place on the
   machine that always answers: a domain need not have a frontend with a socket
   of its own, and one served only by the http-proxy has none. Reporting must
   never decide whether a command runs, so nothing listening is silence in
   [tsync status] rather than a failure.

   [current] joins a phase to the thing within it, so six commands do not each
   pick a separator. *)
let report_job ?target ?current ~kind (module C : Conf.S) ~counters () =
  Job.Report.start
    ~socket_path:(Runtime.sync_socket_path runtime_paths)
    ~domain:C.domain_name ~kind ?target ?current
    ~deferred:(fun () -> deferred_totals C.members)
    ~counters ()

let doing phase detail = phase ^ " · " ^ detail


(* MEMTRACE names a directory, one file per process inside it: a daemon's
   frontends and a command are several processes, and two of them inheriting one
   trace fd drop about half their samples into a file that still reads clean,
   neither saying which process allocated. Sampling defaults to 1e-6;
   MEMTRACE_RATE raises it. *)
let trace_process ~name =
  match Sys.getenv_opt "MEMTRACE" with
    | None | Some "" -> ()
    | Some dir ->
        if not (Sys.file_exists dir && Sys.is_directory dir) then
          failwith (Printf.sprintf "MEMTRACE=%s is not a directory" dir);
        let filename = Filename.concat dir (name ^ ".ctf") in
        Unix.putenv "MEMTRACE" filename;
        Memtrace.trace_if_requested ~context:name ();
        Log.info "memory trace: %s" filename

(* [Lwt_main.run] plus a drain: a command returns as soon as its work is posted
   and a deferred target fills in the background, so without this a short-lived
   command exits leaving copies for the daemon it may not be running alongside.

   [report] is a thunk calling {!Job.Report.start}, run here so a long command
   reports for as long as it runs — the drain included, which is work a caller
   would otherwise see as a command that had finished. *)
let run_lwt ?report p =
  let open Lwt.Syntax in
  (* Named for the subcommand and the pid, so a folder imported one call at a
     time leaves a trace per run rather than overwriting the last. *)
  trace_process
    ~name:
      (Printf.sprintf "%s-%d"
         (if Array.length Sys.argv > 1 then Filename.basename Sys.argv.(1)
          else "tsync")
         (Unix.getpid ()));
  Lwt_main.run
    (Option.iter (fun start -> start ()) report;
     (* A command that raised still says so, since its process is about to go
        and nothing else will ever answer for it. *)
     let* r =
       Lwt.catch
         (fun () -> p)
         (fun exn ->
           let* () = Job.Report.finish ~error:(Printexc.to_string exn) () in
           Lwt.fail exn)
     in
     let* () = Backend.drain () in
     let+ () = Job.Report.finish () in
     r)
