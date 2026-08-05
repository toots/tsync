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

(* Batched so both in-flight requests and live promises stay bounded: a plain
   [iter_p] over a huge list allocates a promise per element up front. *)
let iter_pooled ?(parallelism = 32) f xs =
  let open Lwt.Syntax in
  let rec take n = function
    | x :: tl when n > 0 ->
        let batch, rest = take (n - 1) tl in
        (x :: batch, rest)
    | rest -> ([], rest)
  in
  let rec loop = function
    | [] -> Lwt.return_unit
    | xs ->
        let batch, rest = take parallelism xs in
        let* () = Lwt_list.iter_p f batch in
        loop rest
  in
  loop xs

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

(* The domain's backends composed by role into one module.

   Two layers answering different questions. {!Fallback_backend} says which
   backends a read may look at and how far a write fans out: mains and replicas
   are the source of truth, read-only stores sit behind them. {!Backfill_backend}
   wraps that with the targets filled lazily from the write side. A domain of
   only read-only stores gets an inner layer with nothing writable in it, which
   is what makes it readable but not writable. *)
(* The composite every read and write goes through, plus, separately, the stores
   a share link may be served from. A share manifest lives outside every domain
   root, so publishing one is not a domain write and must not be refused by a
   composite with nothing writable in it. *)
type resolved_backends = {
  backends : (module Backend.S) list;
  share_backends : (module Backend.S) list;
}

(* Order comes from {!Conf_parsing.order_backends}. A backfill target is behind
   by construction, so a link served from one could point at something it has not
   caught up with. *)
let share_leaves leaves =
  List.filter_map
    (fun ((bc : Conf_parsing.backend_config), backend) ->
      if bc.role = `Backfill then None else Some backend)
    leaves

let build_backends (d : Conf_parsing.domain) : resolved_backends =
  (* Shared by every layer below: a second [make_backend] for the same config is
     a second client against the same store. *)
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
  (* Roles are validated at parse time ({!Conf_parsing.validate_roles}), so
     [writable] is empty only for a legitimately read-only domain. *)
  let writable = of_roles [`Main; `Replica] in
  let sub ((bc : Conf_parsing.backend_config), backend) =
    { Fallback_backend.name = bc.name; backend }
  in
  let inner =
    Fallback_backend.make ~writable:(List.map sub writable)
      ~fallbacks:(List.map sub (of_roles [`Read_only]))
  in
  let composite, lanes =
    match of_roles [`Backfill] with
      | [] -> (inner, [])
      | bf ->
          let bf_backend =
            Backfill_backend.make
              ~chunk_prefix:(Conf_parsing.chunk_prefix d)
              ~chunk_keys
              ~skip_prefixes:
                [Conf_parsing.journal_prefix d; Conf_parsing.cursor_key d]
              ~inners:[inner]
              ~backfills:
                (List.map
                   (fun ((bc : Conf_parsing.backend_config), backend) ->
                     { Backfill_backend.name = bc.Conf_parsing.name; backend })
                   bf)
          in
          (bf_backend.Backfill_backend.backend, bf_backend.lanes)
  in
  (* The only place holding each backend's name, role and module at once. *)
  Backend.report_members ~domain:d.Conf_parsing.name
    (List.map
       (fun ((bc : Conf_parsing.backend_config), backend) ->
         let lane = List.assoc_opt bc.name lanes in
         let stat f = Option.map (fun l () -> f (l ())) lane in
         {
           Backend.name = bc.name;
           role = Conf_parsing.role_name bc.role;
           backend_type = bc.backend_type;
           (* Masked as [tsync print-config] does, so a report names the bucket
              without carrying a credential. *)
           config =
             List.map
               (fun (k, v) ->
                 match
                   Option.bind
                     (Backend.spec_for bc.backend_type)
                     (List.find_opt (fun (s : Backend.field_spec) -> s.name = k))
                 with
                   | Some { secret = true; _ } when v <> "" -> (k, "***")
                   | _ -> (k, v))
               bc.fields;
           backend;
           pending = stat (fun s -> s.Backfill_backend.queued);
           in_flight = stat (fun s -> s.Backfill_backend.in_flight);
           degraded = stat (fun s -> s.Backfill_backend.degraded);
           (* Only a local store sits on a filesystem we can measure. *)
           local_path =
             (if bc.backend_type = "local" then List.assoc_opt "path" bc.fields
              else None);
         })
       leaves);
  { backends = [composite]; share_backends = share_leaves leaves }

(* Moves [source] to the head so it serves reads. Fails if no backend has that
   name. *)
let order_backends_from source backends =
  let ordered = Conf_parsing.order_backends backends in
  match
    List.partition
      (fun (b : Conf_parsing.backend_config) -> b.name = source)
      ordered
  with
    | [], _ ->
        failwith
          (Printf.sprintf "no backend named %s (available: %s)" source
             (String.concat ", "
                (List.map
                   (fun (b : Conf_parsing.backend_config) -> b.name)
                   ordered)))
    | chosen, rest -> chosen @ rest

let default_domain_file () =
  Filename.concat runtime_paths.Runtime.data_dir "default-domain"

let read_default_domain () =
  match open_in (default_domain_file ()) with
    | ic ->
        let s = String.trim (input_line ic) in
        close_in ic;
        if s = "" then None else Some s
    | exception _ -> None

(* [tier=false] exposes the raw backend list instead of the role composite, for
   commands (resync-remote) copying between individual backends including ones
   the composite never reads from. [source] forces reads from the named backend,
   for commands that pick where to read. *)
let make_conf ?domain ?socket_path ?(tier = true) ?source cfg : (module Conf.S)
    =
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

    (* Shared: a second [make_backend] for the same config is a second client
       against the same store. *)
    let resolved =
      let flat ordered =
        let leaves =
          List.map
            (fun (bc : Conf_parsing.backend_config) -> (bc, make_backend bc))
            ordered
        in
        { backends = List.map snd leaves; share_backends = share_leaves leaves }
      in
      match source with
        | Some name -> flat (order_backends_from name d.Conf_parsing.backends)
        | None ->
            if tier then build_backends d
            else flat (Conf_parsing.order_backends d.Conf_parsing.backends)

    let backends = resolved.backends
    let share_backends = resolved.share_backends
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

let load_conf ?domain ?tier ?source () =
  make_conf ?domain ?tier ?source (load_config ())

(* [Lwt_main.run] plus a drain: a command returns as soon as its work is posted
   and a backfill target fills in the background, so without this a short-lived
   command exits carrying pending copies with it. *)
let run_lwt p =
  let open Lwt.Syntax in
  Lwt_main.run
    (let* r = p in
     let+ () = Backend.drain () in
     r)
