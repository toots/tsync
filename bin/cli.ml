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

(* The [frontend] override if given (it must be one the domain lists), else the
   domain's first. Resolved at call time, not module-init, so frontend
   registration — a link-order side effect — has already happened. *)
let frontend_names (d : Conf_parsing.domain) =
  List.map
    (fun (f : Conf_parsing.frontend_config) -> f.Conf_parsing.frontend_type)
    d.Conf_parsing.frontends

let resolve_frontend ?frontend (d : Conf_parsing.domain) : (module Frontend.S) =
  let names = frontend_names d in
  let name =
    match frontend with
      | Some name ->
          if List.mem name names then name
          else
            failwith
              (Printf.sprintf
                 "frontend %s not configured for domain %s (configured: %s)"
                 name d.Conf_parsing.name (String.concat ", " names))
      | None -> (
          match names with
            | n :: _ -> n
            | [] ->
                failwith ("domain " ^ d.Conf_parsing.name ^ " has no frontends")
          )
  in
  match Frontend.find name with
    | Some m -> m
    | None ->
        failwith
          (Printf.sprintf
             "frontend %s is configured but not compiled into this binary" name)


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

(* A path names its own domain by sitting under that domain's mount, which is
   how the macOS router resolves one as well. A path under none of them falls
   back to the default domain, so the answer is a daemon saying it does not know
   the file rather than a connection to nothing. *)
let domain_socket_for_path path =
  let path =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
    else path
  in
  let under mount =
    let mount = if mount = "/" then "" else mount in
    String.starts_with ~prefix:(mount ^ "/") path || path = mount
  in
  match
    List.find_opt
      (fun d -> under (Conf_parsing.mount_point_of d))
      (load_config ()).Conf_parsing.domains
  with
    | Some d -> Runtime.domain_socket_path runtime_paths d.Conf_parsing.name
    | None | (exception _) -> domain_socket ()

(* For a command that reports rather than acts: every configured domain, never
   one. The default domain, and [--domain] with it, say which domain a command
   acts on; a report answers for the machine, and narrowing it would leave the
   rest of what runs here unaccounted for.

   Each domain keeps its own name even where the socket is shared, since that is
   what the macOS daemon routes on. *)
let domain_targets () =
  match (load_config ()).Conf_parsing.domains with
    | [] -> failwith "no domains configured"
    | domains ->
        (* Asked of each configured frontend rather than assumed: a domain served
           only by a listener has no socket of its own, and knocking on one
           nothing binds reports a daemon down that was never up. Frontends
           sharing a path answer the same one and collapse. *)
        List.concat_map
          (fun (d : Conf_parsing.domain) ->
            List.filter_map
              (fun (f : Conf_parsing.frontend_config) ->
                match Frontend.find f.Conf_parsing.frontend_type with
                  | None -> None
                  | Some (module F : Frontend.S) -> (
                      match F.listens with
                        | None -> None
                        | Some `Domain_socket ->
                            Some
                              ( d.Conf_parsing.name,
                                Runtime.domain_socket_path runtime_paths
                                  d.Conf_parsing.name )
                        (* Named for the domain, not the listener: one process
                           fronts several and routes on the name, so a report
                           has to ask it once per domain to hear about each. *)
                        | Some `Proxy_socket ->
                            Some
                              ( d.Conf_parsing.name,
                                Runtime.proxy_socket_path runtime_paths )))
              d.Conf_parsing.frontends)
          domains
        (* The process converging every domain, which presents none of them and
           so is named for the work rather than for a domain or a frontend. *)
        @ [("sync", Runtime.sync_socket_path runtime_paths)]
        |> List.sort_uniq compare


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
