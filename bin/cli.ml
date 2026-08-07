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

(* Where fuse mounts a domain: its [mountPoint] option, else ~/tsync/<domain>.
   Also used by commands that accept an absolute path under the mount. *)
let mount_point_of (d : Conf_parsing.domain) =
  let opt =
    List.find_map
      (fun (f : Conf_parsing.frontend_config) ->
        if f.Conf_parsing.frontend_type = "fuse" then
          List.assoc_opt "mountPoint" f.Conf_parsing.options
        else None)
      d.Conf_parsing.frontends
  in
  match opt with
    | Some p when p <> "" -> p
    | _ -> Filename.concat (Sys.getenv "HOME") ("tsync/" ^ d.Conf_parsing.name)

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

(* Raises Failure with the daemon's error message when ok=false. *)
let ipc_request ?(socket_path = runtime_paths.Runtime.socket_path) fields =
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

let ipc_action ?socket_path ?path ?arg ?domain action =
  ipc_request ?socket_path
    ([("action", `String action)]
    @ (match path with Some p -> [("path", `String p)] | None -> [])
    @ (match domain with Some d -> [("domain", `String d)] | None -> [])
    @ match arg with Some a -> [("arg", `String a)] | None -> [])

let make_backend (bc : Conf_parsing.backend_config) =
  Backend.make ~backend_type:bc.backend_type ~get_field:(fun k ->
      List.assoc_opt k bc.fields)

(* None for a body that is not a manifest (a folder marker, a trash marker, a
   share). The only place needing both a backend key and the manifest format. *)
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

(* The one place a configured role becomes behavior. [replica] and [backfill]
   are the same target with one bit between them — whether reads may reach it —
   and everything else follows from that bit rather than being decided again:
   {!Deferred.Readable} is what carries the journal and cursor, and what lets a
   share link be served from the store. So a resynced backfill is promoted by
   editing one word. *)
let build_backends ~resume (d : Conf_parsing.domain) :
    (module Backend.S) * Backend.member list =
  (* Shared by every layer below: a second [make_backend] for the same config is
     a second client against the same store. Order comes from
     {!Conf_parsing.order_backends}, so a main answers first. *)
  let leaves =
    List.map
      (fun (bc : Conf_parsing.backend_config) -> (bc, make_backend bc))
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
            (* Masked as [tsync print-config] does, so a report names the
                bucket without carrying a credential. *)
          ~config:
            (List.map
               (fun (k, v) ->
                 match
                   Option.bind
                     (Backend.spec_for bc.backend_type)
                     (List.find_opt (fun (s : Backend.field_spec) -> s.name = k))
                 with
                   | Some { secret = true; _ } when v <> "" -> (k, "***")
                   | _ -> (k, v))
               bc.fields)
          ?pending:(stat (fun s -> s.Deferred.queued))
          ?in_flight:(stat (fun s -> s.Deferred.in_flight))
          ?degraded:(stat (fun s -> s.Deferred.degraded))
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

let read_default_domain () =
  match open_in (default_domain_file ()) with
    | ic ->
        let s = String.trim (input_line ic) in
        close_in ic;
        if s = "" then None else Some s
    | exception _ -> None

(* [resume] picks up the deferred work a previous run left owed, and belongs to
   the daemon alone — a one-shot command records and drains its own, but must
   not run jobs the daemon is also running.

   One shape, whatever the command: a caller wanting an individual store reaches
   for {!Conf.S.members} rather than a differently-built conf. *)
let make_conf ?domain ?socket_path ?(resume = false) cfg : (module Conf.S) =
  Tls_conf.apply cfg.Conf_parsing.tls;
  let domain =
    match domain with Some _ -> domain | None -> read_default_domain ()
  in
  let d = Conf_parsing.pick_domain ?domain cfg in
  let socket_path =
    Option.value socket_path ~default:runtime_paths.Runtime.socket_path
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

(* Every domain-scoped command declares the same option and opens by loading the
   config and building one domain's conf. *)

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

   Every command talking to a running daemon must go through this. The bare
   [runtime_paths.socket_path] is the shared macOS socket and, on Linux, a path
   nothing listens on. *)
(* Both are needed together: macOS serves every domain on one socket, so the
   request has to name the one it means. *)
let domain_target ?domain () =
  let domain =
    match domain with Some _ -> domain | None -> read_default_domain ()
  in
  let d = Conf_parsing.pick_domain ?domain (load_config ()) in
  let name = d.Conf_parsing.name in
  (name, Runtime.domain_socket_path runtime_paths name)

let domain_socket ?domain () = snd (domain_target ?domain ())
let load_conf ?domain () = make_conf ?domain (load_config ())

(* [--source] says where to read from, so only reads move: a write still goes
   through the domain's own path and reaches the deferred targets behind it. For
   the commands that pick a store to catch up from, rather than letting the read
   order decide. Raises [Failure] when nothing has that name. *)
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
      end : Backend.S)
  end : Conf.S)

(* [Lwt_main.run] plus a drain: a command returns as soon as its work is posted
   and a deferred target fills in the background, so without this a short-lived
   command exits leaving copies for the daemon it may not be running alongside.
*)
let run_lwt p =
  let open Lwt.Syntax in
  Lwt_main.run
    (let* r = p in
     let+ () = Backend.drain () in
     r)
