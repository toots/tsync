open Cmdliner

(* ── Verbose output ──────────────────────────────────────────────────────── *)

let verbose = ref false

let vprintf fmt =
  if !verbose then Printf.printf fmt else Printf.ifprintf stdout fmt

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

let ipc_action ?socket_path ?path ?arg action =
  ipc_request ?socket_path
    ([("action", `String action)]
    @ (match path with Some p -> [("path", `String p)] | None -> [])
    @ match arg with Some a -> [("arg", `String a)] | None -> [])

let make_backend (bc : Conf_parsing.backend_config) =
  Backend.make ~backend_type:bc.backend_type ~get_field:(fun k ->
      List.assoc_opt k bc.fields)

let default_domain_file () =
  Filename.concat runtime_paths.Runtime.data_dir "default-domain"

let read_default_domain () =
  match open_in (default_domain_file ()) with
    | ic ->
        let s = String.trim (input_line ic) in
        close_in ic;
        if s = "" then None else Some s
    | exception _ -> None

let make_conf ?domain ?socket_path cfg : (module Conf.S) =
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

    let backends =
      List.map make_backend
        (Conf_parsing.order_backends d.Conf_parsing.backends)

    let cache_root = runtime_paths.Runtime.cache_root
    let data_dir = runtime_paths.Runtime.data_dir
    let socket_path = socket_path
    let max_uploads = cfg.Conf_parsing.max_uploads
    let max_downloads = cfg.Conf_parsing.max_downloads
    let symlink_policy = d.Conf_parsing.symlink_policy
    let read_only = d.Conf_parsing.read_only

    let notify_path =
      Filename.concat runtime_paths.Runtime.data_dir
        ("notify-" ^ d.Conf_parsing.name ^ ".sock")
  end : Conf.S)

(* ── tsync start ─────────────────────────────────────────────────────────── *)

let start_cmd =
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
    Log.init ();
    Log.debug "loading config from %s" runtime_paths.Runtime.config_path;
    let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
    (* CLI --tls wins over the config value applied by make_conf. *)
    if tls <> None then Tls_conf.apply tls;
    Log.debug "TLS backend: %s (available: %s)" (Tls_conf.current ())
      (String.concat ", " (Tls_conf.available ()));
    let domains =
      if cfg.Conf_parsing.domains = [] then failwith "no domains configured";
      cfg.Conf_parsing.domains
    in
    let mount_fn domain_name =
      match (mount, domains) with
        | Some p, [_] -> p
        | _ -> Filename.concat (Sys.getenv "HOME") ("tsync/" ^ domain_name)
    in
    (* One conf + binding scaffold per domain; a domain's frontends share its conf. *)
    let per_domain =
      List.map
        (fun (d : Conf_parsing.domain) ->
          let socket_path = Runtime.domain_socket_path runtime_paths d.name in
          let conf = make_conf ~domain:d.name ~socket_path cfg in
          let backend_meta =
            List.map
              (fun (b : Conf_parsing.backend_config) ->
                (b.Conf_parsing.name, b.Conf_parsing.backend_type))
              (Conf_parsing.order_backends d.Conf_parsing.backends)
          in
          (d, conf, backend_meta, mount_fn d.Conf_parsing.name))
        domains
    in
    (* Lwt_unix defaults to a pool of up to 1000 OS threads for dispatching
       blocking syscalls (file I/O has no non-blocking mode). Under bursty
       concurrent chunk reads and FUSE cache I/O that default lets the pool
       grow far past what this workload needs, and each idle worker thread
       wakes periodically on its own timer regardless of whether there's
       work — pure overhead. max_uploads and max_downloads are already the
       real, single ceilings on concurrent upload and download operations
       (see the [Buffer_pool] and [download_pool] comments), so their sum
       plus headroom for FUSE-driven cache I/O is the right size for this
       pool. Clamp it too: an unusually large config value (maxDownloads has
       been seen set to 1000, versus a default of 8) shouldn't reopen the
       unbounded-pool problem this is meant to close — staying under the
       clamp means bursts never hit the ceiling and fall back to synchronous
       execution, which would stall the whole event loop; 256 comfortably
       covers realistic concurrency for this workload. *)
    let total_uploads, total_downloads =
      List.fold_left
        (fun (u, dn) (_, conf, _, _) ->
          let module C = (val conf : Conf.S) in
          (u + C.max_uploads, dn + C.max_downloads))
        (0, 0) per_domain
    in
    Lwt_unix.set_pool_size (min 256 (total_uploads + total_downloads + 32));
    (* One [binding] per (domain × frontend), grouped by frontend. Each group runs
       as its own process (all but the last forked), so distinct frontends — e.g.
       fuse and http-proxy on the same domain — run concurrently. *)
    let all_bindings =
      List.concat_map
        (fun (d, conf, backend_meta, mount_point) ->
          List.map
            (fun (f : Conf_parsing.frontend_config) ->
              ( f.Conf_parsing.frontend_type,
                {
                  Frontend.conf;
                  options = f.Conf_parsing.options;
                  backend_meta;
                  mount_point;
                } ))
            d.Conf_parsing.frontends)
        per_domain
    in
    let frontend_order =
      List.fold_left
        (fun acc (name, _) -> if List.mem name acc then acc else acc @ [name])
        [] all_bindings
    in
    let groups =
      List.map
        (fun name ->
          ( name,
            List.filter_map
              (fun (n, b) -> if n = name then Some b else None)
              all_bindings ))
        frontend_order
    in
    let run_group (name, bindings) =
      let (module F : Frontend.S) =
        match Frontend.find name with
          | Some m -> m
          | None ->
              failwith
                (Printf.sprintf
                   "frontend %s is configured but not compiled into this binary"
                   name)
      in
      Log.debug "starting frontend %s (%d domains)" name (List.length bindings);
      F.start bindings
    in
    Log.debug "cache root: %s" runtime_paths.Runtime.cache_root;
    let rec go child_pids = function
      | [] -> []
      | [g] ->
          run_group g;
          List.rev child_pids
      | g :: rest ->
          let pid = Unix.fork () in
          if pid = 0 then begin
            run_group g;
            exit 0
          end;
          go (pid :: child_pids) rest
    in
    let child_pids = go [] groups in
    List.iter
      (fun pid ->
        (try Unix.kill pid Sys.sigterm with _ -> ());
        try ignore (Unix.waitpid [] pid) with _ -> ())
      child_pids
  in
  Cmd.v
    (Cmd.info "start" ~doc:"Mount the filesystem (run via systemd unit)")
    Term.(const run $ mount_arg $ tls_arg)

(* ── tsync stop ─────────────────────────────────────────────────────────── *)

let stop_cmd =
  let run () =
    match ipc_action "stop" with
      | _ -> print_endline "Stopped."
      | exception Failure msg -> Printf.eprintf "Error: %s\n" msg
  in
  Cmd.v
    (Cmd.info "stop" ~doc:"Stop the sync daemon")
    Term.(const run $ const ())

(* ── tsync status ────────────────────────────────────────────────────────── *)

let status_cmd =
  let run () =
    try
      let obj = ipc_action "status" in
      print_endline (Yojson.Safe.to_string (`Assoc obj))
    with _ -> print_endline "Daemon not running"
  in
  Cmd.v
    (Cmd.info "status" ~doc:"Show daemon status")
    Term.(const run $ const ())

(* ── tsync stats ─────────────────────────────────────────────────────────── *)

let human_bytes n =
  let units = [| "B"; "KB"; "MB"; "GB"; "TB" |] in
  let v = ref (float_of_int n) and i = ref 0 in
  while !v >= 1024. && !i < Array.length units - 1 do
    v := !v /. 1024.;
    incr i
  done;
  if !i = 0 then Printf.sprintf "%d B" n
  else Printf.sprintf "%.1f %s" !v units.(!i)

let print_stats obj =
  let i k = match List.assoc_opt k obj with Some (`Int n) -> n | _ -> 0 in
  let f k = match List.assoc_opt k obj with Some (`Float x) -> x | _ -> 0. in
  let row label value = Printf.printf "  %-13s %s\n" label value in
  Printf.printf "Uploads\n";
  row "pending" (string_of_int (i "pendingUploads"));
  row "completed" (string_of_int (i "uploadsCompleted"));
  row "limit" (string_of_int (i "maxUploads"));
  row "transferred" (human_bytes (i "bytesUploaded"));
  row "rate" (human_bytes (i "uploadBytesPerSec") ^ "/s");
  Printf.printf "Downloads\n";
  row "pending" (string_of_int (i "pendingDownloads"));
  row "completed" (string_of_int (i "downloadsCompleted"));
  row "limit" (string_of_int (i "maxDownloads"));
  row "transferred" (human_bytes (i "bytesDownloaded"));
  row "rate" (human_bytes (i "downloadBytesPerSec") ^ "/s");
  Printf.printf "Hashing\n";
  row "chunks" (string_of_int (i "chunksHashed"));
  row "rate" (Printf.sprintf "%d/s" (i "hashesPerSec"));
  Printf.printf "Cache\n";
  row "dirty files" (string_of_int (i "dirtyFiles"));
  row "open files" (string_of_int (i "openFiles"));
  Printf.printf "Process\n";
  row "cpu" (Printf.sprintf "%.1fs" (f "cpuSeconds"));
  row "memory" (human_bytes (i "rssBytes"))

let stats_cmd =
  let watch_arg =
    Arg.(
      value
      & opt (some float) None
      & info ["w"; "watch"] ~docv:"SECONDS"
          ~doc:"Poll and redraw every $(docv) seconds")
  in
  let json_arg =
    Arg.(
      value & flag & info ["json"] ~doc:"Output raw JSON, one object per line")
  in
  let run json watch =
    let show () =
      match ipc_action "stats" with
        | obj when json ->
            let obj = ("t", `Float (Unix.gettimeofday ())) :: obj in
            print_endline (Yojson.Safe.to_string (`Assoc obj))
        | obj -> print_stats obj
        | exception Failure msg -> Printf.eprintf "Error: %s\n" msg
        | exception _ -> print_endline "Daemon not running"
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
    (Cmd.info "stats"
       ~doc:"Show transfer metrics (pending/completed uploads and downloads)")
    Term.(const run $ json_arg $ watch_arg)

(* ── tsync evict ─────────────────────────────────────────────────────────── *)

let evict_cmd =
  let path_arg = Arg.(non_empty & pos_all string [] & info [] ~docv:"PATH") in
  let run paths =
    List.iter
      (fun path ->
        match ipc_action ~path "evict" with
          | _ -> Printf.printf "Evicted: %s\n" path
          | exception Failure msg -> Printf.eprintf "Error: %s\n" msg)
      paths
  in
  Cmd.v
    (Cmd.info "evict" ~doc:"Evict files or directories from local cache")
    Term.(const run $ path_arg)

(* ── tsync restore ───────────────────────────────────────────────────────── *)

let restore_cmd =
  let path_arg = Arg.(non_empty & pos_all string [] & info [] ~docv:"PATH") in
  let run paths =
    List.iter
      (fun path ->
        match ipc_action ~path "restore" with
          | _ -> Printf.printf "Restored: %s\n" path
          | exception Failure msg -> Printf.eprintf "Error: %s\n" msg)
      paths
  in
  Cmd.v
    (Cmd.info "restore" ~doc:"Download evicted files or directories")
    Term.(const run $ path_arg)

(* ── tsync pull ──────────────────────────────────────────────────────────── *)

let pull_cmd =
  let path_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let force_arg =
    Arg.(value & flag & info ["force"] ~doc:"Restore even if already cached")
  in
  let run _path _force = Printf.eprintf "pull: not yet implemented\n" in
  Cmd.v
    (Cmd.info "pull" ~doc:"Download all evicted files")
    Term.(const run $ path_arg $ force_arg)

(* ── tsync ls ────────────────────────────────────────────────────────────── *)

let ls_cmd =
  let path_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let deleted_arg =
    Arg.(
      value & flag
      & info ["deleted"; "d"] ~doc:"Also list deleted files in the directory")
  in
  let domain_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")
  in
  let frontend_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["frontend"] ~docv:"NAME"
          ~doc:
            "Frontend to report cache status for (default: the domain's first).")
  in
  let run path show_deleted domain frontend =
    Lwt_main.run
      (let open Lwt.Syntax in
       let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
       let (module C : Conf.S) = make_conf ?domain cfg in
       let (module F : Frontend.S) =
         resolve_frontend ?frontend (Conf_parsing.pick_domain ?domain cfg)
       in
       let module Fs = File_store.Make (C) in
       let mount_point =
         Filename.concat (Sys.getenv "HOME") ("tsync/" ^ C.domain_name)
       in
       let prefix =
         let dp = C.domain_prefix in
         match path with
           | None -> dp
           | Some p ->
               (* Accept a domain-relative path ("radarr/dir/") or an absolute
                  path under the mount point ("/home/…/tsync/domain/radarr/"). *)
               let rel =
                 let mp = mount_point ^ "/" in
                 if
                   String.length p >= String.length mp
                   && String.sub p 0 (String.length mp) = mp
                 then
                   String.sub p (String.length mp)
                     (String.length p - String.length mp)
                 else p
               in
               let rel =
                 if rel = "" || rel.[String.length rel - 1] = '/' then rel
                 else rel ^ "/"
               in
               dp ^ rel
       in
       let* files, subdirs =
         Local.list_directory ~cache_root:C.cache_root
           ~domain_name:C.domain_name ~domain_prefix:C.domain_prefix ~prefix ()
       in
       let dp_len = String.length C.domain_prefix in
       let file_name (e : Backend.file_entry) =
         if String.length e.key > dp_len then
           String.sub e.key dp_len (String.length e.key - dp_len)
         else e.key
       in
       (* Directories and files interleaved, alphabetized (case-insensitive). *)
       let items =
         List.map (fun d -> (d, `Dir d)) subdirs
         @ List.map (fun e -> (file_name e, `File e)) files
       in
       let items =
         List.sort
           (fun (a, _) (b, _) ->
             String.compare (String.lowercase_ascii a)
               (String.lowercase_ascii b))
           items
       in
       List.iter
         (fun (name, item) ->
           match item with
             | `Dir _ -> Printf.printf "dir    %s/\n" name
             | `File (e : Backend.file_entry) ->
                 let cached =
                   F.is_local ~cache_root:C.cache_root
                     ~domain_name:C.domain_name ~domain_prefix:C.domain_prefix
                     e.key
                 in
                 Printf.printf "%s  %s  %d bytes\n"
                   (if cached then "local" else "cloud")
                   name e.size)
         items;
       if show_deleted then begin
         (* Versioned paths in this directory with no live manifest. *)
         let (module B : Backend.S) = List.hd C.backends in
         let reldir =
           let r = String.sub prefix dp_len (String.length prefix - dp_len) in
           if String.ends_with ~suffix:"/" r then
             String.sub r 0 (String.length r - 1)
           else r
         in
         let seen = Hashtbl.create 16 in
         (* Versions of files in this directory share its folder id. *)
         let* fid =
           Folder_ids.resolve ~cache_root:C.cache_root
             ~domain_name:C.domain_name reldir
         in
         let* entries = B.list_all ~prefix:(C.versions_prefix ^ fid ^ "/") () in
         Lwt_list.iter_s
           (fun (e : Backend.file_entry) ->
             (* Version keys are hashed; the real path is in the version body. *)
               match
                 Versioning.parse ~versions_prefix:C.versions_prefix e.key
               with
               | Some (hrel, _) when not (Hashtbl.mem seen hrel) -> (
                   Hashtbl.add seen hrel ();
                   let* data = B.get ~key:e.key () in
                   match Manifest.of_string data with
                     | `Clean m ->
                         (* [hrel] is the manifest key tail; a missing live
                            manifest means the file was deleted. The leaf name is
                            the version body's own name. *)
                         let+ head =
                           B.head_opt ~key:(C.domain_prefix ^ hrel) ()
                         in
                         if head = None then
                           Printf.printf "deleted  %s\n" m.Manifest.name
                     | `Dirty | (exception _) -> Lwt.return_unit)
               | _ -> Lwt.return_unit)
           entries
       end
       else Lwt.return_unit)
  in
  Cmd.v
    (Cmd.info "ls" ~doc:"List files with cache status")
    Term.(const run $ path_arg $ deleted_arg $ domain_arg $ frontend_arg)

(* ── tsync versions ──────────────────────────────────────────────────────── *)

let human_ts ts_ns =
  let secs = Int64.to_float (Int64.div ts_ns 1_000_000_000L) in
  let tm = Unix.localtime secs in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

let versions_cmd =
  let path_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let domain_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")
  in
  let run path domain =
    Lwt_main.run
      (let open Lwt.Syntax in
       let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
       let (module C : Conf.S) = make_conf ?domain cfg in
       let module St = Store.Make (C) (Layout.Inode.Make (C)) in
       let (module B : Backend.S) = List.hd C.backends in
       let parse = Versioning.parse ~versions_prefix:C.versions_prefix in
       match path with
         | Some rel ->
             let* dir = St.version_dir ~key:(C.domain_prefix ^ rel) in
             let+ entries = B.list_all ~prefix:dir () in
             let versions =
               entries
               |> List.filter_map (fun (e : Backend.file_entry) ->
                   match parse e.key with
                     | Some (_, ts) -> Some (Int64.of_string ts, e.size)
                     | None -> None)
               |> List.sort (fun (a, _) (b, _) -> Int64.compare b a)
             in
             if versions = [] then Printf.printf "No versions for %s\n" rel
             else
               List.iter
                 (fun (ts, size) ->
                   Printf.printf "%Ld  %s  %d bytes\n" ts (human_ts ts) size)
                 versions
         | None ->
             (* Group every version by path; a path with no live manifest is a
                deleted file. *)
             (* Keyed by hashed rel; [sample] keeps one version key per file so a
                deleted file's real path can be read from its version body. *)
             let latest = Hashtbl.create 64
             and count = Hashtbl.create 64
             and sample = Hashtbl.create 64 in
             let* entries = B.list_all ~prefix:C.versions_prefix () in
             List.iter
               (fun (e : Backend.file_entry) ->
                 match parse e.key with
                   | Some (rel, ts) ->
                       let ts = Int64.of_string ts in
                       let best =
                         Option.value ~default:0L (Hashtbl.find_opt latest rel)
                       in
                       if Int64.compare ts best > 0 then
                         Hashtbl.replace latest rel ts;
                       Hashtbl.replace sample rel e.key;
                       Hashtbl.replace count rel
                         (1
                         + Option.value ~default:0 (Hashtbl.find_opt count rel)
                         )
                   | None -> ())
               entries;
             let real_path hrel =
               Lwt.catch
                 (fun () ->
                   let+ data = B.get ~key:(Hashtbl.find sample hrel) () in
                   match Manifest.of_string data with
                     | `Clean m -> m.Manifest.name (* TODO(inode): leaf only *)
                     | _ -> hrel)
                 (fun _ -> Lwt.return hrel)
             in
             let* deleted =
               Hashtbl.fold
                 (fun rel ts acc ->
                   let* acc = acc in
                   let* head = B.head_opt ~key:(C.domain_prefix ^ rel) () in
                   if head = None then
                     let+ path = real_path rel in
                     ( path,
                       ts,
                       Option.value ~default:1 (Hashtbl.find_opt count rel) )
                     :: acc
                   else Lwt.return acc)
                 latest (Lwt.return [])
             in
             let deleted = List.sort compare deleted in
             if deleted = [] then print_endline "No deleted files"
             else
               List.iter
                 (fun (rel, ts, n) ->
                   Printf.printf "%s  (deleted %s, %d version%s)\n" rel
                     (human_ts ts) n
                     (if n = 1 then "" else "s"))
                 deleted;
             Lwt.return_unit)
  in
  Cmd.v
    (Cmd.info "versions"
       ~doc:"List a file's versions, or all deleted files when no PATH is given")
    Term.(const run $ path_arg $ domain_arg)

(* ── tsync revert ────────────────────────────────────────────────────────── *)

let revert_cmd =
  let path_arg =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let version_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["version"] ~docv:"TS"
          ~doc:"Version timestamp to restore (default: most recent)")
  in
  let run path version =
    match ipc_action ~path ?arg:version "revert" with
      | _ -> Printf.printf "Reverted: %s\n" path
      | exception Failure msg -> Printf.eprintf "Error: %s\n" msg
  in
  Cmd.v
    (Cmd.info "revert"
       ~doc:"Restore a previous version of a file (metadata only, no download)")
    Term.(const run $ path_arg $ version_arg)

(* ── tsync purge ─────────────────────────────────────────────────────────── *)

let purge_cmd =
  let path_arg =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let run _path = Printf.eprintf "purge: not yet implemented\n" in
  Cmd.v
    (Cmd.info "purge" ~doc:"Delete all versions from trash")
    Term.(const run $ path_arg)

(* ── tsync trash / untrash ───────────────────────────────────────────────── *)

let trash_domain_arg =
  Arg.(
    value
    & opt (some string) None
    & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")

let trash_markers (module B : Backend.S) domain_prefix =
  B.list_all ~prefix:(domain_prefix ^ Folder.trash_id ^ "/") ()

let trash_cmd =
  let run domain =
    Lwt_main.run
      (let open Lwt.Syntax in
       let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
       let (module C : Conf.S) = make_conf ?domain cfg in
       let (module B : Backend.S) = List.hd C.backends in
       let* markers = trash_markers (module B) C.domain_prefix in
       Lwt_list.iter_s
         (fun (e : Backend.file_entry) ->
           let+ data = B.get ~key:e.key () in
           match Folder.trash_path_of_string data with
             | Some p -> Printf.printf "%s\n" p
             | None -> ())
         markers)
  in
  Cmd.v
    (Cmd.info "trash" ~doc:"List trashed folders")
    Term.(const run $ trash_domain_arg)

let untrash_cmd =
  let path_arg =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let run path domain =
    Lwt_main.run
      (let open Lwt.Syntax in
       let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
       let (module C : Conf.S) = make_conf ?domain cfg in
       let (module B : Backend.S) = List.hd C.backends in
       let* markers = trash_markers (module B) C.domain_prefix in
       let* found =
         Lwt_list.filter_map_s
           (fun (e : Backend.file_entry) ->
             let+ data = B.get ~key:e.key () in
             match
               (Folder.trash_path_of_string data, Folder.marker_of_string data)
             with
               | Some p, Some m when p = path -> Some (e.key, m)
               | _ -> None)
           markers
       in
       match found with
         | [] ->
             Printf.eprintf "not in trash: %s\n" path;
             Lwt.return_unit
         | (trash_key, m) :: _ ->
             (* Re-attach the folder under its original parent's namespace; the
                subtree is untouched, so this is O(1). Its local mirror copy is
                rebuilt by a subsequent full sync. *)
             let par = match Filename.dirname path with "." -> "" | d -> d in
             let* pid =
               Folder_ids.resolve ~cache_root:C.cache_root
                 ~domain_name:C.domain_name par
             in
             let new_key =
               C.domain_prefix
               ^ Folder.child_key ~folder_id:pid (Filename.basename path)
             in
             let marker =
               Folder.marker_to_string
                 { Folder.name = m.Folder.name; id = m.Folder.id }
             in
             let* () =
               Lwt_list.iter_s
                 (fun (module Bk : Backend.S) ->
                   Bk.put ~key:new_key ~data:marker ())
                 C.backends
             in
             let* () =
               Lwt_list.iter_s
                 (fun (module Bk : Backend.S) -> Bk.delete ~key:trash_key ())
                 C.backends
             in
             Printf.printf
               "restored %s — run 'tsync sync' to rebuild it locally\n" path;
             Lwt.return_unit)
  in
  Cmd.v
    (Cmd.info "untrash" ~doc:"Restore a trashed folder (see: tsync trash)")
    Term.(const run $ path_arg $ trash_domain_arg)

(* ── tsync expire ────────────────────────────────────────────────────────── *)

let expire_cmd =
  let date_arg =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"DATE"
          ~doc:"Cutoff date YYYY-MM-DD; versions older than this are removed")
  in
  let parse_date s =
    try
      Scanf.sscanf s "%d-%d-%d" (fun year mon day ->
          fst
            (Unix.mktime
               {
                 Unix.tm_year = year - 1900;
                 tm_mon = mon - 1;
                 tm_mday = day;
                 tm_hour = 0;
                 tm_min = 0;
                 tm_sec = 0;
                 tm_wday = 0;
                 tm_yday = 0;
                 tm_isdst = false;
               }))
    with _ -> failwith ("invalid date (expected YYYY-MM-DD): " ^ s)
  in
  let domain_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")
  in
  let run date domain =
    match
      Lwt_main.run
        (let cutoff = parse_date date in
         let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
         let (module C : Conf.S) = make_conf ?domain cfg in
         let module E = Expire.Make (C) in
         E.expire ~cutoff ())
    with
      | s ->
          Printf.printf "Removed %d version(s), %d chunk(s); kept %d chunk(s)\n"
            s.Expire.versions_deleted s.chunks_deleted s.chunks_kept
      | exception Failure msg -> Printf.eprintf "Error: %s\n" msg
  in
  Cmd.v
    (Cmd.info "expire"
       ~doc:
         "Remove versions older than DATE, then garbage-collect unused chunks")
    Term.(const run $ date_arg $ domain_arg)

(* ── tsync auto-evict ────────────────────────────────────────────────────── *)

let auto_evict_cmd =
  let state_arg =
    Arg.(
      value
      & pos 0 (some string) None
      & info [] ~docv:"on|off|status"
          ~doc:"Enable, disable, or query auto-evict after upload")
  in
  let auto_evict_result obj =
    match List.assoc_opt "result" obj with Some (`String s) -> s | _ -> ""
  in
  let run state =
    match state with
      | None | Some "status" -> (
          match ipc_action ~arg:"status" "auto_evict" with
            | obj -> Printf.printf "auto-evict: %s\n" (auto_evict_result obj)
            | exception Failure msg -> Printf.eprintf "Error: %s\n" msg)
      | Some (("on" | "off") as s) -> (
          match ipc_action ~arg:s "auto_evict" with
            | _ -> Printf.printf "auto-evict: %s\n" s
            | exception Failure msg -> Printf.eprintf "Error: %s\n" msg)
      | Some other -> Printf.eprintf "Expected on|off|status, got: %s\n" other
  in
  Cmd.v
    (Cmd.info "auto-evict" ~doc:"Enable or disable auto-evict after upload")
    Term.(const run $ state_arg)

(* ── tsync sync ──────────────────────────────────────────────────────────── *)

let sync_cmd =
  let domain_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")
  in
  let full_arg =
    Arg.(
      value & flag
      & info ["full"]
          ~doc:
            "Force a full resync: clear the local cache and re-download all \
             manifests from the backend")
  in
  let parallelism_arg =
    Arg.(
      value & opt int 32
      & info ["parallelism"; "j"] ~docv:"N"
          ~doc:
            "Max concurrent backend operations during a full resync (default \
             32). Lower it if you hit DNS or open-file limits.")
  in
  let render_op = function
    | `Put (k, size) -> Printf.sprintf "put %s (%Ld bytes)" k size
    | `Delete k -> "delete " ^ k
    | `Mkdir k -> "mkdir " ^ k
    | `Rmdir k -> "rmdir " ^ k
    | `Rename { Journal.src; dst; is_dir; _ } ->
        Printf.sprintf "rename %s -> %s%s" src dst
          (if is_dir then " (dir)" else "")
  in
  let run domain full parallelism v =
    verbose := v;
    Lwt_main.run
      (let open Lwt.Syntax in
       let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
       let (module C : Conf.S) = make_conf ?domain cfg in
       let module J = Journal.Make (C) in
       let module Fs = File_store.Make (C) in
       let module St = Store.Make (C) (Layout.Inode.Make (C)) in
       let module Sq = Sync_queue.Make (C) in
       let module F = File.Make (C) (Sq) in
       Sq.start
         ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
         ~on_cursor:(fun ~entry_key:_ -> ())
         ~on_upload_done:(fun ~key:_ -> Lwt.return_unit);
       let my_uuid = J.client_uuid () in
       if !verbose then
         Log.info "syncing domain %s (client %s, uuid %s)" C.domain_name
           C.client_name my_uuid;

       (* ── Sync bookmark: the journal key up to which this client is synced ── *)
       let last_sync_file =
         Filename.concat C.data_dir ("last-sync-" ^ C.domain_name)
       in
       let read_bookmark () =
         if Sys.file_exists last_sync_file then (
           let ic = open_in last_sync_file in
           let s = input_line ic in
           close_in ic;
           String.trim s)
         else ""
       in
       let write_bookmark key =
         let oc = open_out last_sync_file in
         output_string oc key;
         close_out oc
       in

       (* ── Journal sync: recover this client's own pending entries ────────── *)
       (* A pending entry that never reached the backend is replayed, minus any
          op another client has since overridden (last-writer-wins). *)
       let recover_entry entry_key ops =
         let short = Filename.basename entry_key in
         let* head = Fs.head_opt ~key:(C.journal_prefix ^ entry_key) in
         if head <> None then begin
           if !verbose then
             Log.info "%s: already published remotely, cleaned up" short;
           J.delete_local_pending ~entry_key
         end
         else begin
           (* Keys another client touched after this entry — those ops lose. *)
           let* newer_keys = Fs.list_journal_keys ~start_after:entry_key () in
           let remotely_modified = Hashtbl.create 16 in
           let* () =
             iter_pooled
               (fun (ek, uuid) ->
                 if uuid = my_uuid then Lwt.return_unit
                 else
                   let+ e = Fs.get_journal_entry ek in
                   match e with
                     | None -> ()
                     | Some remote_ops ->
                         List.iter
                           (fun op ->
                             match op with
                               | `Put (k, _) | `Delete k | `Mkdir k | `Rmdir k
                                 ->
                                   Hashtbl.replace remotely_modified k ()
                               | `Rename { Journal.dst; src; _ } ->
                                   Hashtbl.replace remotely_modified dst ();
                                   Hashtbl.replace remotely_modified src ())
                           remote_ops)
               newer_keys
           in
           let replayed =
             List.filter
               (fun op ->
                 let k =
                   match op with
                     | `Put (k, _) | `Delete k | `Mkdir k | `Rmdir k -> k
                     | `Rename { Journal.dst = k; _ } -> k
                 in
                 not (Hashtbl.mem remotely_modified k))
               ops
           in
           let skipped = List.length ops - List.length replayed in
           if !verbose then
             Log.info "%s: replaying %d/%d op%s%s" short (List.length replayed)
               (List.length ops)
               (if List.length ops = 1 then "" else "s")
               (if skipped > 0 then
                  Printf.sprintf " (%d skipped — remotely overridden)" skipped
                else "");
           (* Ops keep their journal order (a rename must follow its create). *)
           let* () =
             Lwt_list.iter_s
               (fun op ->
                 Lwt.catch
                   (fun () ->
                     match op with
                       | `Put (rel_key, _) ->
                           let key = C.domain_prefix ^ rel_key in
                           let* cached = F.is_cached key in
                           if cached then F.upload key else Lwt.return_unit
                       | `Delete rel_key ->
                           F.apply_delete (C.domain_prefix ^ rel_key)
                       | `Mkdir rel_key -> F.mkdir (C.domain_prefix ^ rel_key)
                       | `Rmdir rel_key -> F.rmdir (C.domain_prefix ^ rel_key)
                       | `Rename { Journal.dst = dst_rel; src = src_rel; _ } ->
                           F.rename
                             ~src:(C.domain_prefix ^ src_rel)
                             ~dst:(C.domain_prefix ^ dst_rel))
                   (fun exn ->
                     Log.err "recover_pending_ops: %s" (Printexc.to_string exn);
                     Lwt.return_unit))
               replayed
           in
           let* () =
             if replayed <> [] then
               let* (_ : string) = Fs.write_journal_entry ~entry_key replayed in
               Fs.bump_cursor entry_key
             else Lwt.return_unit
           in
           J.delete_local_pending ~entry_key
         end
       in
       let recover_pending () =
         let* pending = J.local_pending_entries ~uuid:my_uuid in
         if !verbose then
           Log.info "recovering %d pending journal entr%s" (List.length pending)
             (if List.length pending = 1 then "y" else "ies");
         (* Sequential: entries replay in journal order. *)
         Lwt_list.iter_s
           (fun (entry_key, ops) -> recover_entry entry_key ops)
           pending
       in

       (* ── Manifest sync (full): rebuild the local mirror from the backend ── *)
       (* Walk the inode tree from the root: each folder namespace lists its file
          manifests and folder markers; a marker gives a subfolder's name+id
          (recorded locally so keys resolve) and the id of its own namespace to
          recurse into.

          Concurrency is bounded by a single [pool] shared across the whole
          recursion, so in-flight backend connections and open files stay under
          [parallelism] no matter how wide or deep the tree — a per-namespace
          bound would multiply with depth and exhaust DNS / file descriptors. A
          pool slot only covers a fetch and its immediate local write; recursion
          runs after the slot is released, so a deep tree cannot deadlock. *)
       let rebuild_mirror () =
         let pool =
           Lwt_pool.create (max 1 parallelism) (fun () -> Lwt.return_unit)
         in
         let use f = Lwt_pool.use pool f in
         let join rel name = if rel = "" then name else rel ^ "/" ^ name in
         let count = ref 0 and failed = ref 0 in
         let rec walk folder_id rel =
           let* entries = use (fun () -> St.list_namespace ~folder_id) in
           Lwt_list.iter_p
             (fun (e : Backend.file_entry) ->
               Lwt.catch
                 (fun () ->
                   let* next =
                     use (fun () ->
                         let* data = St.get_object ~bkey:e.key in
                         match Folder.marker_of_string data with
                           | Some m ->
                               let child = join rel m.Folder.name in
                               let+ () =
                                 Folder_ids.write ~cache_root:C.cache_root
                                   ~domain_name:C.domain_name child m
                               in
                               Some (m.Folder.id, child)
                           | None -> (
                               match Manifest.of_string data with
                                 | `Clean man as state ->
                                     incr count;
                                     if !verbose then
                                       Log.info "manifest %s"
                                         (join rel man.Manifest.name);
                                     let+ () =
                                       F.write_manifest
                                         (C.domain_prefix
                                        ^ join rel man.Manifest.name)
                                         state
                                     in
                                     None
                                 | `Dirty -> Lwt.return_none
                                 | exception _ -> Lwt.return_none))
                   in
                   match next with
                     | Some (id, child) -> walk id child
                     | None -> Lwt.return_unit)
                 (fun exn ->
                   incr failed;
                   Log.warn "resync %s: %s" e.key (Printexc.to_string exn);
                   Lwt.return_unit))
             entries
         in
         let+ () = walk Folder.root_id "" in
         (!count, !failed)
       in
       let full_resync reason =
         if !verbose then Log.info "full resync: %s" reason;
         (* Clear the mirror ourselves, then rebuild it, and only once every
            manifest is in place notify the daemon so it re-reads the complete,
            fresh mirror (rather than an empty one mid-rebuild). *)
         let* () =
           Local.clear ~cache_root:C.cache_root ~domain_name:C.domain_name
         in
         let* n, failed = rebuild_mirror () in
         write_bookmark (C.journal_prefix ^ J.entry_key ());
         (try
            if !verbose then Log.info "notifying daemon of completed resync";
            ignore (ipc_action ~socket_path:C.socket_path "full_resync")
          with
           | Failure msg -> Printf.eprintf "Warning: full_resync: %s\n" msg
           | _ -> ());
         Printf.printf "full resync: %d manifest%s downloaded%s\n" n
           (if n = 1 then "" else "s")
           (if failed > 0 then
              Printf.sprintf
                " (%d failed — re-run 'tsync sync --full' to complete)" failed
            else "");
         Lwt.return_unit
       in

       (* ── Journal sync (incremental): apply other clients' recent entries ── *)
       let incremental ~last_sync_key ~all_keys =
         let last_sync_basename = Filename.basename last_sync_key in
         let recent_foreign =
           all_keys
           |> List.filter (fun (k, _) -> k > last_sync_basename)
           |> List.filter (fun (_, uuid) -> uuid <> my_uuid)
         in
         (* Sequential: foreign entries apply in journal order. *)
         let* () =
           Lwt_list.iter_s
             (fun (ek, _) ->
               let* e = Fs.get_journal_entry ek in
               match e with
                 | None -> Lwt.return_unit
                 | Some ops ->
                     if !verbose then
                       Log.info "journal entry %s: %s" ek
                         (String.concat ", " (List.map render_op ops));
                     F.apply_foreign_ops ops)
             recent_foreign
         in
         (match all_keys with
           | [] -> ()
           | _ ->
               let last_key, _ = List.nth all_keys (List.length all_keys - 1) in
               write_bookmark (C.journal_prefix ^ last_key));
         let n = List.length recent_foreign in
         Printf.printf "%d journal entr%s from other clients\n" n
           (if n = 1 then "y" else "ies");
         Lwt.return_unit
       in

       (* ── Main flow ──────────────────────────────────────────────────────── *)
       let* () = recover_pending () in
       if !verbose then Log.info "draining upload queue";
       let* () = Sq.drain () in
       let last_sync_key = read_bookmark () in
       if !verbose then
         Log.info "last sync bookmark: %s"
           (if last_sync_key = "" then "none (first run)" else last_sync_key);
       let* all_keys = Fs.list_journal_keys () in
       if !verbose then
         Log.info "journal: %d entr%s" (List.length all_keys)
           (if List.length all_keys = 1 then "y" else "ies");
       let resync_reason =
         if full then Some "--full flag"
         else if last_sync_key = "" then Some "no bookmark (first run)"
         else (
           match all_keys with
             | (oldest_key, _) :: _
               when Journal.timestamp_ms_of_filename oldest_key
                    > Journal.timestamp_ms_of_filename last_sync_key ->
                 Some "bookmark older than oldest journal entry"
             | _ -> None)
       in
       match resync_reason with
         | Some reason -> full_resync reason
         | None -> incremental ~last_sync_key ~all_keys)
  in
  Cmd.v
    (Cmd.info "sync"
       ~doc:
         "Sync local cache with remote changes. Replays pending local journal \
          entries, then applies new journal entries from other clients. A full \
          resync (triggered by --full or when the local bookmark is stale) \
          clears the cache and re-downloads all manifests. Pass --verbose to \
          see a step-by-step breakdown.")
    Term.(const run $ domain_arg $ full_arg $ parallelism_arg $ verbose_arg)

(* ── tsync recheck ───────────────────────────────────────────────────────── *)

let recheck_cmd =
  let domain_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")
  in
  let run domain =
    let code =
      Lwt_main.run
        (let open Lwt.Syntax in
         let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
         let (module C : Conf.S) = make_conf ?domain cfg in
         let module Rc = Recheck.Make (C) in
         let* summary =
           Rc.run
             ~on_file:(fun ~rel status ->
               Printf.printf "%s\n%!" (Recheck.describe rel status))
             ()
         in
         match summary with
           | None ->
               Printf.eprintf "No local cache for domain %s\n" C.domain_name;
               Lwt.return 1
           | Some s ->
               Printf.printf
                 "\n\
                  %d file%s checked: %d repaired, %d unrepairable, %d skipped\n"
                 s.Recheck.checked
                 (if s.Recheck.checked = 1 then "" else "s")
                 s.Recheck.repaired s.Recheck.unrepairable s.Recheck.skipped;
               Lwt.return (if s.Recheck.unrepairable > 0 then 1 else 0))
    in
    if code <> 0 then exit code
  in
  Cmd.v
    (Cmd.info "recheck"
       ~doc:
         "Verify all remote chunks and manifests against the local cache, \
          repairing what can be repaired")
    Term.(const run $ domain_arg)

(* ── tsync resync-remote ─────────────────────────────────────────────────── *)

let resync_remote_cmd =
  let domain_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")
  in
  let source_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["source"] ~docv:"NAME"
          ~doc:
            "Backend to copy from, by its configured name. Default: the \
             primary backend.")
  in
  let run domain source v =
    verbose := v;
    let code =
      Lwt_main.run
        (let open Lwt.Syntax in
         let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
         let d = Conf_parsing.pick_domain ?domain cfg in
         (* Same ordering make_conf applies, so positions line up with
            C.backends. *)
         let labels =
           List.map
             (fun (b : Conf_parsing.backend_config) -> b.Conf_parsing.name)
             (Conf_parsing.order_backends d.Conf_parsing.backends)
         in
         let (module C : Conf.S) = make_conf ?domain cfg in
         let label i = List.nth labels i in
         let source_index =
           match source with
             | None -> Ok 0
             | Some name -> (
                 match
                   List.concat
                     (List.mapi
                        (fun i l -> if l = name then [i] else [])
                        labels)
                 with
                   | [i] -> Ok i
                   | [] ->
                       Error
                         (Printf.sprintf "no backend named %s (available: %s)"
                            name
                            (String.concat ", " labels))
                   | _ ->
                       Error
                         (Printf.sprintf
                            "backend name %s is ambiguous; set distinct \
                             \"name\" fields in the config"
                            name))
         in
         match source_index with
           | Error msg ->
               Printf.eprintf "%s\n" msg;
               Lwt.return 1
           | Ok _ when List.length C.backends < 2 ->
               Printf.eprintf
                 "resync-remote requires at least two configured backends \
                  (domain %s has %d)\n"
                 C.domain_name (List.length C.backends);
               Lwt.return 1
           | Ok source ->
               vprintf "resyncing from %s...\n" (label source);
               let module M = Mirror.Make (C) in
               let+ dests = M.resync ~source () in
               List.iter
                 (fun (dst : Mirror.dest_stats) ->
                   List.iter (Printf.printf "copied %s\n") dst.Mirror.copied;
                   Printf.printf
                     "%s -> %s: %d object%s checked, %d copied (%d bytes)\n"
                     (label source) (label dst.Mirror.index) dst.Mirror.checked
                     (if dst.Mirror.checked = 1 then "" else "s")
                     (List.length dst.Mirror.copied)
                     dst.Mirror.copied_bytes)
                 dests;
               0)
    in
    if code <> 0 then exit code
  in
  Cmd.v
    (Cmd.info "resync-remote"
       ~doc:
         "Sync one remote backend from another: copy every object of the \
          domain (manifests, chunks, journal, versions) that is missing or \
          size-mismatched on the other configured backends")
    Term.(const run $ domain_arg $ source_arg $ verbose_arg)

(* ── tsync import ────────────────────────────────────────────────────────── *)

let import_cmd =
  let domain_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")
  in
  let src_arg =
    Arg.(
      required
      & pos 0 (some dir) None
      & info [] ~docv:"DIR" ~doc:"Folder whose contents to import")
  in
  let only_arg =
    Arg.(
      value & opt_all string []
      & info ["only"] ~docv:"GLOB"
          ~doc:
            "Import only files matching GLOB (shell glob syntax; matched \
             against each entry's relative path and its basename). May be \
             repeated. --exclude is applied on top of the selected set.")
  in
  let exclude_arg =
    Arg.(
      value & opt_all string []
      & info ["exclude"] ~docv:"GLOB"
          ~doc:
            "Exclude files and directories matching GLOB (shell glob syntax; \
             matched against each entry's relative path and its basename). May \
             be repeated.")
  in
  let force_rehash_arg =
    Arg.(
      value & flag
      & info ["force-rehash"]
          ~doc:
            "Re-hash and re-upload every file even if already present in the \
             domain. Only changed or missing chunks are actually uploaded; the \
             manifest is always recomputed and republished.")
  in
  let run domain src only exclude force_rehash v =
    verbose := v;
    Lwt_main.run
      (let open Lwt.Syntax in
       let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
       let (module C : Conf.S) = make_conf ?domain cfg in
       let module I = Import.Make (C) in
       vprintf "importing from %s into domain %s\n" src C.domain_name;
       let+ summary =
         I.run ~only ~exclude ~force_rehash ~src
           ~on_dir:(fun ~rel -> Printf.printf "mkdir    %s\n%!" rel)
           ~on_file:(fun ~rel status ->
             match status with
               | Import.Imported size ->
                   Printf.printf "imported %s (%Ld bytes)\n%!" rel size
               | Import.Skipped_exists ->
                   Printf.printf "skip     %s (already in domain)\n%!" rel
               | Import.Skipped_symlink ->
                   Printf.printf "skip     %s (symlink)\n%!" rel
               | Import.Failed msg ->
                   Printf.printf "failed   %s: %s\n%!" rel msg)
           ()
       in
       Printf.printf
         "\n%d file%s imported, %d skipped, %d symlinks skipped, %d failed\n"
         summary.Import.imported
         (if summary.Import.imported = 1 then "" else "s")
         summary.Import.skipped summary.Import.skipped_symlinks
         summary.Import.failed;
       if summary.Import.failed > 0 then exit 1)
  in
  Cmd.v
    (Cmd.info "import"
       ~doc:
         "Import a folder into the domain: upload its files to all backends \
          and create manifest sidecars in the local cache. Data is not copied \
          — the cache links to the source files. Keys already in the domain \
          are skipped.")
    Term.(
      const run $ domain_arg $ src_arg $ only_arg $ exclude_arg
      $ force_rehash_arg $ verbose_arg)

(* ── tsync export ────────────────────────────────────────────────────────── *)

let export_cmd =
  let domain_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")
  in
  let dst_arg =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"DIR" ~doc:"Destination folder (created if needed)")
  in
  let run domain dst v =
    verbose := v;
    let code =
      Lwt_main.run
        (let open Lwt.Syntax in
         let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
         let (module C : Conf.S) = make_conf ?domain cfg in
         let module E = Export.Make (C) in
         vprintf "exporting domain %s to %s\n" C.domain_name dst;
         let+ summary =
           E.run ~dst
             ~on_file:(fun ~rel status ->
               match status with
                 | Export.Exported Export.Local_cache ->
                     Printf.printf "exported %s (local cache)\n%!" rel
                 | Export.Exported Export.Remote_chunks ->
                     Printf.printf "exported %s (remote)\n%!" rel
                 | Export.Exported Export.Symlink ->
                     Printf.printf "exported %s (symlink)\n%!" rel
                 | Export.Missing_data ->
                     Printf.printf
                       "MISSING  %s (no local data or remote manifest)\n%!" rel)
             ()
         in
         Printf.printf "\n%d file%s exported, %d missing\n"
           summary.Export.exported
           (if summary.Export.exported = 1 then "" else "s")
           summary.Export.missing;
         if summary.Export.missing > 0 then 1 else 0)
    in
    if code <> 0 then exit code
  in
  Cmd.v
    (Cmd.info "export"
       ~doc:
         "Export every file of the domain to a folder. Cached files are copied \
          locally; evicted files are recomposed from remote chunks without \
          populating the cache.")
    Term.(const run $ domain_arg $ dst_arg $ verbose_arg)

(* ── tsync configure ────────────────────────────────────────────────────── *)

(* Read a JSON value's field, tolerating non-objects and missing keys. *)
let jfield json key =
  match json with `Assoc l -> List.assoc_opt key l | _ -> None

let jstr json key =
  match jfield json key with Some (`String s) -> Some s | _ -> None

let jbool ?(default = false) json key =
  match jfield json key with Some (`Bool b) -> b | _ -> default

let jint json key =
  match jfield json key with Some (`Int n) -> Some n | _ -> None

let jlist json key = match jfield json key with Some (`List l) -> l | _ -> []

(* Update key in place (preserving position) or append it. *)
let assoc_set l key v =
  if List.mem_assoc key l then
    List.map (fun (k, v') -> if k = key then (key, v) else (k, v')) l
  else l @ [(key, v)]

(* One store's fields from `terraform output -json`. *)
type tf_store = {
  bucket : string;
  region : string;
  share_url : string;
  access_key_id : string;
  secret : string option;
}

let terraform_output dir =
  let cmd =
    Printf.sprintf "terraform -chdir=%s output -json 2>/dev/null"
      (Filename.quote dir)
  in
  let ic = Unix.open_process_in cmd in
  let buf = Buffer.create 4096 in
  let rec drain () =
    match input_line ic with
      | line ->
          Buffer.add_string buf line;
          Buffer.add_char buf '\n';
          drain ()
      | exception End_of_file -> ()
  in
  drain ();
  match Unix.close_process_in ic with
    | Unix.WEXITED 0 -> (
        try Some (Yojson.Basic.from_string (Buffer.contents buf))
        with _ -> None)
    | _ -> None

let tf_value root name =
  jfield (Option.value (jfield root name) ~default:`Null) "value"

(* Store keys present in `terraform output`. *)
let tf_stores root =
  match tf_value root "stores" with
    | Some (`Assoc l) -> List.map fst l
    | _ -> []

let tf_lookup root store =
  let value name = tf_value root name in
  match value "stores" with
    | Some stores -> (
        match jfield stores store with
          | Some s ->
              let str k = Option.value (jstr s k) ~default:"" in
              let secret =
                Option.bind (value "secret_access_keys") (fun m -> jstr m store)
              in
              Some
                {
                  bucket = str "bucket";
                  region = str "region";
                  share_url = str "share_url";
                  access_key_id = str "access_key_id";
                  secret;
                }
          | None -> None)
    | None -> None

(* ── Interactive prompt helpers ──────────────────────────────────────────── *)

(* Clear the screen and home the cursor, so menus redraw in place. *)
let clear_screen () =
  print_string "\027[H\027[2J";
  flush stdout

let prompt msg def =
  (match def with
    | Some d when d <> "" -> Printf.printf "%s [%s]: %!" msg d
    | _ -> Printf.printf "%s: %!" msg);
  let line = read_line () in
  if line = "" then Option.value def ~default:"" else line

let rec prompt_required msg =
  let v = prompt msg None in
  if v <> "" then v
  else begin
    Printf.printf "  (required — cannot be blank)\n%!";
    prompt_required msg
  end

let prompt_bool ?(default = false) msg =
  Printf.printf "%s [%s]: %!" msg (if default then "Y/n" else "y/N");
  match String.lowercase_ascii (read_line ()) with
    | "y" | "yes" -> true
    | "n" | "no" -> false
    | "" -> default
    | _ -> false

let prompt_int msg default =
  match int_of_string_opt (prompt msg (Some (string_of_int default))) with
    | Some n when n > 0 -> n
    | _ -> default

let read_password msg =
  Printf.printf "%s: %!" msg;
  let old_attr = Unix.tcgetattr Unix.stdin in
  Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH { old_attr with Unix.c_echo = false };
  match read_line () with
    | s ->
        Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH old_attr;
        print_newline ();
        s
    | exception e ->
        Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH old_attr;
        raise e

let prompt_symlinks default =
  let rec ask () =
    let v = prompt "Symlinks policy (keep/follow/skip)" (Some default) in
    if List.mem v ["keep"; "follow"; "skip"] then v
    else begin
      Printf.printf "  Unknown policy %S — choose keep, follow, or skip.\n%!" v;
      ask ()
    end
  in
  ask ()

(* ── Backend / domain builders ───────────────────────────────────────────── *)

(* Fields a Terraform store fills on an s3 backend. *)
let store_fields =
  ["bucket"; "region"; "accessKeyId"; "secretAccessKey"; "shareUrl"]

let apply_store_fields l (s : tf_store) =
  let l = assoc_set l "bucket" (`String s.bucket) in
  let l =
    if s.region = "" then l else assoc_set l "region" (`String s.region)
  in
  let l = assoc_set l "accessKeyId" (`String s.access_key_id) in
  let l =
    match s.secret with
      | Some sec -> assoc_set l "secretAccessKey" (`String sec)
      | None -> l
  in
  assoc_set l "shareUrl" (`String s.share_url)

(* Interactively pick a Terraform store (numbered menu of store + bucket) and read
   its outputs. Pulls once; nothing about Terraform is persisted. [None] on
   decline/failure. *)
let terraform_store () =
  let dir = prompt "  Terraform directory" (Some "terraform") in
  let fail msg =
    Printf.printf "  (%s)\n" msg;
    None
  in
  match terraform_output dir with
    | None -> fail (Printf.sprintf "could not read terraform output in %s" dir)
    | Some root -> (
        let entries =
          List.filter_map
            (fun k -> Option.map (fun s -> (k, s)) (tf_lookup root k))
            (tf_stores root)
        in
        match entries with
          | [] -> fail "no stores found in terraform output"
          | _ -> (
              Printf.printf "  Terraform stores:\n";
              List.iteri
                (fun i (k, (s : tf_store)) ->
                  Printf.printf "    %d. %-10s %s\n" (i + 1) k s.bucket)
                entries;
              let choice = prompt "  Choose a store by number" (Some "1") in
              match int_of_string_opt (String.trim choice) with
                | Some n when n >= 1 && n <= List.length entries ->
                    let k, s = List.nth entries (n - 1) in
                    Printf.printf "  Pulled store %S (bucket=%s).\n" k s.bucket;
                    Some s
                | _ -> fail "invalid choice"))

let prompt_backend () =
  let rec ask () =
    let t = prompt "  Backend type (s3/local/ssh)" (Some "s3") in
    if List.mem t ["s3"; "local"; "ssh"] then t
    else begin
      Printf.printf "  Unknown backend type %S — choose s3, local, or ssh.\n%!"
        t;
      ask ()
    end
  in
  let backend_type = ask () in
  let name = prompt "  Backend name" (Some backend_type) in
  (* For s3, offer to pull bucket/keys/share URL from Terraform up front, then
     only prompt the fields Terraform doesn't provide. *)
  let synced =
    if
      backend_type = "s3"
      && prompt_bool ~default:true
           "  Fill bucket/keys/share URL from Terraform?"
    then terraform_store ()
    else None
  in
  let spec = Option.value ~default:[] (Backend.spec_for backend_type) in
  let fields =
    List.filter_map
      (fun (s : Backend.field_spec) ->
        if synced <> None && List.mem s.name store_fields then None
        else (
          let value =
            match s.typ with
              | `Bool ->
                  string_of_bool
                    (prompt_bool ~default:(s.default = Some "true")
                       ("  " ^ s.label))
              | `String when s.secret ->
                  let rec ask () =
                    let v = read_password ("  " ^ s.label) in
                    if v <> "" then v
                    else begin
                      Printf.printf "  (required — cannot be blank)\n%!";
                      ask ()
                    end
                  in
                  ask ()
              | `String -> (
                  match s.default with
                    | None -> prompt_required ("  " ^ s.label)
                    | Some d ->
                        prompt ("  " ^ s.label)
                          (if d = "" then None else Some d))
          in
          match (s.typ, s.default, value) with
            | `String, Some "", "" -> None
            | `Bool, _, v -> Some (s.name, `Bool (v = "true"))
            | `String, _, v -> Some (s.name, `String v)))
      spec
  in
  let synced_fields =
    match synced with Some s -> apply_store_fields [] s | None -> []
  in
  let main =
    prompt_bool ~default:(backend_type = "local")
      "  Primary backend (used for reads)?"
  in
  `Assoc
    ([("name", `String name); ("type", `String backend_type)]
    @ synced_fields @ fields
    @ [("main", `Bool main)])

let prompt_backends () =
  let backends = ref [] in
  let n = ref 1 in
  let continue_ = ref true in
  while !continue_ do
    Printf.printf "\n  Backend %d\n" !n;
    backends := !backends @ [prompt_backend ()];
    incr n;
    continue_ := prompt_bool "  Add another backend?"
  done;
  !backends

(* Prompt one backend spec field, pre-filled with [current]. [None] omits it
   (blank optional string, or blank secret keeping no prior value). *)
let prompt_spec_field (s : Backend.field_spec) ~current =
  match s.typ with
    | `Bool ->
        let default =
          match current with
            | Some v -> v = "true"
            | None -> s.default = Some "true"
        in
        Some (s.name, `Bool (prompt_bool ~default s.label))
    | `String when s.secret ->
        let v = read_password (s.label ^ " (blank keeps current)") in
        if v <> "" then Some (s.name, `String v)
        else Option.map (fun c -> (s.name, `String c)) current
    | `String ->
        let def =
          match current with
            | Some c -> Some c
            | None -> ( match s.default with Some "" -> None | d -> d)
        in
        let v = prompt s.label def in
        if v = "" && s.default = Some "" then None else Some (s.name, `String v)

(* Per-field editor for one backend, with a Terraform sync action for s3. *)
let edit_backend b =
  let l = ref (match b with `Assoc l -> l | _ -> []) in
  let get k =
    match List.assoc_opt k !l with
      | Some (`String s) -> s
      | Some (`Bool b) -> string_of_bool b
      | _ -> ""
  in
  let btype = get "type" in
  let is_s3 = btype = "s3" in
  let spec = Option.value ~default:[] (Backend.spec_for btype) in
  let running = ref true in
  let status = ref "" in
  while !running do
    clear_screen ();
    Printf.printf "Editing backend: %s (%s)\n\nFields:\n" (get "name") btype;
    Printf.printf "  1. %-16s %s\n" "name:" (get "name");
    List.iteri
      (fun i (s : Backend.field_spec) ->
        let v = get s.name in
        Printf.printf "  %d. %-16s %s\n" (i + 2) (s.name ^ ":")
          (if s.secret && v <> "" then "***" else v))
      spec;
    let main_n = List.length spec + 2 in
    Printf.printf "  %d. %-16s %s\n" main_n "primary:" (get "main");
    if is_s3 then
      Printf.printf "  [t] sync bucket/keys/share URL from Terraform\n";
    if !status <> "" then Printf.printf "\n%s\n" !status;
    Printf.printf "\nEnter a field number to edit%s, or [d]one:\n> %!"
      (if is_s3 then ", [t] to sync" else "");
    status := "";
    let input = String.lowercase_ascii (String.trim (read_line ())) in
    match input with
      | "d" | "" -> running := false
      | "t" when is_s3 -> (
          match terraform_store () with
            | Some s -> l := apply_store_fields !l s
            | None -> ())
      | "1" ->
          l :=
            assoc_set !l "name"
              (`String (prompt "Backend name" (Some (get "name"))))
      | _ -> (
          match int_of_string_opt input with
            | Some n when n = main_n ->
                l :=
                  assoc_set !l "main"
                    (`Bool
                       (prompt_bool
                          ~default:(get "main" = "true")
                          "Primary backend?"))
            | Some n when n >= 2 && n <= List.length spec + 1 -> (
                let s = List.nth spec (n - 2) in
                match prompt_spec_field s ~current:(Some (get s.name)) with
                  | Some (k, v) -> l := assoc_set !l k v
                  | None -> l := List.remove_assoc s.name !l)
            | _ -> status := Printf.sprintf "(unknown field %S)" input)
  done;
  `Assoc !l

(* Backend list menu for a domain: add / edit / remove. *)
let edit_backends backends =
  let backends = ref backends in
  let running = ref true in
  let status = ref "" in
  while !running do
    clear_screen ();
    Printf.printf "Backends:\n";
    if !backends = [] then Printf.printf "  (none)\n"
    else
      List.iteri
        (fun i b ->
          Printf.printf "  %d. %s (%s)%s\n" (i + 1)
            (Option.value (jstr b "name") ~default:"?")
            (Option.value (jstr b "type") ~default:"?")
            (if jbool b "main" then " [primary]" else ""))
        !backends;
    if !status <> "" then Printf.printf "\n%s\n" !status;
    Printf.printf
      "\nEnter a backend number to edit, [a]dd, [r]emove N, or [d]one:\n> %!";
    status := "";
    let parts =
      List.filter (( <> ) "")
        (String.split_on_char ' '
           (String.lowercase_ascii (String.trim (read_line ()))))
    in
    let nth_ok i = i >= 1 && i <= List.length !backends in
    match parts with
      | [] | ["d"] -> running := false
      | ["a"] ->
          Printf.printf "\nNew backend\n";
          backends := !backends @ [prompt_backend ()]
      | ["r"; n] -> (
          match int_of_string_opt n with
            | Some i when nth_ok i ->
                backends := List.filteri (fun j _ -> j <> i - 1) !backends
            | _ -> status := "(need a valid backend number)")
      | [n] -> (
          match int_of_string_opt n with
            | Some i when nth_ok i ->
                backends :=
                  List.mapi
                    (fun j b -> if j = i - 1 then edit_backend b else b)
                    !backends
            | _ -> status := Printf.sprintf "(unknown action %S)" n)
      | _ -> status := "(unknown action)"
  done;
  !backends

let backend_summary = function
  | [] -> "(none)"
  | bs ->
      String.concat ", "
        (List.map (fun b -> Option.value (jstr b "type") ~default:"?") bs)

(* A frontend JSON entry is a bare type-name string or an object with a "type"
   key; both forms are accepted on read. *)
let frontend_type_of = function `String s -> Some s | j -> jstr j "type"

let frontend_summary = function
  | [] -> "(none)"
  | fs ->
      String.concat ", "
        (List.map (fun j -> Option.value (frontend_type_of j) ~default:"?") fs)

(* Toggle each compiled-in frontend on or off, pre-filled from [current]. Emits
   the enabled frontends as bare type-name strings (the config also accepts the
   [{"type": name, ...options}] object form). *)
let edit_frontends current =
  let registered = Frontend.names () in
  let is_on name =
    List.exists (fun j -> frontend_type_of j = Some name) current
  in
  List.filter_map
    (fun name ->
      if prompt_bool ~default:(is_on name) ("  Enable frontend " ^ name ^ "?")
      then Some (`String name)
      else None)
    registered

(* Build or edit one domain. A new domain ([existing = None]) is filled in
   linearly; an existing one is edited through a per-field menu, so untouched
   fields keep their current values without re-prompting. *)
let edit_domain existing =
  let cur k d =
    Option.value (Option.bind existing (fun j -> jstr j k)) ~default:d
  in
  let curbool k = match existing with Some j -> jbool j k | None -> false in
  let name = ref (cur "name" "default") in
  let versioning = ref (curbool "versioning") in
  let symlinks = ref (cur "symlinks" "keep") in
  let read_only = ref (curbool "readOnly") in
  let backends =
    ref (match existing with Some j -> jlist j "backends" | None -> [])
  in
  (* A new domain defaults to every compiled-in frontend (usually one). *)
  let frontends =
    ref
      (match existing with
        | Some j -> jlist j "frontends"
        | None -> List.map (fun name -> `String name) (Frontend.names ()))
  in
  (match existing with
    | None ->
        name := prompt "Domain name" (Some !name);
        versioning :=
          prompt_bool ~default:!versioning
            "Enable versioning (keep version history)?";
        symlinks := prompt_symlinks !symlinks;
        read_only :=
          prompt_bool ~default:!read_only
            "Read-only mount (block all local writes)?";
        backends := prompt_backends ();
        frontends := edit_frontends !frontends
    | Some _ ->
        let running = ref true in
        let status = ref "" in
        while !running do
          clear_screen ();
          Printf.printf "Editing domain: %s\n\nFields:\n" !name;
          Printf.printf "  1. name:        %s\n" !name;
          Printf.printf "  2. versioning:  %b\n" !versioning;
          Printf.printf "  3. symlinks:    %s\n" !symlinks;
          Printf.printf "  4. read-only:   %b\n" !read_only;
          Printf.printf "  5. backends:    %s\n" (backend_summary !backends);
          Printf.printf "  6. frontends:   %s\n" (frontend_summary !frontends);
          if !status <> "" then Printf.printf "\n%s\n" !status;
          Printf.printf "\nEnter a field number to edit, or [d]one:\n> %!";
          status := "";
          match String.lowercase_ascii (String.trim (read_line ())) with
            | "1" -> name := prompt "Domain name" (Some !name)
            | "2" ->
                versioning :=
                  prompt_bool ~default:!versioning "Enable versioning?"
            | "3" -> symlinks := prompt_symlinks !symlinks
            | "4" ->
                read_only := prompt_bool ~default:!read_only "Read-only mount?"
            | "5" -> backends := edit_backends !backends
            | "6" -> frontends := edit_frontends !frontends
            | "d" | "" -> running := false
            | other -> status := Printf.sprintf "(unknown field %S)" other
        done);
  `Assoc
    [
      ("name", `String !name);
      ("versioning", `Bool !versioning);
      ("symlinks", `String !symlinks);
      ("readOnly", `Bool !read_only);
      ("backends", `List !backends);
      ("frontends", `List !frontends);
    ]

(* Serialize globals + domains to [path] with 0600 perms. *)
let write_config ~path ~client_name ~max_uploads ~max_downloads ~tls ~domains =
  mkdir_p (Filename.dirname path);
  let json =
    `Assoc
      ([
         ("name", `String client_name);
         ("maxUploads", `Int max_uploads);
         ("maxDownloads", `Int max_downloads);
       ]
      @ (match tls with Some t -> [("tls", `String t)] | None -> [])
      @ [("domains", `List domains)])
  in
  let oc = open_out path in
  output_string oc (Yojson.Basic.pretty_to_string json);
  output_char oc '\n';
  close_out oc;
  Unix.chmod path 0o600

let configure_cmd =
  let run () =
    Printf.printf "tsync configuration\n-------------------\n";
    let config_path = runtime_paths.Runtime.config_path in
    let existing_root =
      if Sys.file_exists config_path then (
        match Yojson.Basic.from_file config_path with
          | j -> Some j
          | exception _ ->
              Printf.eprintf
                "Existing config at %s is not valid JSON; refusing to overwrite.\n"
                config_path;
              exit 1)
      else None
    in
    let client_name =
      ref
        (Option.value
           (Option.bind existing_root (fun r -> jstr r "name"))
           ~default:(Unix.gethostname ()))
    in
    let max_uploads =
      ref
        (Option.value
           (Option.bind existing_root (fun r -> jint r "maxUploads"))
           ~default:Conf_parsing.default_max_uploads)
    in
    let max_downloads =
      ref
        (Option.value
           (Option.bind existing_root (fun r -> jint r "maxDownloads"))
           ~default:Conf_parsing.default_max_downloads)
    in
    let tls = ref (Option.bind existing_root (fun r -> jstr r "tls")) in
    let domains =
      ref (match existing_root with Some r -> jlist r "domains" | None -> [])
    in
    let edit_globals () =
      client_name := prompt "Client name" (Some !client_name);
      max_uploads := prompt_int "Max concurrent uploads" !max_uploads;
      max_downloads := prompt_int "Max concurrent downloads" !max_downloads
    in
    (* A brand-new config: gather globals and the first domain up front. *)
    if existing_root = None then begin
      edit_globals ();
      Printf.printf "\nDomain 1\n";
      domains := [edit_domain None]
    end;
    (* On entry, select the default domain if one is set, else the first. *)
    let default_domain = read_default_domain () in
    let selected =
      ref
        (match
           Option.bind default_domain (fun name ->
               List.find_index (fun d -> jstr d "name" = Some name) !domains)
         with
          | Some i -> i
          | None -> if !domains = [] then -1 else 0)
    in
    let list_domains () =
      if !domains = [] then Printf.printf "  (no domains)\n"
      else
        List.iteri
          (fun i d ->
            let name = Option.value (jstr d "name") ~default:"?" in
            let btype =
              match jlist d "backends" with
                | b :: _ -> Option.value (jstr b "type") ~default:"?"
                | [] -> "none"
            in
            let dflt =
              if default_domain = Some name then " [default]" else ""
            in
            Printf.printf "%s %d. %s (%s)%s\n"
              (if i = !selected then ">" else " ")
              (i + 1) name btype dflt)
          !domains
    in
    let replace_nth i v = List.mapi (fun j x -> if j = i then v else x) in
    let remove_nth i = List.filteri (fun j _ -> j <> i) in
    let selected_name () =
      if !selected >= 0 && !selected < List.length !domains then
        Option.value (jstr (List.nth !domains !selected) "name") ~default:"?"
      else "(none)"
    in
    let saved = ref false in
    let running = ref true in
    let status = ref "" in
    while !running do
      clear_screen ();
      Printf.printf "tsync configuration\n-------------------\n\nDomains:\n";
      list_domains ();
      Printf.printf "\nSelected: %s\n" (selected_name ());
      if !status <> "" then Printf.printf "\n%s\n" !status;
      Printf.printf
        "\n\
         Enter a domain number to select, or an action:\n\
        \  [a]dd  [e]dit selected  [r]emove selected  [g]lobals  [w]rite  [q]uit\n\
         > %!";
      let action = String.lowercase_ascii (String.trim (read_line ())) in
      let has_sel = !selected >= 0 && !selected < List.length !domains in
      status := "";
      match int_of_string_opt action with
        | Some n ->
            if n >= 1 && n <= List.length !domains then selected := n - 1
            else status := Printf.sprintf "(no domain %d)" n
        | None -> (
            match action with
              | "a" ->
                  domains := !domains @ [edit_domain None];
                  selected := List.length !domains - 1
              | "e" ->
                  if has_sel then
                    domains :=
                      replace_nth !selected
                        (edit_domain (Some (List.nth !domains !selected)))
                        !domains
                  else status := "(select a domain first)"
              | "r" ->
                  if has_sel then begin
                    domains := remove_nth !selected !domains;
                    if !selected >= List.length !domains then
                      selected := List.length !domains - 1
                  end
                  else status := "(select a domain first)"
              | "g" -> edit_globals ()
              | "w" ->
                  if !domains = [] then
                    status := "(add at least one domain before writing)"
                  else begin
                    running := false;
                    saved := true
                  end
              | "q" ->
                  if prompt_bool "Quit without saving?" then running := false
              | "" -> ()
              | other -> status := Printf.sprintf "(unknown action %S)" other)
    done;
    if not !saved then Printf.printf "Aborted; config left untouched.\n"
    else begin
      (* Ask for a TLS backend only when an S3 domain exists, more than one is
         compiled in, and none is already set. *)
      let any_s3 =
        List.exists
          (fun d ->
            List.exists
              (fun b -> jstr b "type" = Some "s3")
              (jlist d "backends"))
          !domains
      in
      let available = Tls_conf.available () in
      if !tls = None && any_s3 && List.length available >= 2 then begin
        let choice =
          prompt
            (Printf.sprintf "TLS backend for S3 (%s)"
               (String.concat "/" available))
            (Some (List.hd available))
        in
        if List.mem choice available then tls := Some choice
      end;
      write_config ~path:config_path ~client_name:!client_name
        ~max_uploads:!max_uploads ~max_downloads:!max_downloads ~tls:!tls
        ~domains:!domains;
      Printf.printf "\nConfig written to %s\n" config_path
    end
  in
  Cmd.v
    (Cmd.info "configure" ~doc:"Create or edit the configuration (interactive)")
    Term.(const run $ const ())

(* ── tsync share ─────────────────────────────────────────────────────────── *)

(* "<N>d" / "<N>h" -> seconds *)
let parse_duration s =
  let n = String.length s in
  let fail () = failwith ("invalid duration (use <N>d or <N>h): " ^ s) in
  if n < 2 then fail ()
  else (
    match (int_of_string_opt (String.sub s 0 (n - 1)), s.[n - 1]) with
      | Some k, 'd' when k > 0 -> float_of_int (k * 86400)
      | Some k, 'h' when k > 0 -> float_of_int (k * 3600)
      | _ -> fail ())

let random_hex bytes =
  let b = Bytes.create bytes in
  let ic = open_in_bin "/dev/urandom" in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input ic b 0 bytes);
  String.concat ""
    (List.init bytes (fun i ->
         Printf.sprintf "%02x" (Char.code (Bytes.get b i))))

let share_cmd =
  let path_arg =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let expires_arg =
    Arg.(
      value & opt string "7d"
      & info ["expires"] ~docv:"DUR"
          ~doc:"Link lifetime as $(b,<N>d) or $(b,<N>h) (default 7d)")
  in
  let domain_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")
  in
  let token_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["token"] ~docv:"HEX"
          ~doc:
            "Reuse this share id instead of generating a random one, keeping \
             an existing link stable. Overwrites any share already at that id. \
             Must be lowercase hex.")
  in
  let run path expires domain token =
    (match token with
      | Some t
        when t = ""
             || String.exists
                  (fun c -> not (String.contains "0123456789abcdef" c))
                  t ->
          Printf.eprintf "--token must be non-empty lowercase hex\n";
          exit 1
      | _ -> ());
    let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
    let domain =
      match domain with Some _ -> domain | None -> read_default_domain ()
    in
    let d = Conf_parsing.pick_domain ?domain cfg in
    let ttl = parse_duration expires in
    let (module C : Conf.S) = make_conf ?domain cfg in
    let expires = int_of_float (Unix.time () +. ttl) in
    let url =
      Lwt_main.run
        (let open Lwt.Syntax in
         (* The share backend is the first of this domain's backends that serves
            shares (an s3 with a shareUrl, or an http-proxy that reports one). *)
         let* share_backend, share_url =
           let rec find = function
             | [] ->
                 Printf.eprintf "no backend in domain %s serves shares\n"
                   d.Conf_parsing.name;
                 exit 1
             | (module Bk : Backend.S) :: rest -> (
                 let* u = Bk.share_url ~prefix:C.domain_prefix () in
                 match u with
                   | Some url -> Lwt.return ((module Bk : Backend.S), url)
                   | None -> find rest)
           in
           find C.backends
         in
         let (module B : Backend.S) = share_backend in
         (* Resolve PATH to a domain-relative path; accept an absolute path under
            the mount point too. Empty rel means the whole domain. *)
         let mount_point =
           Filename.concat (Sys.getenv "HOME") ("tsync/" ^ C.domain_name)
         in
         let rel =
           let mp = mount_point ^ "/" in
           if
             String.length path >= String.length mp
             && String.sub path 0 (String.length mp) = mp
           then
             String.sub path (String.length mp)
               (String.length path - String.length mp)
           else path
         in
         let rel =
           if rel <> "" && rel.[String.length rel - 1] = '/' then
             String.sub rel 0 (String.length rel - 1)
           else rel
         in
         let base_json = [("v", `Int 1); ("expires", `Int expires)] in
         let module L = Layout.Inode.Make (C) in
         let* manifest =
           let* file_key = L.manifest_key (C.domain_prefix ^ rel) in
           (* A file manifest and a folder marker occupy the same key within a
              parent namespace, so classify by the body — otherwise a folder
              would be shared as a (chunkless) file and the Lambda would choke. *)
           let* obj =
             if rel = "" then Lwt.return_none else B.get_opt ~key:file_key ()
           in
           let marker = Option.bind obj Folder.marker_of_string in
           match (obj, marker) with
             | Some _, None ->
                 (* Single file: the Lambda fetches the manifest by this key. *)
                 Lwt.return
                   (`Assoc
                      (base_json
                      @ [
                          ("type", `String "file");
                          ("key", `String file_key);
                          ("chunkPrefix", `String C.chunk_prefix);
                          ("filename", `String (Filename.basename rel));
                        ]))
             | _ ->
                 (* Directory (a folder marker, or the domain root): store the
                    folder's namespace prefix (by id); the Lambda lists it lazily.
                    Keeps `tsync share` O(1). *)
                 let* dir_id =
                   match marker with
                     | Some m -> Lwt.return m.Folder.id
                     | None ->
                         Folder_ids.resolve ~cache_root:C.cache_root
                           ~domain_name:C.domain_name rel
                 in
                 let dir_prefix = C.domain_prefix ^ dir_id ^ "/" in
                 let* entries = B.list_all ~prefix:dir_prefix ~max_keys:1 () in
                 if entries = [] then (
                   Printf.eprintf "not found: %s\n" path;
                   exit 1);
                 let base =
                   if rel = "" then C.domain_name else Filename.basename rel
                 in
                 Lwt.return
                   (`Assoc
                      (base_json
                      @ [
                          ("type", `String "dir");
                          ("chunkPrefix", `String C.chunk_prefix);
                          ("dirPrefix", `String dir_prefix);
                          ("filename", `String (base ^ ".zip"));
                        ]))
         in
         (* The token is just the manifest's id; the server rebuilds the key as
            SHARES_PREFIX + token. Keeps the share URL short. Reuse a caller-
            supplied id (stable links) or generate a random one. *)
         let token = Option.value token ~default:(random_hex 16) in
         let manifest_key = Conf_parsing.shares_prefix d ^ token in
         let* () =
           B.put ~key:manifest_key ~data:(Yojson.Basic.to_string manifest) ()
         in
         Lwt.return (share_url ^ "/" ^ token))
    in
    let tm = Unix.localtime (float_of_int expires) in
    Printf.eprintf "Expires %04d-%02d-%02d %02d:%02d\n" (tm.Unix.tm_year + 1900)
      (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min;
    print_endline url
  in
  Cmd.v
    (Cmd.info "share" ~doc:"Print a shareable download URL for a file or folder")
    Term.(const run $ path_arg $ expires_arg $ domain_arg $ token_arg)

(* ── tsync print-config ──────────────────────────────────────────────────── *)

let print_conf_cmd =
  let mask (b : Conf_parsing.backend_config) k v =
    match Backend.spec_for b.backend_type with
      | None -> v
      | Some specs -> (
          match
            List.find_opt (fun (s : Backend.field_spec) -> s.name = k) specs
          with
            | Some { secret = true; _ } -> "***"
            | _ -> v)
  in
  let symlink_str = function
    | `Keep -> "keep"
    | `Follow -> "follow"
    | `Skip -> "skip"
  in
  let run () =
    let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
    let default = read_default_domain () in
    Printf.printf "name:          %s\n" cfg.Conf_parsing.name;
    Printf.printf "maxUploads:    %d\n" cfg.Conf_parsing.max_uploads;
    Printf.printf "maxDownloads:  %d\n" cfg.Conf_parsing.max_downloads;
    (match cfg.Conf_parsing.tls with
      | Some t -> Printf.printf "tls:           %s\n" t
      | None -> ());
    List.iter
      (fun (d : Conf_parsing.domain) ->
        Printf.printf "\ndomain: %s%s\n" d.name
          (if default = Some d.name then " [default]" else "");
        Printf.printf "  versioning: %b\n" d.versioning;
        Printf.printf "  read_only:  %b\n" d.read_only;
        Printf.printf "  symlinks:   %s\n" (symlink_str d.symlink_policy);
        Printf.printf "  frontends:  %s\n"
          (String.concat ", " (frontend_names d));
        List.iter
          (fun (b : Conf_parsing.backend_config) ->
            Printf.printf "  backend: %s (%s)%s\n" b.name b.backend_type
              (if b.main then " [primary]" else "");
            List.iter
              (fun (k, v) ->
                Printf.printf "    %-22s %s\n" (k ^ ":") (mask b k v))
              b.fields)
          d.backends)
      cfg.Conf_parsing.domains
  in
  Cmd.v
    (Cmd.info "print-config"
       ~doc:"Print the current configuration (sensitive values hidden)")
    Term.(const run $ const ())

(* ── tsync paths ─────────────────────────────────────────────────────────── *)

let paths_cmd =
  let run () =
    let p = runtime_paths in
    Printf.printf "config:  %s\n" p.Runtime.config_path;
    Printf.printf "cache:   %s\n" p.Runtime.cache_root;
    Printf.printf "data:    %s\n" p.Runtime.data_dir;
    Printf.printf "socket:  %s\n" p.Runtime.socket_path;
    Printf.printf "notify:  %s\n"
      (Filename.concat p.Runtime.data_dir "notify.sock")
  in
  Cmd.v
    (Cmd.info "paths" ~doc:"Show all filesystem paths used by this binary")
    Term.(const run $ const ())

(* ── tsync set-domain ────────────────────────────────────────────────────── *)

let set_domain_cmd =
  let name_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"NAME")
  in
  let clear_arg =
    Arg.(value & flag & info ["clear"] ~doc:"Clear the default domain")
  in
  let run name clear =
    let file = default_domain_file () in
    if clear || name = None then begin
      (try Unix.unlink file with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      print_endline "Default domain cleared."
    end
    else begin
      let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
      let name = Option.get name in
      match
        List.find_opt
          (fun (d : Conf_parsing.domain) -> d.name = name)
          cfg.Conf_parsing.domains
      with
        | None ->
            Printf.eprintf "Domain not found: %s\n" name;
            exit 1
        | Some _ ->
            mkdir_p (Filename.dirname file);
            let oc = open_out file in
            output_string oc (name ^ "\n");
            close_out oc;
            Printf.printf "Default domain set to: %s\n" name
    end
  in
  Cmd.v
    (Cmd.info "set-domain"
       ~doc:
         "Set (or clear) the default domain used when --domain is omitted. \
          With no arguments, shows the current default.")
    Term.(const run $ name_arg $ clear_arg)

(* ── tsync default-domain ────────────────────────────────────────────────── *)

let default_domain_cmd =
  let run () =
    match read_default_domain () with
      | Some name -> print_endline name
      | None ->
          Printf.eprintf "No default domain set.\n";
          exit 1
  in
  Cmd.v
    (Cmd.info "default-domain" ~doc:"Print the current default domain")
    Term.(const run $ const ())

(* ── tsync build-config ──────────────────────────────────────────────────── *)

let build_config_cmd =
  let run () =
    Printf.printf "frontends: %s\ns3 backend: %b\nlog: %s\n"
      (String.concat ", " (Frontend.names ()))
      S3_link.s3_backend_enabled Log.implementation
  in
  Cmd.v
    (Cmd.info "build-config"
       ~doc:"Show optional features compiled into this binary")
    Term.(const run $ const ())

(* ── Main ────────────────────────────────────────────────────────────────── *)

let () =
  let cmd =
    Cmd.group
      (Cmd.info "tsync" ~doc:"Cloud-backed filesystem sync")
      [
        build_config_cmd;
        configure_cmd;
        print_conf_cmd;
        paths_cmd;
        set_domain_cmd;
        default_domain_cmd;
        start_cmd;
        stop_cmd;
        status_cmd;
        stats_cmd;
        sync_cmd;
        recheck_cmd;
        resync_remote_cmd;
        import_cmd;
        export_cmd;
        evict_cmd;
        restore_cmd;
        pull_cmd;
        ls_cmd;
        share_cmd;
        versions_cmd;
        revert_cmd;
        trash_cmd;
        untrash_cmd;
        purge_cmd;
        expire_cmd;
        auto_evict_cmd;
      ]
  in
  exit (Cmd.eval cmd)
