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

(* Raises Failure with the daemon's error message when ok=false.

   [socket_path] is required rather than defaulted: a socket belongs to a
   domain, and which domain a command means is the caller's to decide. Resolve
   one with {!domain_socket} or {!domain_socket_for_path}. *)
let ipc_request ~socket_path fields =
  let request = Yojson.Safe.to_string (`Assoc fields) in
  match Yojson.Safe.from_string (Ipc.send ~socket_path request) with
    | `Assoc obj when List.assoc_opt "ok" obj = Some (`Bool true) -> obj
    | `Assoc obj ->
        let msg =
          match List.assoc_opt "error" obj with
            | Some (`String s) -> s
            | _ -> "unexpected response"
        in
        failwith msg
    | _ -> failwith "unexpected response"

let ipc_action ~socket_path ?path ?arg ?domain action =
  ipc_request ~socket_path
    ([("action", `String action)]
    @ (match path with Some p -> [("path", `String p)] | None -> [])
    @ (match domain with Some d -> [("domain", `String d)] | None -> [])
    @ match arg with Some a -> [("arg", `String a)] | None -> [])

let make_backend ~traffic (bc : Conf_parsing.backend_config) =
  Backend.make ~traffic ~backend_type:bc.backend_type
    ~get_field:(fun k -> List.assoc_opt k bc.fields)
    ()

(* Empty for a body that is not a manifest: a folder marker, a trash marker, a
   share. *)
let chunk_keys data =
  match Chunk_table.of_string data with
    | t -> List.init (Chunk_table.count t) (Chunk_table.key t)
    | exception _ -> []

(* Where the deferred targets keep what they still owe. Per domain, since the
   jobs name domain keys and a shared root would replay one domain's against
   another's backends — the same reason {!Wal} shards by domain. *)
let deferred_root (d : Conf_parsing.domain) =
  Filename.concat
    (Filename.concat runtime_paths.Runtime.data_dir "deferred-pending")
    d.Conf_parsing.name

(* The one place a configured role becomes behavior: [replica] and [backfill]
   are the same target with one bit between them — whether reads may reach it —
   so a resynced backfill is promoted by editing one word. *)
let build_backends ~resume (d : Conf_parsing.domain) :
    (module Backend.S) * Backend.member list =
  (* One counter pair per configured store, kept by name so the member built
     below reports the very counters that store's wrapper adds to. *)
  let traffic : (string, Backend.traffic) Hashtbl.t = Hashtbl.create 4 in
  (* Shared by every layer below: a second [make_backend] for the same config is
     a second client against the same store. Order comes from
     {!Conf_parsing.order_backends}, so a main answers first. *)
  let leaves =
    List.map
      (fun (bc : Conf_parsing.backend_config) ->
        let t = Backend.new_traffic () in
        Hashtbl.replace traffic bc.Conf_parsing.name t;
        (bc, make_backend ~traffic:t bc))
      (Conf_parsing.order_backends d.Conf_parsing.backends)
  in
  let of_roles rs =
    List.filter
      (fun ((bc : Conf_parsing.backend_config), _) -> List.mem bc.role rs)
      leaves
  in
  let sub ((bc : Conf_parsing.backend_config), backend) =
    { Domain_store.name = bc.Conf_parsing.name; backend }
  in
  (* Kept so [report_members] and the share list can ask a target how it is
     doing, and whether reads reach it, without re-deriving either from the
     role. *)
  let built : (string, (module Deferred.S)) Hashtbl.t = Hashtbl.create 4 in
  let target ((bc : Conf_parsing.backend_config), backend) ~source =
    let plain =
      Deferred.make ~resume ~name:bc.name ~backend ~source
        ~chunk_prefix:(Conf_parsing.chunk_prefix d)
        ~chunk_from_prefix:
          (Chunk_space.from_prefix ~chunk_prefix:(Conf_parsing.chunk_prefix d))
        ~chunk_keys
        ~journal_prefix:(Conf_parsing.journal_prefix d)
        ~cursor_key:(Conf_parsing.cursor_key d)
        ~root:(deferred_root d) ()
    in
    let built_target =
      match bc.role with
        | `Replica ->
            let module R = Deferred.Readable ((val plain : Deferred.S)) in
            (module R : Deferred.S)
        | _ -> plain
    in
    Hashtbl.replace built bc.name built_target;
    built_target
  in
  (* Roles are validated at parse time ({!Conf_parsing.validate_roles}), so the
     mains are empty only for a legitimately read-only domain. *)
  let composite =
    Domain_store.make
      ~mains:(List.map sub (of_roles [`Main]))
      ~targets:(List.map target (of_roles [`Replica; `Backfill]))
      ~archives:(List.map sub (of_roles [`Read_only]))
  in
  (* The only place holding each store's name, role and module at once. A store
     with no target behind it is a main or an archive, both of which reads
     reach. *)
  let members =
    List.map
      (fun ((bc : Conf_parsing.backend_config), backend) ->
        let stat f =
          Option.map
            (fun (module D : Deferred.S) () -> f (D.stats ()))
            (Hashtbl.find_opt built bc.name)
        in
        Backend.member ~name:bc.name
          ~role:(Conf_parsing.role_name bc.role)
          ~readable:
            (match Hashtbl.find_opt built bc.name with
              | Some (module D : Deferred.S) -> D.readable <> None
              | None -> true)
          ~backend_type:bc.backend_type
            (* Masked as [tsync config] does, so a report names the
                bucket without carrying a credential. *)
          ~config:
            (List.map
               (fun (k, v) ->
                 match
                   Option.bind
                     (Backend.spec_for bc.backend_type)
                     (List.find_opt (fun (s : Field_spec.t) -> s.name = k))
                 with
                   | Some { secret = true; _ } when v <> "" -> (k, "***")
                   | _ -> (k, v))
               bc.fields)
          ?pending:(stat (fun s -> s.Deferred.queued))
          ?in_flight:(stat (fun s -> s.Deferred.in_flight))
          ?degraded:(stat (fun s -> s.Deferred.degraded))
          ?traffic:
            (if Backend.counts_traffic ~backend_type:bc.backend_type then
               Hashtbl.find_opt traffic bc.name
             else None)
            (* Only a local store sits on a filesystem we can measure. *)
          ?local_path:
            (if bc.backend_type = "local" then List.assoc_opt "path" bc.fields
             else None)
          backend)
      leaves
  in
  (composite, members)

let default_domain_file () =
  Filename.concat runtime_paths.Runtime.data_dir "default-domain"

(* The config says which domains exist: a name left here by a domain since
   dropped from it is ignored rather than fatal, so removing a domain does not
   break every command that omits [--domain]. *)
let read_default_domain () =
  let configured name =
    match Conf_parsing.load runtime_paths.Runtime.config_path with
      | cfg ->
          List.exists
            (fun (d : Conf_parsing.domain) -> d.name = name)
            cfg.Conf_parsing.domains
      | exception _ -> true
  in
  match open_in (default_domain_file ()) with
    | ic ->
        let s = String.trim (input_line ic) in
        close_in ic;
        if s = "" || not (configured s) then None else Some s
    | exception _ -> None

(* [resume] picks up the deferred work a previous run left owed, and belongs to
   the daemon alone — a one-shot command records and drains its own, but must
   not run jobs the daemon is also running. *)
let make_conf ?domain ?socket_path ?(resume = false) cfg : (module Conf.S) =
  Tls_conf.apply cfg.Conf_parsing.tls;
  let domain =
    match domain with Some _ -> domain | None -> read_default_domain ()
  in
  let d = Conf_parsing.pick_domain ?domain cfg in
  let socket_path =
    match socket_path with
      | Some p -> p
      | None -> Runtime.domain_socket_path runtime_paths d.Conf_parsing.name
  in
  (module struct
    let versioning = d.Conf_parsing.versioning
    let client_name = cfg.Conf_parsing.name
    let domain_name = d.Conf_parsing.name
    let domain_prefix = Conf_parsing.domain_prefix d
    let chunk_prefix = Conf_parsing.chunk_prefix d
    let versions_prefix = Conf_parsing.versions_prefix d
    let journal_prefix = Conf_parsing.journal_prefix d
    let cursor_key = Conf_parsing.cursor_key d
    let shares_prefix = Conf_parsing.shares_prefix d
    let store, members = build_backends ~resume d
    let cache_root = runtime_paths.Runtime.cache_root
    let data_dir = runtime_paths.Runtime.data_dir
    let socket_path = socket_path
    let max_uploads = cfg.Conf_parsing.max_uploads
    let max_chunk_buffers = cfg.Conf_parsing.max_chunk_buffers
    let max_downloads = cfg.Conf_parsing.max_downloads
    let chunk_size = d.Conf_parsing.chunk_size
    let cache_chunk_size = d.Conf_parsing.cache_chunk_size
    let max_cache = d.Conf_parsing.max_cache
    let symlink_policy = d.Conf_parsing.symlink_policy
    let read_only = d.Conf_parsing.read_only
  end : Conf.S)

let domain_arg =
  Arg.(
    value
    & opt (some string) None
    & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")

let load_config () = Conf_parsing.load runtime_paths.Runtime.config_path

(* Linux gives each domain its own socket (a domain is its own child process)
   while macOS shares one, so reaching the right daemon means resolving the
   domain first: explicit [--domain], else the persisted default, else the sole
   configured domain.

   Every command talking to a running daemon goes through this or
   {!domain_socket_for_path}, which is why {!ipc_request} requires its socket
   rather than defaulting one: there is nothing to fall through to. *)
let domain_target ?domain () =
  let domain =
    match domain with Some _ -> domain | None -> read_default_domain ()
  in
  let d = Conf_parsing.pick_domain ?domain (load_config ()) in
  let name = d.Conf_parsing.name in
  (name, Runtime.domain_socket_path runtime_paths name)

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

let load_conf ?domain () = make_conf ?domain (load_config ())

(* [--source] says where to read from, so only reads move: a write still goes
   through the domain's own path and reaches the deferred targets behind it.
   Raises [Failure] when nothing has that name. *)
let reading_from name (module C : Conf.S) : (module Conf.S) =
  let m =
    match
      List.filter (fun (m : Backend.member) -> m.Backend.name = name) C.members
    with
      | [m] -> m
      | [] ->
          failwith
            (Printf.sprintf "no backend named %s (available: %s)" name
               (String.concat ", "
                  (List.map (fun (m : Backend.member) -> m.name) C.members)))
      | _ ->
          failwith
            (Printf.sprintf
               "backend name %s is ambiguous; set distinct \"name\" fields in \
                the config"
               name)
  in
  (module struct
    include C

    let store =
      (module struct
        include (val C.store : Backend.S)
        module Src = (val m.Backend.backend : Backend.S)

        let get = Src.get
        let get_opt = Src.get_opt
        let head_opt = Src.head_opt
        let list_prefix = Src.list_prefix

        (* Taken from [Src] rather than left as the composite's, which would
           read bodies through the whole domain while the listings came from
           this one store. [None] where [Src] has no batch of its own, so the
           fan-out asks the [get_opt] above. *)
        let get_many = Src.get_many
      end : Backend.S)
  end : Conf.S)

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
