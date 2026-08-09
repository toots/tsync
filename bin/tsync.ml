open Cmdliner
open Cli

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
    Log.Daemon.init ();
    Log.debug "loading config from %s" runtime_paths.Runtime.config_path;
    (* Not a failure: the installer starts the service before the user has
       configured anything. Exit 0 so launchd/systemd does not respawn. *)
    if not (Sys.file_exists runtime_paths.Runtime.config_path) then begin
      Printf.eprintf
        "No config at %s. Run `tsync configure`, then `tsync restart`.\n"
        runtime_paths.Runtime.config_path;
      exit 0
    end;
    let cfg = load_config () in
    (* CLI --tls wins over the config value applied by make_conf. *)
    if tls <> None then Tls_conf.apply tls;
    Log.debug "TLS backend: %s (available: %s)" (Tls_conf.current ())
      (String.concat ", " (Tls_conf.available ()));
    let domains =
      if cfg.Conf_parsing.domains = [] then begin
        Printf.eprintf "No domains configured in %s. Run `tsync configure`.\n"
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
    (* Do NOT touch Lwt here: any Lwt_unix/Lwt_preemptive call initializes the
       shared notification eventfd, and a child inheriting it across the fork
       below would have its worker wakeups delivered to the wrong process. Each
       leaf caps its own blocking pool after forking, from inside its own loop
       (see [Frontend.cap_blocking_pool]). *)
    (* One [binding] per (domain × frontend), grouped by frontend. Each group is
       its own process (all but the last forked), so distinct frontends on one
       domain run concurrently. *)
    let all_bindings =
      List.concat_map
        (fun (d, conf, mount_point) ->
          List.map
            (fun (f : Conf_parsing.frontend_config) ->
              ( f.Conf_parsing.frontend_type,
                { Frontend.conf; options = f.Conf_parsing.options; mount_point }
              ))
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
    Frontend.run_forked run_group groups
  in
  Cmd.v
    (Cmd.info "start" ~doc:"Mount the filesystem (run under a service manager)")
    Term.(const run $ mount_arg $ tls_arg)

let stop_cmd =
  let run () =
    (* Frontends without an IPC socket (http-proxy) are not reached here; a
       supervisor's SIGTERM stops that group. An absent or unconnectable socket
       just means that part is not running. *)
    let cfg = load_config () in
    let sockets =
      List.sort_uniq compare
        (List.map
           (fun (d : Conf_parsing.domain) ->
             Runtime.domain_socket_path runtime_paths d.Conf_parsing.name)
           cfg.Conf_parsing.domains)
    in
    let stopped = ref 0 in
    List.iter
      (fun socket_path ->
        match ipc_action ~socket_path "stop" with
          | _ -> incr stopped
          | exception Unix.Unix_error ((Unix.ECONNREFUSED | Unix.ENOENT), _, _)
            ->
              ()
          | exception Failure msg ->
              Printf.eprintf "Error stopping %s: %s\n" socket_path msg)
      sockets;
    if !stopped > 0 then Printf.printf "Stopped %d domain(s).\n" !stopped
    else print_endline "No IPC-backed frontend running; relying on signal."
  in
  Cmd.v
    (Cmd.info "stop" ~doc:"Stop the sync daemon")
    Term.(const run $ const ())

let status_cmd =
  let run domain =
    try
      let name, socket_path = domain_target ?domain () in
      match ipc_action ~socket_path ~domain:name "status" with
        | obj -> print_endline (Yojson.Safe.to_string (`Assoc obj))
        | exception _ -> Printf.printf "No daemon answering on %s\n" socket_path
    with e -> Printf.eprintf "Error: %s\n" (Printexc.to_string e)
  in
  Cmd.v
    (Cmd.info "status" ~doc:"Show daemon status")
    Term.(const run $ domain_arg)

(* The service manager already keeps and rotates the log, so this hands the
   terminal to the reader it provides rather than shipping lines over IPC. Only
   the daemon's own log — a frontend the OS starts elsewhere (the macOS
   FileProvider extension) logs where the OS decides. *)
let logs_cmd =
  let follow_arg =
    Arg.(
      value & flag & info ["f"; "follow"] ~doc:"Keep printing as lines arrive")
  in
  let lines_arg =
    Arg.(
      value & opt int 200
      & info ["n"; "lines"] ~docv:"N" ~doc:"How many past lines to show")
  in
  let run follow lines =
    let argv = Array.of_list (Runtime.log_command ~follow ~lines) in
    try Unix.execvp argv.(0) argv with
      | Unix.Unix_error (Unix.ENOENT, _, _) ->
          failwith
            (Printf.sprintf
               "%s not found: the daemon logs through syslog, so reading it \
                back needs this system's log reader"
               argv.(0))
      | Unix.Unix_error (e, _, _) ->
          failwith
            (Printf.sprintf "cannot run %s: %s" argv.(0) (Unix.error_message e))
  in
  Cmd.v
    (Cmd.info "logs"
       ~doc:
         "Show the daemon log. On Linux this reads the systemd journal, so it \
          needs systemd-journald; the daemon logs through syslog and keeps no \
          log file of its own. On macOS it reads the LaunchAgent's log file.")
    Term.(const run $ follow_arg $ lines_arg)

(* Uploads only: a download runs because something is blocked waiting for it. *)
let pause_cmd ~verb ~arg ~done_ ~doc =
  let run domain =
    try
      let name, socket_path = domain_target ?domain () in
      let (_ : (string * Yojson.Safe.t) list) =
        ipc_action ~socket_path ~domain:name ~arg "pause"
      in
      Printf.printf "Uploads %s for '%s'\n" done_ name
    with e -> Printf.eprintf "Error: %s\n" (Printexc.to_string e)
  in
  Cmd.v (Cmd.info verb ~doc) Term.(const run $ domain_arg)

let pause_uploads_cmd =
  pause_cmd ~verb:"pause" ~arg:"on" ~done_:"paused"
    ~doc:"Pause uploads (queued work is kept)"

let resume_uploads_cmd =
  pause_cmd ~verb:"resume" ~arg:"off" ~done_:"resumed"
    ~doc:"Resume paused uploads"

let human_bytes = Metrics.human_bytes

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
  let totals_arg =
    Arg.(
      value & flag
      & info ["totals"]
          ~doc:
            "Also report what each backend holds. The chunk count is estimated \
             from a sample of the store's shards; the manifest count is a full \
             listing. See $(b,--exact).")
  in
  let exact_arg =
    Arg.(
      value & flag
      & info ["exact"]
          ~doc:
            "With $(b,--totals), count every chunk instead of estimating from \
             a sample. Enumerates the whole chunk namespace, so it costs a \
             full listing per backend.")
  in
  let reload_arg =
    Arg.(
      value & flag
      & info ["reload"]
          ~doc:
            "With $(b,--totals), recount instead of reporting what was counted \
             before. A store is counted once and that figure served from then \
             on, with its age, until this asks for a new one.")
  in
  let run json totals exact reload watch domain =
    (* The daemon counts a store once and serves that until asked again, so the
       flags travel as a set, not a mode. *)
    let arg =
      match totals || exact || reload with
        | false -> None
        | true ->
            Some
              (String.concat ","
                 (["totals"]
                 @ (if exact then ["exact"] else [])
                 @ if reload then ["reload"] else []))
    in
    (* Resolved once: [--watch] must not re-read the config per tick, and a
       config error should surface before the screen starts clearing. *)
    let name, socket_path = domain_target ?domain () in
    let show () =
      match ipc_action ~socket_path ~domain:name ?arg "stats" with
        | obj when json ->
            let obj = ("t", `Float (Unix.gettimeofday ())) :: obj in
            print_endline (Yojson.Safe.to_string (`Assoc obj))
        | obj -> print_string (Diagnostics.text (`Assoc obj))
        | exception Failure msg -> Printf.eprintf "Error: %s\n" msg
        | exception _ -> Printf.printf "No daemon answering on %s\n" socket_path
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
       ~doc:
         "Report on the running daemon: transfer metrics, config as resolved, \
          cache, journal backlog and each backend's health")
    Term.(
      const run $ json_arg $ totals_arg $ exact_arg $ reload_arg $ watch_arg
      $ domain_arg)

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

let ls_cmd =
  let path_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let deleted_arg =
    Arg.(
      value & flag
      & info ["deleted"; "d"] ~doc:"Also list deleted files in the directory")
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
    run_lwt
      (let open Lwt.Syntax in
       let cfg = load_config () in
       let domain =
         match domain with Some _ -> domain | None -> read_default_domain ()
       in
       let (module C : Conf.S) = make_conf ?domain cfg in
       let (module F : Frontend.S) =
         resolve_frontend ?frontend (Conf_parsing.pick_domain ?domain cfg)
       in
       let module Fs = File_store.Make (C) in
       let mount_point =
         mount_point_of (Conf_parsing.pick_domain ?domain cfg)
       in
       let prefix =
         let dp = C.domain_prefix in
         match path with
           | None -> dp
           | Some p ->
               (* Accepts a domain-relative path or an absolute one under the
                  mount point. *)
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
       let module Mf = Manifest.Make (C) in
       let module B = (val C.store : Backend.S) in
       let* files, subdirs = Mf.list_children ~prefix () in
       let file_name (e : Backend.file_entry) =
         Key.strip_prefix ~domain_prefix:C.domain_prefix e.key
       in
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
                 let cached = F.is_local (Conf.locality (module C)) e.key in
                 Printf.printf "%s  %s  %d bytes\n"
                   (if cached then "local" else "cloud")
                   name e.size)
         items;
       if show_deleted then begin
         (* Versioned paths in this directory with no live manifest. *)
         let reldir =
           Key.chop_slash
             (Key.strip_prefix ~domain_prefix:C.domain_prefix prefix)
         in
         let seen = Hashtbl.create 16 in
         (* Versions of files in this directory share its folder id. *)
         let* fid =
           Folder_ids.ensure_id ~cache_root:C.cache_root
             ~domain_name:C.domain_name reldir
         in
         let* entries =
           B.list_prefix ~prefix:(C.versions_prefix ^ fid ^ "/") ()
         in
         Lwt_list.iter_s
           (fun (e : Backend.file_entry) ->
             (* Version keys are hashed: the real path is in the body. *)
               match
                 Versioning.parse ~versions_prefix:C.versions_prefix e.key
               with
               | Some (hrel, _) when not (Hashtbl.mem seen hrel) -> (
                   Hashtbl.add seen hrel ();
                   let* data = B.get ~key:e.key () in
                   match Manifest.of_string data with
                     | m ->
                         (* A missing live manifest means the file was deleted;
                            the leaf name comes from the version body. *)
                         let+ head =
                           B.head_opt ~key:(C.domain_prefix ^ hrel) ()
                         in
                         if head = None then
                           Printf.printf "deleted  %s\n"
                             (Manifest.recorded_name m)
                     | exception _ -> Lwt.return_unit)
               | _ -> Lwt.return_unit)
           entries
       end
       else Lwt.return_unit)
  in
  Cmd.v
    (Cmd.info "ls" ~doc:"List files with cache status")
    Term.(const run $ path_arg $ deleted_arg $ domain_arg $ frontend_arg)

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
  let run path domain =
    run_lwt
      (let open Lwt.Syntax in
       let (module C : Conf.S) = load_conf ?domain () in
       let module St = Store.Make (C) (Layout.Inode.Make (C)) in
       let module B = (val C.store : Backend.S) in
       let parse = Versioning.parse ~versions_prefix:C.versions_prefix in
       match path with
         | Some rel ->
             let* dir = St.version_dir ~key:(C.domain_prefix ^ rel) in
             let+ entries =
               match dir with
                 | None -> Lwt.return_nil
                 | Some dir -> B.list_prefix ~prefix:dir ()
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
             (* [sample] keeps one version key per file, so a deleted file's
                real path can be read out of its version body. *)
             let latest = Hashtbl.create 64
             and count = Hashtbl.create 64
             and sample = Hashtbl.create 64 in
             let* entries = B.list_prefix ~prefix:C.versions_prefix () in
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
                     | m -> Manifest.recorded_name m
                     | exception _ -> hrel)
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

let purge_cmd =
  let path_arg =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let run _path = Printf.eprintf "purge: not yet implemented\n" in
  Cmd.v
    (Cmd.info "purge" ~doc:"Delete all versions from trash")
    Term.(const run $ path_arg)

let trash_markers (module B : Backend.S) domain_prefix =
  B.list_prefix ~prefix:(domain_prefix ^ Folder.trash_id ^ "/") ()

let trash_cmd =
  let run domain =
    run_lwt
      (let open Lwt.Syntax in
       let (module C : Conf.S) = load_conf ?domain () in
       let module B = (val C.store : Backend.S) in
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
    Term.(const run $ domain_arg)

let untrash_cmd =
  let path_arg =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let run path domain =
    run_lwt
      (let open Lwt.Syntax in
       let (module C : Conf.S) = load_conf ?domain () in
       let module L = Layout.Inode.Make (C) in
       let module St = Store.Make (C) (L) in
       let module B = (val C.store : Backend.S) in
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
             (* O(1): the subtree is untouched. The local mirror copy is rebuilt
                by a later full sync. *)
             let* new_key = L.folder_marker_key (C.domain_prefix ^ path) in
             let new_key = Option.get new_key in
             let marker =
               Folder.marker_to_string
                 { Folder.name = m.Folder.name; id = m.Folder.id }
             in
             let* () = St.put_raw ~bkey:new_key ~data:marker in
             let* () = St.delete_raw ~bkey:trash_key in
             Printf.printf
               "restored %s — run 'tsync sync' to rebuild it locally\n" path;
             Lwt.return_unit)
  in
  Cmd.v
    (Cmd.info "untrash" ~doc:"Restore a trashed folder (see: tsync trash)")
    Term.(const run $ path_arg $ domain_arg)

let parse_duration s =
  let n = String.length s in
  let fail () =
    failwith ("invalid duration (use <N>d, <N>h, <N>m or <N>s): " ^ s)
  in
  if n < 2 then fail ()
  else (
    match (int_of_string_opt (String.sub s 0 (n - 1)), s.[n - 1]) with
      | Some k, 'd' when k > 0 -> float_of_int (k * 86400)
      | Some k, 'h' when k > 0 -> float_of_int (k * 3600)
      | Some k, 'm' when k > 0 -> float_of_int (k * 60)
      | Some k, 's' when k > 0 -> float_of_int k
      | _ -> fail ())

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
  let run date domain =
    match
      run_lwt
        (let cutoff = parse_date date in
         let (module C : Conf.S) = load_conf ?domain () in
         let module E = Expire.Make (C) in
         (* A domain with a long history spends minutes listing before it deletes
            anything, so say what is happening rather than sit silent. Progress
            goes to stderr, leaving stdout to the one summary line a script would
            read. *)
         E.expire
           ~on_list:(fun ~name -> Printf.eprintf "Listing %s...\n%!" name)
           ~on_scan:(fun ~name ~objects ->
             Printf.eprintf "  %s: %d object(s)\n%!" name objects)
           ~on_delete:(fun ~name ~deleted ->
             Printf.eprintf "  %s: %d deleted\r%!" name deleted)
           ~cutoff ())
    with
      | s ->
          Printf.printf "Removed %d version(s), %d journal entr(ies)\n"
            s.Expire.versions_deleted s.journal_deleted
      | exception Failure msg -> Printf.eprintf "Error: %s\n" msg
  in
  Cmd.v
    (Cmd.info "expire"
       ~doc:
         "Remove trashed folders, versions and journal entries older than DATE \
          (then: tsync gc)")
    Term.(const run $ date_arg $ domain_arg)

let gc_cmd =
  let budget_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["budget"] ~docv:"DUR"
          ~doc:
            "Spend at most this long, then stop and leave the collection open \
             where it is; the next $(b,tsync gc) continues from there. Checked \
             between batches, so a batch already running is not cut short. An \
             open collection is safe to leave indefinitely. One count and one \
             unit: $(b,30s), $(b,10m), $(b,2h), $(b,1d).")
  in
  let pause_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["pause"] ~docv:"DUR"
          ~doc:
            "Idle this long between batches. Where $(b,--budget) bounds how \
             long the whole thing takes, this bounds how hard it pushes while \
             it runs.")
  in
  let concurrency_arg =
    Arg.(
      value
      & opt (some int) None
      & info ["concurrency"] ~docv:"N"
          ~doc:
            "Operations in flight (default: what the device says). $(b,1) is \
             as gentle as it gets.")
  in
  let abort_arg =
    Arg.(
      value & flag
      & info ["abort"]
          ~doc:
            "Abandon an open collection, keeping every chunk it still holds. \
             Takes $(b,--budget), $(b,--pause) and $(b,--concurrency) like a \
             collection does, and resumes the same way — a second $(b,--abort) \
             continues abandoning rather than starting over.")
  in
  let status_arg =
    Arg.(
      value & flag
      & info ["status"] ~doc:"Report an open collection without continuing it.")
  in
  let report ~abort ~domain (s : Gc.stats) =
    (match s.Gc.outcome with
      | Gc.Completed when abort && s.chunks_promoted = 0 ->
          (* Nothing was open, or nothing was left in it. Either way saying
             "abandoned; 0 kept" invites the reader to wonder what happened to
             their chunks. *)
          Printf.printf "No collection was open for %s; nothing to abandon.\n"
            domain
      | Gc.Completed when abort ->
          Printf.printf "Collection abandoned; %d chunk(s) kept.\n"
            s.chunks_promoted
      | Gc.Completed ->
          Printf.printf "Reclaimed %d chunk(s), %s. Kept %d.\n"
            s.chunks_reclaimed
            (human_bytes s.bytes_reclaimed)
            s.chunks_promoted
      (* Each phase fills in different fields, so one fixed set of them would
         print zeroes that read as "nothing happened" rather than as "this phase
         does not count that".

         The continue line names the command that continues *this*: a plain
         [tsync gc] over an abandoned collection would go back to collecting it. *)
      | Gc.Suspended { phase; _ } when abort ->
          Printf.printf
            "Stopped while %s: %d chunk(s) kept so far.\n\
             Still open; rerun tsync gc --abort to continue.\n"
            phase s.chunks_promoted
      | Gc.Suspended { phase; _ } ->
          Printf.printf
            "Stopped while %s: %d file(s) marked, %d chunk(s) kept, %d \
             reclaimed.\n\
             Still open; rerun tsync gc to continue.\n"
            phase s.roots_marked s.chunks_promoted s.chunks_reclaimed);
    List.iter
      (fun (m : Gc.member_stats) ->
        Printf.printf "  %s: %d deleted%s\n" m.Gc.name m.deleted
          (if m.uploaded > 0 then Printf.sprintf ", %d filled" m.uploaded
           else ""))
      s.members
  in
  let run budget pause concurrency abort status domain =
    (* Reported as [Failure], which the top level prints as "tsync: <sentence>"
       and exits nonzero on. Both carry prose written for whoever typed this. *)
    let translate f =
      try f () with
        | Gc.Unsupported msg | Gc.Busy msg -> failwith msg
        | Failure msg -> failwith msg
    in
    let (module C : Conf.S) = load_conf ?domain () in
    let module G = Gc.Make (C) in
    if status then (
      match run_lwt (G.status ()) with
        | None -> Printf.printf "No collection is open for %s.\n" C.domain_name
        | Some r ->
            Printf.printf "Collection of %s open: %s, %.0fs so far.\n"
              C.domain_name
              (Chunk_space.string_of_phase r.Chunk_space.phase)
              (Unix.gettimeofday () -. r.Chunk_space.started))
    else (
      (* Abandoning is the same machinery with everything treated as live, so it
         takes the same pacing and reports the same way — whoever reaches for
         --abort is getting out of a collection that is already going badly.

         Progress to stderr, so stdout carries only the summary a script would
         read. *)
      let budget = Option.map parse_duration budget
      and pause = Option.map parse_duration pause in
      (* Carriage-return progress belongs on a terminal. Down a pipe it is a line
         of padding in front of the summary, so a non-interactive run gets the
         summary alone -- and the logs, which is what [-v] is for. *)
      let watching = Unix.isatty Unix.stderr in
      let progress fmt =
        if watching then Printf.eprintf fmt else Printf.ifprintf stderr fmt
      in
      let on_open () =
        progress "%s %s...\n%!"
          (if abort then "Abandoning the collection of" else "Collecting")
          C.domain_name
      in
      (* Abandoning walks shards and has no notion of a file; marking walks
         folders and counts the files in them, so the two get different lines
         rather than one with a field that means nothing in half the runs. *)
      let on_mark ~namespaces ~total ~roots ~promoted =
        if abort then
          progress "  kept %d/%d shard(s), %d chunk(s)\r%!" namespaces total
            promoted
        else
          progress "  marked %d/%d folder(s), %d file(s), %d chunk(s) kept\r%!"
            namespaces total roots promoted
      in
      let on_close ~shards ~reclaimed =
        progress "  closed %d shard(s), %d chunk(s) reclaimed\r%!" shards
          reclaimed
      in
      let on_reconcile ~name ~shards ~total ~deleted ~uploaded =
        progress "  %s: %d/%d shard(s), %d deleted, %d filled\r%!" name shards
          total deleted uploaded
      in
      translate (fun () ->
          let s =
            run_lwt
              (if abort then
                 G.abort ?budget ?pause ?concurrency ~on_open ~on_mark ~on_close
                   ~on_reconcile ()
               else
                 G.run ?budget ?pause ?concurrency ~on_open ~on_mark ~on_close
                   ~on_reconcile ())
          in
          (* The progress lines above end in a carriage return, so the last one is
             still sitting on the terminal's current line. Cleared before the
             summary goes to stdout, or the two land on top of each other. *)
          if watching then Printf.eprintf "\r%*s\r%!" 72 "";
          report ~abort ~domain:C.domain_name s))
  in
  Cmd.v
    (Cmd.info "gc"
       ~doc:
         "Reclaim chunks nothing references any more (run tsync expire first). \
          Local main stores only.")
    Term.(
      const run $ budget_arg $ pause_arg $ concurrency_arg $ abort_arg
      $ status_arg $ domain_arg)

let sync_cmd =
  let source_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["source"] ~docv:"NAME"
          ~doc:
            "Backend to sync from, by its configured name. Default: the \
             primary backend.")
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
  let run domain source full parallelism v =
    set_verbose v;
    run_lwt
      (let open Lwt.Syntax in
       let (module C : Conf.S) =
         let conf = load_conf ?domain () in
         match source with Some name -> reading_from name conf | None -> conf
       in
       let module J = Journal.Make (C) in
       let module W = Wal.Make (C) in
       let module Fs = File_store.Make (C) in
       let module St = Store.Make (C) (Layout.Inode.Make (C)) in
       let module Sq = Sync_queue.Make (C) in
       let module F = File.Make (C) (Sq) in
       let module Rp = Replay.Make (C) (F) in
       Sq.start
         ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
         ~on_cursor:(fun ~entry_key:_ -> ())
         ~on_upload_done:(fun ~key:_ -> Lwt.return_unit);
       let my_uuid = J.client_uuid () in
       if !verbose then
         Log.info "syncing domain %s (client %s, uuid %s)" C.domain_name
           C.client_name my_uuid;
       (* Walks the inode tree from the root, a folder marker giving a
          subfolder's name+id plus the namespace to recurse into.

          One [pool] is shared across the whole recursion, a per-namespace bound
          multiplying with depth until it exhausts DNS / descriptors; a slot
          covers only a fetch and its local write, so a deep tree cannot
          deadlock. *)
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
                                 | man ->
                                     incr count;
                                     (* Read by backend key, which is hashed:
                                        the body is what names it. *)
                                     let leaf = Manifest.recorded_name man in
                                     if !verbose then
                                       Log.info "manifest %s" (join rel leaf);
                                     let+ () =
                                       F.write_manifest
                                         (C.domain_prefix ^ join rel leaf)
                                         man
                                     in
                                     None
                                 | exception parse_exn ->
                                     (* Counted, so a store whose manifests all
                                        fail to parse cannot resync
                                        "successfully" writing nothing. *)
                                     incr failed;
                                     Log.warn
                                       "resync %s: unreadable manifest: %s"
                                       e.key
                                       (match parse_exn with
                                         | Chunk_table.Malformed m -> m
                                         | ex -> Printexc.to_string ex);
                                     Lwt.return_none))
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
         (* Notify the daemon only once the rebuild is complete, or it re-reads
            an empty mirror mid-rebuild. Unsynced edits are kept: nothing else
            holds those bytes. *)
         let* () =
           Cache_layout.clear ~cache_root:C.cache_root
             ~domain_name:C.domain_name
         in
         let* n, failed = rebuild_mirror () in
         Fs.write_last_sync_key (J.entry_key ());
         (try
            if !verbose then Log.info "notifying daemon of completed resync";
            ignore
              (ipc_action ~socket_path:C.socket_path ~domain:C.domain_name
                 "full_resync")
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
       (* One pass of the same engine the daemon polls with, so the two cannot
          drift apart. *)
       let incremental () =
         (* A one-shot command: no mount of ours is running to refresh. *)
         let+ n = Rp.apply_foreign ~on_changed:(fun _ -> ()) () in
         (match Fs.read_last_sync_key () with
           | Some k when !verbose ->
               Log.info "applied through %s" (Journal.Entry_key.to_string k)
           | _ -> ());
         Printf.printf "%d journal entr%s from other clients\n" n
           (if n = 1 then "y" else "ies")
       in
       let* () = Rp.reconcile () in
       if !verbose then Log.info "draining upload queue";
       let* () = Sq.drain () in
       let last_sync_key = Fs.read_last_sync_key () in
       if !verbose then
         Log.info "last sync bookmark: %s"
           (match last_sync_key with
             | None -> "none (first run)"
             | Some k -> Journal.Entry_key.to_string k);
       let* all_keys = Fs.list_journal_keys () in
       if !verbose then
         Log.info "journal: %d entr%s" (List.length all_keys)
           (if List.length all_keys = 1 then "y" else "ies");
       let resync_reason =
         match last_sync_key with
           | _ when full -> Some "--full flag"
           | None -> Some "no bookmark (first run)"
           | Some last ->
               if Journal.Entry_key.cannot_bridge last all_keys then
                 Some "bookmark older than oldest journal entry"
               else None
       in
       match resync_reason with
         | Some reason -> full_resync reason
         | None -> incremental ())
  in
  Cmd.v
    (Cmd.info "sync"
       ~doc:
         "Sync local cache with remote changes. Replays pending local journal \
          entries, then applies new journal entries from other clients. A full \
          resync (triggered by --full or when the local bookmark is stale) \
          clears the cache and re-downloads all manifests. Pass --verbose to \
          see a step-by-step breakdown.")
    Term.(
      const run $ domain_arg $ source_arg $ full_arg $ parallelism_arg
      $ verbose_arg)

let recheck_cmd =
  let run domain =
    let code =
      run_lwt
        (let open Lwt.Syntax in
         let (module C : Conf.S) = load_conf ?domain () in
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
               (* Bodies are content-addressed: one that no longer hashes to its
                  own name is corrupt, and is dropped to be re-fetched. *)
               let+ checked, dropped = Rc.verify_chunk_cache () in
               Printf.printf "%d chunk%s verified, %d dropped as corrupt\n"
                 checked
                 (if checked = 1 then "" else "s")
                 dropped;
               if s.Recheck.unrepairable > 0 then 1 else 0)
    in
    if code <> 0 then exit code
  in
  Cmd.v
    (Cmd.info "recheck"
       ~doc:
         "Verify all remote chunks and manifests against the local cache, \
          repairing what can be repaired")
    Term.(const run $ domain_arg)

let resync_remote_cmd =
  let source_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["source"] ~docv:"NAME"
          ~doc:
            "Backend to copy from, by its configured name. Default: the \
             primary backend.")
  in
  let manifests_arg =
    Arg.(
      value & flag
      & info ["manifests"]
          ~doc:
            "Copy only the manifests namespace (skip chunks, journal, \
             versions, cursor) — a cheap way to complete a backend's structure \
             without hauling chunk data.")
  in
  let run domain source manifests_only v =
    set_verbose v;
    let code =
      run_lwt
        (let open Lwt.Syntax in
         let (module C : Conf.S) = load_conf ?domain () in
         (* Mirror copies between the stores themselves, so it reads
            [C.members] rather than going through the composite. *)
         let src =
           Option.value source
             ~default:
               (match C.members with m :: _ -> m.Backend.name | [] -> "")
         in
         if List.length C.members < 2 then begin
           Printf.eprintf
             "resync-remote requires at least two configured backends (domain \
              %s has %d)\n"
             C.domain_name (List.length C.members);
           Lwt.return 1
         end
         else begin
           vprintf "initiating remote sync: copying %s from %s..."
             (if manifests_only then "manifests" else "all objects")
             src;
           let module M = Mirror.Make (C) in
           let on_list ~name = vprintf "  fetching %s listing..." name in
           let on_scan ~objects =
             vprintf "scanned %s: %d object%s to check" src objects
               (if objects = 1 then "" else "s")
           in
           let on_copy ~name ~key ~bytes =
             vprintf "  copied %s (%d bytes) -> %s" key bytes name
           in
           let+ dests =
             M.resync ~source:src ~manifests_only ~on_scan ~on_list ~on_copy ()
           in
           List.iter
             (fun (dst : Mirror.dest_stats) ->
               (* Under -v they are already logged live. *)
               if not !verbose then
                 List.iter (Printf.printf "copied %s\n") dst.Mirror.copied;
               Printf.printf
                 "%s -> %s: %d object%s checked, %d copied (%d bytes)\n" src
                 dst.Mirror.name dst.Mirror.checked
                 (if dst.Mirror.checked = 1 then "" else "s")
                 (List.length dst.Mirror.copied)
                 dst.Mirror.copied_bytes)
             dests;
           0
         end)
    in
    if code <> 0 then exit code
  in
  Cmd.v
    (Cmd.info "resync-remote"
       ~doc:
         "Sync one remote backend from another: copy every object of the \
          domain (manifests, chunks, journal, versions) that is missing or \
          size-mismatched on the other configured backends. Pass --manifests \
          to copy only the manifests.")
    Term.(const run $ domain_arg $ source_arg $ manifests_arg $ verbose_arg)

let import_cmd =
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
    set_verbose v;
    run_lwt
      (let open Lwt.Syntax in
       let (module C : Conf.S) = load_conf ?domain () in
       let module I = Import.Make (C) in
       vprintf "importing from %s into domain %s" src C.domain_name;
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

let export_cmd =
  let dst_arg =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"DIR" ~doc:"Destination folder (created if needed)")
  in
  let run domain dst v =
    set_verbose v;
    let code =
      run_lwt
        (let open Lwt.Syntax in
         let (module C : Conf.S) = load_conf ?domain () in
         let module E = Export.Make (C) in
         vprintf "exporting domain %s to %s" C.domain_name dst;
         let+ summary =
           E.run ~dst
             ~on_file:(fun ~rel status ->
               match status with
                 | Export.Exported -> Printf.printf "exported %s\n%!" rel
                 | Export.Exported_symlink ->
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

(* "<N>d" / "<N>h" -> seconds *)
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
    let cfg = load_config () in
    let domain =
      match domain with Some _ -> domain | None -> read_default_domain ()
    in
    let ttl = parse_duration expires in
    let (module C : Conf.S) = make_conf ?domain cfg in
    let expires = int_of_float (Unix.time () +. ttl) in
    (* Resolve PATH to a domain-relative path; accept an absolute path under the
       mount point too. Empty rel means the whole domain. *)
    let mount_point = mount_point_of (Conf_parsing.pick_domain ?domain cfg) in
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
    let module S = Share.Make (C) in
    match run_lwt (S.create ?token ~expires ~rel ()) with
      | Error msg ->
          Printf.eprintf "%s\n" msg;
          exit 1
      | Ok url ->
          let tm = Unix.localtime (float_of_int expires) in
          Printf.eprintf "Expires %04d-%02d-%02d %02d:%02d\n"
            (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
            tm.Unix.tm_hour tm.Unix.tm_min;
          print_endline url
  in
  Cmd.v
    (Cmd.info "share" ~doc:"Print a shareable download URL for a file or folder")
    Term.(const run $ path_arg $ expires_arg $ domain_arg $ token_arg)

let print_conf_cmd =
  let mask (b : Conf_parsing.backend_config) k v =
    match Backend.spec_for b.backend_type with
      | None -> v
      | Some specs -> (
          match List.find_opt (fun (s : Field_spec.t) -> s.name = k) specs with
            | Some { secret = true; _ } when v <> "" -> "***"
            | _ -> v)
  in
  let mask_frontend ftype k v =
    match
      List.find_opt
        (fun (s : Field_spec.t) -> s.name = k)
        (Frontend.spec_for ftype)
    with
      | Some { secret = true; _ } when v <> "" -> "***"
      | _ -> v
  in
  let symlink_str = function
    | `Keep -> "keep"
    | `Follow -> "follow"
    | `Skip -> "skip"
  in
  let run () =
    let cfg = load_config () in
    let default = read_default_domain () in
    Printf.printf "name:            %s\n" cfg.Conf_parsing.name;
    Printf.printf "maxUploads:      %d\n" cfg.Conf_parsing.max_uploads;
    Printf.printf "maxChunkBuffers: %d\n" cfg.Conf_parsing.max_chunk_buffers;
    Printf.printf "maxDownloads:    %d\n" cfg.Conf_parsing.max_downloads;
    (match cfg.Conf_parsing.tls with
      | Some t -> Printf.printf "tls:             %s\n" t
      | None -> ());
    List.iter
      (fun (d : Conf_parsing.domain) ->
        Printf.printf "\ndomain: %s%s\n" d.name
          (if default = Some d.name then " [default]" else "");
        Printf.printf "  versioning: %b\n" d.versioning;
        Printf.printf "  read_only:  %b\n" d.read_only;
        Printf.printf "  symlinks:   %s\n" (symlink_str d.symlink_policy);
        let show_size label = function
          | Some n ->
              Printf.printf "  %-11s %s\n" (label ^ ":") (Metrics.human_bytes n)
          | None -> ()
        in
        show_size "chunkSize" d.chunk_size;
        show_size "cacheChunk" d.cache_chunk_size;
        Printf.printf "  maxCache:   %s\n"
          (match d.max_cache with
            | Some n -> Metrics.human_bytes n
            | None -> "none");
        List.iter
          (fun (f : Conf_parsing.frontend_config) ->
            Printf.printf "  frontend: %s\n" f.frontend_type;
            List.iter
              (fun (k, v) ->
                Printf.printf "    %-22s %s\n" (k ^ ":")
                  (mask_frontend f.frontend_type k v))
              f.options)
          d.frontends;
        List.iter
          (fun (b : Conf_parsing.backend_config) ->
            Printf.printf "  backend: %s (%s) [%s]\n" b.name b.backend_type
              (Conf_parsing.role_name b.role);
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

let paths_cmd =
  let run () =
    let p = runtime_paths in
    Printf.printf "config:  %s\n" p.Runtime.config_path;
    Printf.printf "cache:   %s\n" p.Runtime.cache_root;
    Printf.printf "data:    %s\n" p.Runtime.data_dir;
    Printf.printf "socket:  %s\n" p.Runtime.socket_path
  in
  Cmd.v
    (Cmd.info "paths" ~doc:"Show all filesystem paths used by this binary")
    Term.(const run $ const ())

let restart_cmd =
  let run () =
    if Runtime.restart_service () then print_endline "Restarted."
    else begin
      prerr_endline "Could not restart: the tsync service is not installed.";
      exit 1
    end
  in
  Cmd.v
    (Cmd.info "restart"
       ~doc:"Restart the background service so it re-reads the config")
    Term.(const run $ const ())

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
      let cfg = load_config () in
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
            Fs_util.mkdir_p_sync (Filename.dirname file);
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

let build_config_cmd =
  let run () =
    Printf.printf "frontends: %s\ns3 backend: %b\nlog: %s\n"
      (String.concat ", " (Frontend.names ()))
      S3_link.s3_backend_enabled Log.Daemon.implementation
  in
  Cmd.v
    (Cmd.info "build-config"
       ~doc:"Show optional features compiled into this binary")
    Term.(const run $ const ())

(* Each registered frontend surfaces its commands as `tsync <cli_group> <verb>`,
   the binary owning [--domain] parsing and checking the frontend is configured
   for that domain before handing over. Groups exist only for frontends linked
   into this binary, so `fileprovider` appears on macOS but not Linux. *)
let frontend_cmds () =
  let run name (command : Frontend.command) domain =
    let cfg = load_config () in
    let domain =
      match domain with Some _ -> domain | None -> read_default_domain ()
    in
    let d = Conf_parsing.pick_domain ?domain cfg in
    if not (List.mem name (frontend_names d)) then (
      Printf.eprintf "domain %s has no %s frontend\n" d.Conf_parsing.name name;
      exit 1);
    let (module C : Conf.S) = make_conf ?domain cfg in
    command.Frontend.run (module C)
  in
  List.filter_map
    (fun (name, cli_group, commands) ->
      match commands with
        | [] -> None
        | _ ->
            let subs =
              List.map
                (fun (command : Frontend.command) ->
                  Cmd.v
                    (Cmd.info command.Frontend.verb ~doc:command.Frontend.doc)
                    Term.(const (run name command) $ domain_arg))
                commands
            in
            Some
              (Cmd.group
                 (Cmd.info cli_group
                    ~doc:(Printf.sprintf "%s frontend commands" cli_group))
                 subs))
    (Frontend.entries ())

let () =
  Printexc.record_backtrace true;
  let cmd =
    Cmd.group
      (Cmd.info "tsync" ~doc:"Cloud-backed filesystem sync")
      ([
         build_config_cmd;
         Configure.cmd;
         print_conf_cmd;
         paths_cmd;
         restart_cmd;
         set_domain_cmd;
         default_domain_cmd;
         start_cmd;
         stop_cmd;
         status_cmd;
         logs_cmd;
         pause_uploads_cmd;
         resume_uploads_cmd;
         stats_cmd;
         sync_cmd;
         recheck_cmd;
         resync_remote_cmd;
         import_cmd;
         export_cmd;
         evict_cmd;
         restore_cmd;
         ls_cmd;
         share_cmd;
         versions_cmd;
         revert_cmd;
         trash_cmd;
         untrash_cmd;
         purge_cmd;
         expire_cmd;
         gc_cmd;
       ]
      @ frontend_cmds ())
  in
  (* Every [failwith] under [Conf_parsing] is phrased for a user: print it, not
     a stack trace. *)
    match Cmd.eval ~catch:false cmd with
    | code -> exit code
    | exception Failure msg ->
        prerr_endline ("tsync: " ^ msg);
        exit 1
    | exception exn ->
        (* Matches what cmdliner's own catch prints. *)
        Printf.eprintf "tsync: internal error, uncaught exception:\n%s\n"
          (Printexc.to_string exn);
        prerr_string (Printexc.get_backtrace ());
        exit Cmd.Exit.internal_error
