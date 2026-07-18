open Cmdliner

(* ── Verbose output ──────────────────────────────────────────────────────── *)

let verbose = ref false

let vprintf fmt =
  if !verbose then Printf.printf fmt else Printf.ifprintf stdout fmt

let verbose_arg =
  Arg.(value & flag & info ["verbose"; "v"] ~doc:"Print detailed progress")

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let runtime_paths = Runtime.default_paths ()

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
  let domain_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["domain"] ~docv:"NAME" ~doc:"Domain name (default: from config)")
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
  let run mount domain tls =
    Log.init ();
    Log.debug "loading config from %s" runtime_paths.Runtime.config_path;
    let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
    (* CLI --tls wins over the config value applied by make_conf. *)
    if tls <> None then Tls_conf.apply tls;
    Log.debug "TLS backend: %s (available: %s)" (Tls_conf.current ())
      (String.concat ", " (Tls_conf.available ()));
    let domains =
      let name =
        match domain with Some n -> Some n | None -> read_default_domain ()
      in
      match name with
        | Some name -> [Conf_parsing.pick_domain ~domain:name cfg]
        | None ->
            if cfg.Conf_parsing.domains = [] then
              failwith "no domains configured";
            cfg.Conf_parsing.domains
    in
    let mount_fn domain_name =
      match (mount, domains) with
        | Some p, [_] -> p
        | _ -> Filename.concat (Sys.getenv "HOME") ("tsync/" ^ domain_name)
    in
    let confs =
      List.map
        (fun (d : Conf_parsing.domain) ->
          let socket_path = Runtime.domain_socket_path runtime_paths d.name in
          make_conf ~domain:d.name ~socket_path cfg)
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
        (fun (u, d) (module C : Conf.S) ->
          (u + C.max_uploads, d + C.max_downloads))
        (0, 0) confs
    in
    Lwt_unix.set_pool_size (min 256 (total_uploads + total_downloads + 32));
    List.iter
      (fun (module C : Conf.S) ->
        let mp = mount_fn C.domain_name in
        Log.debug "domain: %s, mount: %s" C.domain_name mp;
        mkdir_p mp;
        Runtime.pre_start ~mount_point:mp)
      confs;
    Log.debug "cache root: %s" runtime_paths.Runtime.cache_root;
    Log.debug "initializing runtime";
    Runtime.start ~confs ~mount_fn
  in
  Cmd.v
    (Cmd.info "start" ~doc:"Mount the filesystem (run via systemd unit)")
    Term.(const run $ mount_arg $ domain_arg $ tls_arg)

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
  let run path show_deleted domain =
    Lwt_main.run
      (let open Lwt.Syntax in
       let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
       let (module C : Conf.S) = make_conf ?domain cfg in
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
       List.iter
         (fun (e : Backend.file_entry) ->
           let name =
             if String.length e.key > dp_len then
               String.sub e.key dp_len (String.length e.key - dp_len)
             else e.key
           in
           let cached =
             Runtime.is_local ~cache_root:C.cache_root
               ~domain_name:C.domain_name ~domain_prefix:C.domain_prefix e.key
           in
           Printf.printf "%s  %s  %d bytes\n"
             (if cached then "local" else "cloud")
             name e.size)
         files;
       List.iter (fun d -> Printf.printf "dir    %s/\n" d) subdirs;
       if show_deleted then begin
         (* Versioned paths in this directory with no live manifest. *)
         let (module B : Backend.S) = List.hd C.backends in
         let reldir =
           String.sub prefix dp_len (String.length prefix - dp_len)
         in
         let seen = Hashtbl.create 16 in
         let* entries = B.list_all ~prefix:(C.versions_prefix ^ reldir) () in
         Lwt_list.iter_s
           (fun (e : Backend.file_entry) ->
             match
               Versioning.parse ~versions_prefix:C.versions_prefix e.key
             with
               | Some (rel, _) when not (Hashtbl.mem seen rel) ->
                   Hashtbl.add seen rel ();
                   let child =
                     String.sub rel (String.length reldir)
                       (String.length rel - String.length reldir)
                   in
                   if String.contains child '/' then Lwt.return_unit
                   else
                     let+ head = B.head_opt ~key:(C.domain_prefix ^ rel) () in
                     if head = None then Printf.printf "deleted  %s\n" child
               | _ -> Lwt.return_unit)
           entries
       end
       else Lwt.return_unit)
  in
  Cmd.v
    (Cmd.info "ls" ~doc:"List files with cache status")
    Term.(const run $ path_arg $ deleted_arg $ domain_arg)

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
       let (module B : Backend.S) = List.hd C.backends in
       let parse = Versioning.parse ~versions_prefix:C.versions_prefix in
       match path with
         | Some rel ->
             let+ entries =
               B.list_all ~prefix:(C.versions_prefix ^ rel ^ "/") ()
             in
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
             let latest = Hashtbl.create 64 and count = Hashtbl.create 64 in
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
                       Hashtbl.replace count rel
                         (1
                         + Option.value ~default:0 (Hashtbl.find_opt count rel)
                         )
                   | None -> ())
               entries;
             let* deleted =
               Hashtbl.fold
                 (fun rel ts acc ->
                   let* acc = acc in
                   let+ head = B.head_opt ~key:(C.domain_prefix ^ rel) () in
                   if head = None then
                     ( rel,
                       ts,
                       Option.value ~default:1 (Hashtbl.find_opt count rel) )
                     :: acc
                   else acc)
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
  let render_op = function
    | `Put (k, size) -> Printf.sprintf "put %s (%Ld bytes)" k size
    | `Delete k -> "delete " ^ k
    | `Mkdir k -> "mkdir " ^ k
    | `Rmdir k -> "rmdir " ^ k
    | `Rename { Journal.src; dst; is_dir; _ } ->
        Printf.sprintf "rename %s -> %s%s" src dst
          (if is_dir then " (dir)" else "")
  in
  let run domain full v =
    verbose := v;
    Lwt_main.run
      (let open Lwt.Syntax in
       let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
       let (module C : Conf.S) = make_conf ?domain cfg in
       let module J = Journal.Make (C) in
       let module Fs = File_store.Make (C) in
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
       let recover_entry entry_key ops =
         let short = Filename.basename entry_key in
         let remote_key = C.journal_prefix ^ entry_key in
         let* head = Fs.head_opt ~key:remote_key in
         if head <> None then begin
           if !verbose then
             Log.info "%s: already published remotely, cleaned up" short;
           J.delete_local_pending ~entry_key
         end
         else begin
           let* newer_keys = Fs.list_journal_keys ~start_after:entry_key () in
           let remotely_modified = Hashtbl.create 16 in
           let* () =
             Lwt_list.iter_s
               (fun (ek, uuid) ->
                 if uuid <> my_uuid then
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
                           remote_ops
                 else Lwt.return_unit)
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
                       | `Mkdir rel_key ->
                           Fs.create_directory ~key:(C.domain_prefix ^ rel_key)
                       | `Rmdir rel_key ->
                           Fs.delete_dir ~prefix:(C.domain_prefix ^ rel_key)
                       | `Rename
                           { Journal.dst = dst_rel; src = src_rel; is_dir; _ }
                         ->
                           let src_key = C.domain_prefix ^ src_rel in
                           let dst_key = C.domain_prefix ^ dst_rel in
                           if is_dir then
                             Fs.rename_directory ~src_prefix:(src_key ^ "/")
                               ~dst_prefix:(dst_key ^ "/")
                           else Fs.rename_file ~src_key ~dst_key)
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
       let* pending = J.local_pending_entries ~uuid:my_uuid in
       if !verbose then
         Log.info "recovering %d pending journal entr%s" (List.length pending)
           (if List.length pending = 1 then "y" else "ies");
       let* () =
         Lwt_list.iter_s
           (fun (entry_key, ops) -> recover_entry entry_key ops)
           pending
       in
       if !verbose then Log.info "draining upload queue";
       let* () = Sq.drain () in
       let share_dir = C.data_dir in
       let last_sync_file =
         Filename.concat share_dir ("last-sync-" ^ C.domain_name)
       in
       let last_sync_key =
         if Sys.file_exists last_sync_file then (
           let ic = open_in last_sync_file in
           let s = input_line ic in
           close_in ic;
           String.trim s)
         else ""
       in
       if !verbose then
         Log.info "last sync bookmark: %s"
           (if last_sync_key = "" then "none (first run)" else last_sync_key);
       let* all_keys = Fs.list_journal_keys () in
       if !verbose then
         Log.info "journal: %d entr%s" (List.length all_keys)
           (if List.length all_keys = 1 then "y" else "ies");
       let need_full_resync =
         if full || last_sync_key = "" then true
         else (
           match all_keys with
             | [] -> false
             | (oldest_key, _) :: _ ->
                 Journal.timestamp_ms_of_filename oldest_key
                 > Journal.timestamp_ms_of_filename last_sync_key)
       in
       if need_full_resync then begin
         if !verbose then
           Log.info "full resync: %s"
             (if full then "--full flag"
              else if last_sync_key = "" then "no bookmark (first run)"
              else "bookmark older than oldest journal entry");
         (try
            if !verbose then Log.info "sending full_resync to daemon";
            ignore (ipc_action ~socket_path:C.socket_path "full_resync")
          with
           | Failure msg -> Printf.eprintf "Warning: full_resync: %s\n" msg
           | _ -> ());
         let* files = Fs.list_all_files ~prefix:C.domain_prefix in
         let is_marker k =
           String.length k > 0 && k.[String.length k - 1] = '/'
         in
         let file_entries =
           List.filter
             (fun (e : Backend.file_entry) -> not (is_marker e.key))
             files
         in
         Log.info "downloading %d manifest%s" (List.length file_entries)
           (if List.length file_entries = 1 then "" else "s");
         let pool =
           Lwt_pool.create C.max_downloads (fun () -> Lwt.return_unit)
         in
         let* () =
           Lwt_list.iter_p
             (fun (e : Backend.file_entry) ->
               Lwt_pool.use pool (fun () ->
                   Lwt.catch
                     (fun () ->
                       let* m = F.resolved_manifest e.key in
                       match m with
                         | Some state ->
                             if !verbose then Log.info "manifest %s" e.key;
                             F.write_manifest e.key state
                         | None -> Lwt.return_unit)
                     (fun exn ->
                       Log.warn "manifest %s: %s" e.key (Printexc.to_string exn);
                       Lwt.return_unit)))
             file_entries
         in
         let new_key = C.journal_prefix ^ J.entry_key () in
         let oc = open_out last_sync_file in
         output_string oc new_key;
         close_out oc;
         Printf.printf "full resync: %d manifest%s downloaded\n"
           (List.length file_entries)
           (if List.length file_entries = 1 then "" else "s");
         Lwt.return_unit
       end
       else begin
         let last_sync_basename = Filename.basename last_sync_key in
         let recent_foreign =
           all_keys
           |> List.filter (fun (k, _) -> k > last_sync_basename)
           |> List.filter (fun (_, uuid) -> uuid <> my_uuid)
         in
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
               let oc = open_out last_sync_file in
               output_string oc (C.journal_prefix ^ last_key);
               close_out oc);
         let n = List.length recent_foreign in
         Printf.printf "%d journal entr%s from other clients\n" n
           (if n = 1 then "y" else "ies");
         Lwt.return_unit
       end)
  in
  Cmd.v
    (Cmd.info "sync"
       ~doc:
         "Sync local cache with remote changes. Replays pending local journal \
          entries, then applies new journal entries from other clients. A full \
          resync (triggered by --full or when the local bookmark is stale) \
          clears the cache and re-downloads all manifests. Pass --verbose to \
          see a step-by-step breakdown.")
    Term.(const run $ domain_arg $ full_arg $ verbose_arg)

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
  let run domain src exclude force_rehash v =
    verbose := v;
    Lwt_main.run
      (let open Lwt.Syntax in
       let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
       let (module C : Conf.S) = make_conf ?domain cfg in
       let module I = Import.Make (C) in
       vprintf "importing from %s into domain %s\n" src C.domain_name;
       let+ summary =
         I.run ~exclude ~force_rehash ~src
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
      const run $ domain_arg $ src_arg $ exclude_arg $ force_rehash_arg
      $ verbose_arg)

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

let configure_cmd =
  let run () =
    let prompt msg def =
      (match def with
        | Some d -> Printf.printf "%s [%s]: %!" msg d
        | None -> Printf.printf "%s: %!" msg);
      let line = read_line () in
      if line = "" then Option.value def ~default:"" else line
    in
    let prompt_required msg =
      let rec ask () =
        let v = prompt msg None in
        if v <> "" then v
        else begin
          Printf.printf "  (required — cannot be blank)\n%!";
          ask ()
        end
      in
      ask ()
    in
    let prompt_bool ?(default = false) msg =
      Printf.printf "%s [%s]: %!" msg (if default then "Y/n" else "y/N");
      match String.lowercase_ascii (read_line ()) with
        | "y" | "yes" -> true
        | "n" | "no" -> false
        | "" -> default
        | _ -> false
    in
    let prompt_int msg default =
      match int_of_string_opt (prompt msg (Some (string_of_int default))) with
        | Some n when n > 0 -> n
        | _ -> default
    in
    let read_password msg =
      Printf.printf "%s: %!" msg;
      let old_attr = Unix.tcgetattr Unix.stdin in
      Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH
        { old_attr with Unix.c_echo = false };
      match read_line () with
        | s ->
            Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH old_attr;
            print_newline ();
            s
        | exception e ->
            Unix.tcsetattr Unix.stdin Unix.TCSAFLUSH old_attr;
            raise e
    in
    let has_s3 = ref false in
    let prompt_backend () =
      let rec ask () =
        let t = prompt "  Backend type (s3/local/ssh)" (Some "s3") in
        if List.mem t ["s3"; "local"; "ssh"] then t
        else begin
          Printf.printf
            "  Unknown backend type %S — choose s3, local, or ssh.\n%!" t;
          ask ()
        end
      in
      let backend_type = ask () in
      if backend_type = "s3" then has_s3 := true;
      let name = prompt "  Backend name" (Some backend_type) in
      let spec = Option.value ~default:[] (Backend.spec_for backend_type) in
      let fields =
        List.filter_map
          (fun (s : Backend.field_spec) ->
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
              | `String, _, v -> Some (s.name, `String v))
          spec
      in
      let main_default = backend_type = "local" in
      let main =
        prompt_bool ~default:main_default "  Primary backend (used for reads)?"
      in
      `Assoc
        ([("name", `String name); ("type", `String backend_type)]
        @ fields
        @ [("main", `Bool main)])
    in
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
    in
    let prompt_domain () =
      let name = prompt "Domain name" (Some "default") in
      let key_prefix = prompt "Key prefix" (Some "tsync") in
      let versioning =
        prompt_bool "Enable versioning (keep version history)?"
      in
      let symlinks =
        let rec ask () =
          let v = prompt "Symlinks policy (keep/follow/skip)" (Some "keep") in
          if List.mem v ["keep"; "follow"; "skip"] then v
          else begin
            Printf.printf
              "  Unknown policy %S — choose keep, follow, or skip.\n%!" v;
            ask ()
          end
        in
        ask ()
      in
      let read_only = prompt_bool "Read-only mount (block all local writes)?" in
      let backends = prompt_backends () in
      `Assoc
        [
          ("name", `String name);
          ("prefix", `String key_prefix);
          ("versioning", `Bool versioning);
          ("symlinks", `String symlinks);
          ("readOnly", `Bool read_only);
          ("backends", `List backends);
        ]
    in
    Printf.printf "tsync configuration\n-------------------\n";
    let config_path = runtime_paths.Runtime.config_path in
    if
      Sys.file_exists config_path
      && not
           (prompt_bool
              (Printf.sprintf "Config already exists at %s. Overwrite?"
                 config_path))
    then (
      Printf.printf "Aborted; existing config left untouched.\n";
      exit 0);
    let client_name = prompt "Client name" (Some (Unix.gethostname ())) in
    let max_uploads =
      prompt_int "Max concurrent uploads" Conf_parsing.default_max_uploads
    in
    let max_downloads =
      prompt_int "Max concurrent downloads" Conf_parsing.default_max_downloads
    in
    let domains = ref [] in
    let continue_ = ref true in
    while !continue_ do
      Printf.printf "\nDomain %d\n" (List.length !domains + 1);
      domains := !domains @ [prompt_domain ()];
      continue_ := prompt_bool "Add another domain?"
    done;
    (* Only worth asking when there is an S3 backend and more than one TLS
       implementation is compiled in; otherwise there is nothing to choose. *)
    let tls_field =
      let available = Tls_conf.available () in
      if (not !has_s3) || List.length available < 2 then []
      else (
        let choice =
          prompt
            (Printf.sprintf "TLS backend for S3 (%s)"
               (String.concat "/" available))
            (Some (List.hd available))
        in
        if List.mem choice available then [("tls", `String choice)] else [])
    in
    mkdir_p (Filename.dirname config_path);
    let json =
      `Assoc
        ([
           ("name", `String client_name);
           ("maxUploads", `Int max_uploads);
           ("maxDownloads", `Int max_downloads);
         ]
        @ tls_field
        @ [("domains", `List !domains)])
    in
    let oc = open_out config_path in
    output_string oc (Yojson.Basic.pretty_to_string json);
    output_char oc '\n';
    close_out oc;
    Unix.chmod config_path 0o600;
    Printf.printf "\nConfig written to %s\nRun 'tsync start' to mount.\n"
      config_path
  in
  Cmd.v
    (Cmd.info "configure" ~doc:"Interactive configuration setup")
    Term.(const run $ const ())

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
        Printf.printf "  prefix:     %s\n" d.prefix;
        Printf.printf "  versioning: %b\n" d.versioning;
        Printf.printf "  read_only:  %b\n" d.read_only;
        Printf.printf "  symlinks:   %s\n" (symlink_str d.symlink_policy);
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
    Printf.printf "runtime: %s\ns3 backend: %b\nlog: %s\n"
      Runtime.implementation S3_link.s3_backend_enabled Log.implementation
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
        versions_cmd;
        revert_cmd;
        purge_cmd;
        expire_cmd;
        auto_evict_cmd;
      ]
  in
  exit (Cmd.eval cmd)
