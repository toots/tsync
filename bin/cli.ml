open Cmdliner

(* ── Verbose output ──────────────────────────────────────────────────────── *)

let verbose = ref false

(* CLI progress goes through Log at info level; --verbose lowers the threshold
   so those lines appear. Actual command results stay on stdout via Printf. *)
let set_verbose v =
  verbose := v;
  Log.set_min_level (if v then `info else `warn)

let vprintf fmt = Log.info fmt

let verbose_arg =
  Arg.(value & flag & info ["verbose"; "v"] ~doc:"Print detailed progress")

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

(* Run [f] over [xs] with at most [parallelism] concurrent operations, in
   batches so both the in-flight request count and the number of live Lwt
   promises stay bounded (a plain [iter_p] over a huge list would allocate a
   promise per element up front). Latency-bound backend work benefits most. *)
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

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let runtime_paths = Runtime.default_paths ()

(* Which frontend serves a domain: the [frontend] override if given (must be one
   the domain lists), else the domain's first configured frontend. Errors if the
   name isn't compiled into this binary. Resolved at call time (not module-init)
   so frontend registration, a link-order side effect, has already happened. *)
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

(* Send a JSON IPC request; return the parsed response fields.
   Raises Failure with the daemon's error message when ok=false. *)
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

(* The domain's ordered backends. When any is flagged [backfill] or [readOnly],
   collapse them into a single tiered composite; otherwise the plain ordered list.

   Roles: exactly one primary (neither flag) is the writable source of truth;
   [backfill] backends are writable, lazily-filled chunk copies; [readOnly]
   backends are authoritative read-only fallbacks. Reads prefer the primary and
   fall through the rest; writes fan out to everything except [readOnly]. *)
let build_backends (d : Conf_parsing.domain) : (module Backend.S) list =
  let ordered = Conf_parsing.order_backends d.Conf_parsing.backends in
  let tiered =
    List.exists
      (fun (b : Conf_parsing.backend_config) -> b.backfill || b.read_only)
      ordered
  in
  if not tiered then List.map make_backend ordered
  else begin
    let subs =
      List.map
        (fun (bc : Conf_parsing.backend_config) ->
          ( bc,
            {
              Tiered_backend.name = bc.Conf_parsing.name;
              backend = make_backend bc;
            } ))
        ordered
    in
    let read_order = List.map snd subs in
    let backfills =
      List.filter_map
        (fun (bc, s) -> if bc.Conf_parsing.backfill then Some s else None)
        subs
    in
    (* Manifests/listings come from the authoritative (non-backfill) backends. *)
    let manifest_read =
      List.filter_map
        (fun (bc, s) -> if bc.Conf_parsing.backfill then None else Some s)
        subs
    in
    (* Writes go everywhere except read-only backends. *)
    let writes =
      List.filter_map
        (fun ((bc : Conf_parsing.backend_config), s) ->
          if bc.read_only then None else Some s.Tiered_backend.backend)
        subs
    in
    (match
       List.filter
         (fun ((bc : Conf_parsing.backend_config), _) ->
           (not bc.backfill) && not bc.read_only)
         subs
     with
      | [_] -> ()
      | [] ->
          failwith
            (Printf.sprintf
               "domain %s: no primary backend; exactly one must be neither \
                \"backfill\" nor \"readOnly\""
               d.Conf_parsing.name)
      | _ :: _ :: _ ->
          failwith
            (Printf.sprintf
               "domain %s: more than one primary backend; exactly one must be \
                neither \"backfill\" nor \"readOnly\""
               d.Conf_parsing.name));
    [
      Tiered_backend.make
        ~chunk_prefix:(Conf_parsing.chunk_prefix d)
        ~read_order ~manifest_read ~writes ~backfills;
    ]
  end

(* Ordered backends with the one named [source] moved to the head, so it serves
   reads (the primary). Fails if no backend has that name. *)
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

(* [tier=false] exposes the raw ordered backend list instead of the tiered
   composite — for commands (resync-remote) that copy between individual backends.
   [source] forces reads to come from the named backend (moved to the head, tiering
   off) — for commands that pick which backend to read from. *)
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

    let backends =
      match source with
        | Some name ->
            List.map make_backend
              (order_backends_from name d.Conf_parsing.backends)
        | None ->
            if tier then build_backends d
            else
              List.map make_backend
                (Conf_parsing.order_backends d.Conf_parsing.backends)

    let cache_root = runtime_paths.Runtime.cache_root
    let data_dir = runtime_paths.Runtime.data_dir
    let socket_path = socket_path
    let max_uploads = cfg.Conf_parsing.max_uploads
    let max_downloads = cfg.Conf_parsing.max_downloads
    let chunk_size = d.Conf_parsing.chunk_size
    let max_cache = d.Conf_parsing.max_cache
    let symlink_policy = d.Conf_parsing.symlink_policy
    let read_only = d.Conf_parsing.read_only

    let notify_path =
      Filename.concat runtime_paths.Runtime.data_dir
        ("notify-" ^ d.Conf_parsing.name ^ ".sock")
  end : Conf.S)
