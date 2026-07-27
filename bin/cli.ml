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

(* The chunk keys a manifest body names, and none for a body that is not a
   manifest (a folder marker, a trash marker, a share). The only place that has
   to know both a backend key and the manifest format. *)
let chunk_keys data =
  match Chunk_table.of_string data with
    | t -> List.init (Chunk_table.count t) (Chunk_table.key t)
    | exception _ -> []

(* The domain's backends composed by role into the single module everything else
   talks to.

   Two layers, because they answer different questions. {!Fallback_backend} says
   which backends a read may look at and how far a write fans out: mains and
   replicas are the source of truth, read-only stores sit behind them.
   {!Backfill_backend} then wraps that with the targets filled lazily from the
   write side. A domain with only mains gets the inner layer and nothing else,
   and one with only read-only stores gets an inner layer with nothing writable
   in it — which is what makes such a domain readable but not writable. *)
let build_backends (d : Conf_parsing.domain) : (module Backend.S) list =
  let of_roles rs =
    List.filter
      (fun (b : Conf_parsing.backend_config) -> List.mem b.role rs)
      (Conf_parsing.order_backends d.Conf_parsing.backends)
  in
  (* Role coherence is settled at parse time ({!Conf_parsing.validate_roles}), so
     [writable] is empty only for a domain that is legitimately read-only. *)
  let writable = of_roles [`Main; `Replica] in
  let sub (bc : Conf_parsing.backend_config) =
    { Fallback_backend.name = bc.name; backend = make_backend bc }
  in
  let inner =
    Fallback_backend.make ~writable:(List.map sub writable)
      ~fallbacks:(List.map sub (of_roles [`Read_only]))
  in
  match of_roles [`Backfill] with
    | [] -> [inner]
    | bf ->
        [
          Backfill_backend.make
            ~chunk_prefix:(Conf_parsing.chunk_prefix d)
            ~chunk_keys
            ~skip_prefixes:
              [Conf_parsing.journal_prefix d; Conf_parsing.cursor_key d]
            ~inners:[inner]
            ~backfills:
              (List.map
                 (fun (bc : Conf_parsing.backend_config) ->
                   {
                     Backfill_backend.name = bc.Conf_parsing.name;
                     backend = make_backend bc;
                   })
                 bf);
        ]

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

(* [tier=false] exposes the raw backend list instead of the role composite — for
   commands (resync-remote) that copy between individual backends, including the
   ones the composite never reads from.
   [source] forces reads to come from the named backend (moved to the head, no
   composite) — for commands that pick which backend to read from. *)
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
    let cache_chunk_size = d.Conf_parsing.cache_chunk_size
    let max_cache = d.Conf_parsing.max_cache
    let symlink_policy = d.Conf_parsing.symlink_policy
    let read_only = d.Conf_parsing.read_only

    let notify_path =
      Filename.concat runtime_paths.Runtime.data_dir
        ("notify-" ^ d.Conf_parsing.name ^ ".sock")
  end : Conf.S)

(* ── Command scaffolding ─────────────────────────────────────────────────────
   Every domain-scoped command declares the same option and opens by loading the
   config and building one domain's conf. Declared once here rather than a dozen
   times over. *)

let domain_arg =
  Arg.(
    value
    & opt (some string) None
    & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")

let load_config () = Conf_parsing.load runtime_paths.Runtime.config_path

let load_conf ?domain ?tier ?source () =
  make_conf ?domain ?tier ?source (load_config ())

(* [Lwt_main.run] for a one-shot command: run the body, then let the backends
   settle before the process goes away. A command returns as soon as its work is
   posted and a backfill target is filled in the background, so without this a
   short-lived command would routinely exit carrying pending copies with it. *)
let run_lwt p =
  let open Lwt.Syntax in
  Lwt_main.run
    (let* r = p in
     let+ () = Backend.drain () in
     r)
