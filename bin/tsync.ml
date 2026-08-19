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
        "No config at %s. Run `tsync config --edit`, then `tsync restart`.\n"
        runtime_paths.Runtime.config_path;
      exit 0
    end;
    let cfg = load_config () in
    (* CLI --tls wins over the config value applied by make_conf, which is also
       what reports the choice: doing it here would name conduit's default,
       the config not having been read yet. *)
    if tls <> None then Tls_conf.apply tls;
    let domains =
      if cfg.Conf_parsing.domains = [] then begin
        Printf.eprintf
          "No domains configured in %s. Run `tsync config --edit`.\n"
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
      (* Here rather than at startup: this runs once per frontend process, after
         the fork. *)
      trace_process ~name;
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
    with e ->
      Printf.eprintf "Error: %s\n" (Printexc.to_string e);
      exit 1
  in
  Cmd.v (Cmd.info verb ~doc) Term.(const run $ domain_arg)

let pause_uploads_cmd =
  pause_cmd ~verb:"pause-uploads" ~arg:"on" ~done_:"paused"
    ~doc:"Pause uploads (queued work is kept)"

let resume_uploads_cmd =
  pause_cmd ~verb:"resume-uploads" ~arg:"off" ~done_:"resumed"
    ~doc:"Resume paused uploads"

let human_bytes = Metrics.human_bytes

let status_cmd =
  let watch_arg =
    Arg.(
      value
      & opt (some float) None
      & info ["w"; "watch"] ~docv:"SECONDS"
          ~doc:"Poll and redraw every $(docv) seconds")
  in
  let json_arg =
    Arg.(
      value & flag
      & info ["json"]
          ~doc:"Output raw JSON, one object per answering daemon per line")
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
  let run json totals exact reload watch =
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
    let targets = domain_targets () in
    (* A domain that is down must not cost the others their report, so a failure
       here is a line on stderr and one report fewer. *)
    let ask (name, socket_path) =
      match ipc_action ~socket_path ~domain:name ?arg "stats" with
        | obj -> Some (socket_path, `Assoc obj)
        | exception Failure msg ->
            Printf.eprintf "Error: %s: %s\n" name msg;
            None
        | exception _ ->
            Printf.eprintf "%s: no daemon answering on %s\n" name socket_path;
            None
    in
    (* One report per answering process, not per domain: a daemon serving
       several answers once per domain, and its pid, cpu and traffic are one set
       of figures. The socket is that identity — Linux gives each domain its
       own, macOS shares one. *)
    let group answers =
      let sockets =
        List.fold_left
          (fun acc (s, _) -> if List.mem s acc then acc else acc @ [s])
          [] answers
      in
      List.map
        (fun s ->
          Diagnostics.merge
            (List.filter_map
               (fun (s', obj) -> if s' = s then Some obj else None)
               answers))
        sockets
    in
    let show () =
      List.iteri
        (fun i report ->
          if json then begin
            let obj = match report with `Assoc obj -> obj | _ -> [] in
            print_endline
              (Yojson.Safe.to_string
                 (`Assoc (("t", `Float (Unix.gettimeofday ())) :: obj)))
          end
          else begin
            if i > 0 then print_newline ();
            print_string (Diagnostics.text report)
          end)
        (group (List.filter_map ask targets))
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
    (Cmd.info "status"
       ~doc:
         "Report on the running daemons: transfer metrics, config as resolved, \
          cache, journal backlog and each backend's health. Covers every \
          configured domain.")
    Term.(
      const run $ json_arg $ totals_arg $ exact_arg $ reload_arg $ watch_arg)

(* Residency, both directions. Evicting and fetching are the same operation
   over the same paths with the wire verb swapped, and naming them apart put
   [restore] beside [revert], which recovers a lost thing --
   this one only moves bytes on and off this machine. *)
let cache_cmd =
  let path_arg = Arg.(non_empty & pos_all string [] & info [] ~docv:"PATH") in
  let evict_arg =
    Arg.(
      value & flag
      & info ["evict"] ~doc:"Drop these files or directories from the cache.")
  in
  let fetch_arg =
    Arg.(
      value & flag
      & info ["fetch"]
          ~doc:"Download these files or directories into the cache.")
  in
  let act ~verb ~done_ ~domain paths =
    let socket_path path =
      match domain with
        | Some _ -> domain_socket ?domain ()
        | None -> domain_socket_for_path path
    in
    List.iter
      (fun path ->
        match ipc_action ~socket_path:(socket_path path) ~path verb with
          | _ -> Printf.printf "%s: %s\n" done_ path
          | exception Failure msg -> Printf.eprintf "Error: %s\n" msg)
      paths
  in
  let run paths domain evict fetch =
    match (evict, fetch) with
      | true, false -> act ~verb:"evict" ~done_:"Evicted" ~domain paths
      | false, true -> act ~verb:"restore" ~done_:"Fetched" ~domain paths
      | true, true ->
          failwith "--evict and --fetch do opposite things; run one."
      | false, false -> failwith "cache needs --evict or --fetch."
  in
  Cmd.v
    (Cmd.info "cache"
       ~doc:
         "Move files on and off this machine: $(b,--evict) drops them from the \
          cache, $(b,--fetch) downloads them into it.")
    Term.(const run $ path_arg $ domain_arg $ evict_arg $ fetch_arg)

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
                   match Manifest.of_string (Chunk.to_string data) with
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
  let revert_arg =
    Arg.(
      value & flag
      & info ["revert"]
          ~doc:
            "Restore a previous version of $(i,PATH) instead of listing them. \
             Metadata only, nothing is downloaded.")
  in
  let version_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["version"] ~docv:"TS"
          ~doc:
            "With $(b,--revert): the version timestamp to restore (default: \
             most recent).")
  in
  (* The path names its own domain by sitting under that domain's mount, so
     [--domain] is only consulted when it was given. *)
  let revert path version domain =
    let socket_path =
      match domain with
        | Some _ -> domain_socket ?domain ()
        | None -> domain_socket_for_path path
    in
    match ipc_action ~socket_path ~path ?arg:version "revert" with
      | _ -> Printf.printf "Reverted: %s\n" path
      | exception Failure msg -> Printf.eprintf "Error: %s\n" msg
  in
  let list path domain =
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
                   let data = Chunk.to_string data in
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
  let run path domain do_revert version =
    match (path, do_revert) with
      | Some path, true -> revert path version domain
      | _, false -> list path domain
      | None, true -> failwith "--revert needs the PATH to restore."
  in
  Cmd.v
    (Cmd.info "versions"
       ~doc:
         "List a file's versions, or all deleted files when no PATH is given. \
          With $(b,--revert), restore one instead.")
    Term.(const run $ path_arg $ domain_arg $ revert_arg $ version_arg)

(* An empty trash lists as its own directory key, which holds no marker and
   cannot be fetched on a filesystem store. Dropped here rather than in each
   reader: every one of them goes on to [get] what this returns. *)
let trash_markers (module B : Backend.S) domain_prefix =
  let open Lwt.Syntax in
  let+ entries =
    B.list_prefix ~prefix:(domain_prefix ^ Folder.trash_id ^ "/") ()
  in
  List.filter
    (fun (e : Backend.file_entry) -> not (Key.is_dir e.Backend.key))
    entries

let trash_list domain =
  run_lwt
    (let open Lwt.Syntax in
     let (module C : Conf.S) = load_conf ?domain () in
     let module B = (val C.store : Backend.S) in
     let* markers = trash_markers (module B) C.domain_prefix in
     Lwt_list.iter_s
       (fun (e : Backend.file_entry) ->
         let+ data = B.get ~key:e.key () in
         let data = Chunk.to_string data in
         match Folder.trash_path_of_string data with
           | Some p -> Printf.printf "%s\n" p
           | None -> ())
       markers)

let trash_restore path domain =
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
           let data = Chunk.to_string data in
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

let trash_cmd =
  let path_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let restore_arg =
    Arg.(
      value & flag
      & info ["restore"]
          ~doc:
            "Put $(i,PATH) back where it was. The subtree is untouched, so \
             this is O(1); run $(b,tsync sync) to rebuild it locally.")
  in
  let purge_arg =
    Arg.(
      value & flag
      & info ["purge"] ~doc:"Delete every version of $(i,PATH) from the trash.")
  in
  let purge path domain =
    let code =
      run_lwt
        (let open Lwt.Syntax in
         let (module C : Conf.S) = load_conf ?domain () in
         let module E = Expire.Make (C) in
         let+ outcome = E.purge_trashed ~path () in
         match outcome with
           | `Not_in_trash ->
               Printf.eprintf "not in trash: %s\n" path;
               1
           | `Purged n ->
               Printf.printf
                 "purged %s (%d object%s) — run tsync gc to reclaim\n" path n
                 (if n = 1 then "" else "s");
               0)
    in
    (* Outside {!run_lwt}: exiting from inside its promise would skip the
       deferred drain it exists for. *)
    if code <> 0 then exit code
  in
  let run path domain restore do_purge =
    match (path, restore, do_purge) with
      | None, false, false -> trash_list domain
      | Some path, true, false -> trash_restore path domain
      | Some path, false, true -> purge path domain
      | None, _, _ -> failwith "--restore and --purge each need a PATH."
      | Some _, true, true ->
          failwith "--restore and --purge do opposite things; run one."
      | Some _, false, false ->
          failwith
            "naming a path needs --restore or --purge; trash alone lists."
  in
  Cmd.v
    (Cmd.info "trash"
       ~doc:
         "List trashed folders, or act on one: $(b,--restore) puts it back, \
          $(b,--purge) deletes its versions for good.")
    Term.(const run $ path_arg $ domain_arg $ restore_arg $ purge_arg)

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
    (* Carriage-return progress belongs on a terminal, where one line rewrites
       itself; down a pipe it is padding in front of the summary. *)
    let watching = Unix.isatty Unix.stderr in
    let s =
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
             if watching then Printf.eprintf "  %s: %d deleted\r%!" name deleted)
           ~cutoff ())
    in
    (* The last progress line is still sitting on the terminal's current line,
       and the summary below would land on top of it. *)
    if watching then Printf.eprintf "\r%*s\r%!" 72 "";
    (* [Failure] is left to the top level, which prints it as a sentence and
       exits nonzero: a run that could not reach a backend must not tell a
       script it expired anything. *)
    Printf.printf "Removed %d version(s), %d journal entr(ies)\n"
      s.Expire.versions_deleted s.journal_deleted
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
  let delete_batch_arg =
    Arg.(
      value
      & opt (some int) None
      & info ["delete-batch"] ~docv:"N"
          ~doc:
            "Chunks per delete request against a replica or backfill target \
             (default: 1000, which is what S3 and GCS both cap a bulk delete \
             at). Raise it for a store that takes more, lower it for one that \
             chokes.")
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
  let retry_arg =
    Arg.(
      value & flag
      & info ["retry-jobs"]
          ~doc:
            "Deliver outstanding delete requests again. A request is handed to \
             a copy's bucket once, by the notification its own write fires; a \
             function that was absent or broken then does not pick one up by \
             being fixed. Safe to repeat.")
  in
  let status_arg =
    Arg.(
      value & flag
      & info ["status"] ~doc:"Report an open collection without continuing it.")
  in
  let verify_arg =
    Arg.(
      value & flag
      & info ["verify"]
          ~doc:
            "Also hold each live chunk against its own name as it is kept, and \
             record what fails for $(b,tsync data-integrity --repair). Reads \
             every live byte, where a collection otherwise touches only \
             metadata — minutes become hours on a large store. A chunk that \
             fails is kept and marked, never discarded.")
  in
  let verified_line (s : Gc.stats) =
    if s.Gc.chunks_verified = 0 && s.Gc.chunks_unreadable = 0 then ""
    else
      Printf.sprintf
        "\n\
         %d chunk(s) checked: %d corrupt, %d unreadable, %d marker(s) \
         cleared.%s"
        s.Gc.chunks_verified s.Gc.chunks_corrupt s.Gc.chunks_unreadable
        s.Gc.chunks_cleared
        (if s.Gc.chunks_corrupt + s.Gc.chunks_unreadable > 0 then
           " Run tsync data-integrity --repair."
         else "")
  in
  (* [was_open] is read before the abandonment rather than inferred from its
     counts: what it moves back is what marking had not reached yet, so a run
     abandoned after a finished mark moves nothing and a count of zero says
     nothing about whether there was a run at all. *)
  let report ~abort ~was_open ~domain (s : Gc.stats) =
    match s.Gc.outcome with
      | Gc.Completed when abort && not was_open ->
          Printf.printf "No collection was open for %s; nothing to abandon.\n"
            domain
      | Gc.Completed when abort ->
          (* Moved back, not kept: everything marking had already moved across is
             kept too, and was never at risk. *)
          Printf.printf
            "Collection abandoned; %d chunk(s) moved back, none discarded.\n"
            s.chunks_promoted
      | Gc.Completed ->
          Printf.printf "Reclaimed %d chunk(s), %s. Kept %d.%s\n"
            s.chunks_reclaimed
            (human_bytes s.bytes_reclaimed)
            s.chunks_promoted (verified_line s)
      (* Each phase fills in different fields, so one fixed set of them would
         print zeroes that read as "nothing happened" rather than as "this phase
         does not count that".

         The continue line names the command that continues *this*: a plain
         [tsync gc] over an abandoned collection would go back to collecting it. *)
      | Gc.Suspended { phase; _ } when abort ->
          Printf.printf
            "Stopped while %s: %d chunk(s) moved back so far.\n\
             Still open; rerun tsync gc --abort to continue.\n"
            phase s.chunks_promoted
      | Gc.Suspended { phase; _ } ->
          Printf.printf
            "Stopped while %s: %d file(s) marked, %d chunk(s) kept, %d \
             reclaimed.%s\n\
             Still open; rerun tsync gc to continue.\n"
            phase s.roots_marked s.chunks_promoted s.chunks_reclaimed
            (verified_line s)
  in
  let run budget pause concurrency delete_batch abort status retry verify
      verbose domain =
    set_verbose verbose;
    (* Reported as [Failure], which the top level prints as "tsync: <sentence>"
       and exits nonzero on. Both carry prose written for whoever typed this. *)
    let translate f =
      try f () with
        | Gc.Unsupported msg | Gc.Busy msg -> failwith msg
        | Failure msg -> failwith msg
    in
    let (module C : Conf.S) = load_conf ?domain () in
    let module G = Gc.Make (C) in
    if retry then (
      (* Re-delivery, not a fresh decision: what each request names is in the
         request, the space those keys came from having been discarded. *)
      let sent = run_lwt (G.retry_outstanding ()) in
      let total = List.fold_left (fun n (_, c) -> n + c) 0 sent in
      if total = 0 then
        Printf.printf "No delete request is outstanding for %s.\n" C.domain_name
      else
        List.iter
          (fun (name, n) ->
            if n > 0 then
              Printf.printf
                "%s: %d delete request(s) sent again. Watch tsync gc --status: \
                 they clear as the function consumes them.\n"
                name n)
          sent)
    else if status then (
      (match run_lwt (G.status ()) with
        | None -> Printf.printf "No collection is open for %s.\n" C.domain_name
        | Some r ->
            Printf.printf "Collection of %s open: %s, %.0fs so far.\n"
              C.domain_name
              (Chunk_space.string_of_phase r.Chunk_space.phase)
              (Unix.gettimeofday () -. r.Chunk_space.started));
      (* Printed whether or not one is open: a request outlives the collection
         that queued it, and a copy sitting on one is the case this exists to
         show. *)
      List.iter
        (fun (name, count, oldest) ->
          Printf.printf
            "  %s: %d delete request(s) outstanding, oldest %s.\n\
            \    Nothing has picked them up — check the bucket's notification \
             and the function's logs.\n"
            name count (G.show_age oldest))
        (run_lwt (G.outstanding ())))
    else (
      (* Abandoning is the same machinery with everything treated as live, so it
         takes the same pacing and reports the same way — whoever reaches for
         --abort is getting out of a collection that is already going badly.

         Progress to stderr, so stdout carries only the summary a script would
         read. *)
      let budget = Option.map parse_duration budget
      and pause = Option.map parse_duration pause in
      (* Carriage-return progress belongs on a terminal, where one line rewrites
         itself; down a pipe it is padding in front of the summary. The same
         text goes to the log there instead, which is what [-v] reaches -- a
         collection run under screen and teed to a file is the case that wants
         it, and the one where stderr is not a terminal. *)
      let watching = Unix.isatty Unix.stderr in
      (* Spelled as {!Chunk_space.string_of_phase} does, so a phase named here
         and one read off an open run are the same word. *)
      let phase = ref (Chunk_space.string_of_phase Chunk_space.Opening) in
      let at_ = ref "" in
      let marked = ref [] and closed = ref [] in
      let emit ending line =
        if watching then Printf.eprintf "%s%s%!" line ending
        else vprintf "%s" line
      in
      let header fmt = Printf.ksprintf (emit "\n") fmt in
      let progress fmt = Printf.ksprintf (emit "\r") fmt in
      let on_open () =
        phase := Chunk_space.string_of_phase Chunk_space.Opening;
        header "%s %s..."
          (if abort then "Abandoning the collection of" else "Collecting")
          C.domain_name
      in
      (* Abandoning walks shards and has no notion of a file; marking walks
         folders and counts the files in them, so the two get different lines
         rather than one with a field that means nothing in half the runs. *)
      let on_mark ~namespaces ~total ~roots ~promoted ~at =
        phase :=
          Chunk_space.string_of_phase
            (if abort then Chunk_space.Abandoning else Chunk_space.Marking);
        at_ := at;
        marked :=
          if abort then
            [("shards", namespaces); ("planned", total); ("kept", promoted)]
          else
            [
              ("folders", namespaces);
              ("planned", total);
              ("files", roots);
              ("kept", promoted);
            ];
        if abort then
          progress "  kept %d/%d shard(s), %d chunk(s)" namespaces total
            promoted
        else
          progress "  marked %d/%d folder(s), %d file(s), %d chunk(s) kept"
            namespaces total roots promoted
      in
      (* Added to rather than replacing what marking counted: a job whose set of
         counters changes halfway through reads as one that lost them. *)
      let on_close ~shards ~reclaimed ~at =
        phase := Chunk_space.string_of_phase Chunk_space.Closing;
        at_ := at;
        closed := [("closed", shards); ("reclaimed", reclaimed)];
        progress "  closed %d shard(s), %d chunk(s) reclaimed" shards reclaimed
      in
      translate (fun () ->
          let was_open = abort && run_lwt (G.status ()) <> None in
          let s =
            run_lwt
              ~report:(fun () ->
                report_job ?domain
                  (module C)
                  ~kind:(if abort then "gc --abort" else "gc")
                  ~current:(fun () ->
                    Some (if !at_ = "" then !phase else doing !phase !at_))
                  ~counters:(fun () -> !marked @ !closed)
                  ())
              (if abort then
                 G.abort ?budget ?pause ?concurrency ~on_open ~on_mark ~on_close
                   ()
               else
                 G.run ?budget ?pause ?concurrency ?delete_batch ~verify
                   ~on_open ~on_mark ~on_close ())
          in
          (* The progress lines above end in a carriage return, so the last one is
             still sitting on the terminal's current line. Cleared before the
             summary goes to stdout, or the two land on top of each other. *)
          if watching then Printf.eprintf "\r%*s\r%!" 72 "";
          report ~abort ~was_open ~domain:C.domain_name s))
  in
  Cmd.v
    (Cmd.info "gc"
       ~doc:
         "Reclaim chunks nothing references any more (run tsync expire first). \
          Local main stores only. Deletes the same chunks off the replicas and \
          backfill targets; filling a copy that has fallen behind is tsync \
          mirror's job, not this one's.")
    Term.(
      const run $ budget_arg $ pause_arg $ concurrency_arg $ delete_batch_arg
      $ abort_arg $ status_arg $ retry_arg $ verify_arg $ verbose_arg
      $ domain_arg)

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
    let (module C : Conf.S) =
      let conf = load_conf ?domain () in
      match source with Some name -> reading_from name conf | None -> conf
    in
    let phase = ref "starting" and current = ref None in
    let manifests = ref 0 and failures = ref 0 in
    (* An incremental pass counts no manifests, and a fixed set of counters
       would print zeroes reading as "nothing happened" rather than as "this
       pass does not count that". *)
    let rebuilding = ref false in
    let code =
      run_lwt
        ~report:(fun () ->
          report_job ?domain
            (module C)
            ~kind:(if full then "sync --full" else "sync")
            ~current:(fun () ->
              match !current with
                | Some at -> Some (doing !phase at)
                | None -> Some !phase)
              (* No total for a resync: the inode tree is discovered as it is
               walked, so a denominator here would be one this cannot know. *)
            ~counters:(fun () ->
              if !rebuilding then
                [("manifests", !manifests); ("failed", !failures)]
              else [])
            ())
        (let open Lwt.Syntax in
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
           let count = manifests and failed = failures in
           (* Entries of one folder, bounded; the descent below is sequential.
            Recursing inside the fan-out instead would keep every level live at
            once, so the peak is the whole tree rather than one directory — and
            a second bound here would deadlock against this one. *)
           let entry_slots = Lwt_bounded.create ~max:(max 1 parallelism) () in
           let rec walk folder_id rel =
             current := Some (if rel = "" then "/" else rel);
             let* entries = use (fun () -> St.list_namespace ~folder_id) in
             let* children =
               Lwt_bounded.filter_map_with entry_slots
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
                                         let leaf =
                                           Manifest.recorded_name man
                                         in
                                         if !verbose then
                                           Log.info "manifest %s"
                                             (join rel leaf);
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
                       Lwt.return next)
                     (fun exn ->
                       incr failed;
                       Log.warn "resync %s: %s" e.key (Printexc.to_string exn);
                       Lwt.return_none))
                 entries
             in
             Lwt_list.iter_s (fun (id, child) -> walk id child) children
           in
           let+ () = walk Folder.root_id "" in
           (!count, !failed)
         in
         let full_resync reason =
           rebuilding := true;
           phase := "clearing the cache";
           if !verbose then Log.info "full resync: %s" reason;
           (* Notify the daemon only once the rebuild is complete, or it re-reads
            an empty mirror mid-rebuild. Unsynced edits are kept: nothing else
            holds those bytes. *)
           let* () =
             Cache_layout.clear ~cache_root:C.cache_root
               ~domain_name:C.domain_name
           in
           phase := "rebuilding";
           let* n, failed = rebuild_mirror () in
           current := None;
           phase := "notifying the daemon";
           (* Only a rebuild that reached everything may say so. Recording the
            mark after a partial walk moves the cursor past folders that were
            never fetched, and nothing revisits them: their files arrive later
            as journal puts, into directories no id names. *)
           if failed = 0 then Fs.write_last_sync_key (J.entry_key ());
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
           Lwt.return (if failed > 0 then 1 else 0)
         in
         (* One pass of the same engine the daemon polls with, so the two cannot
          drift apart. *)
         let incremental () =
           phase := "applying other clients' entries";
           (* A one-shot command: no mount of ours is running to refresh. *)
           let+ n = Rp.apply_foreign ~on_changed:(fun _ -> ()) () in
           (match Fs.read_last_sync_key () with
             | Some k when !verbose ->
                 Log.info "applied through %s" (Journal.Entry_key.to_string k)
             | _ -> ());
           Printf.printf "%d journal entr%s from other clients\n" n
             (if n = 1 then "y" else "ies");
           0
         in
         phase := "replaying local records";
         let* () = Rp.reconcile () in
         phase := "draining uploads";
         if !verbose then Log.info "draining upload queue";
         let* () = Sq.drain () in
         phase := "reading the journal";
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
    (* Outside {!run_lwt}: exiting from inside its promise would skip the
       deferred drain it exists for, and a resync that failed part way is
       exactly the run with copies still queued. *)
    if code <> 0 then exit code
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

(* One command for the three things anyone does about a chunk that is not what
   its name says: ask for a check, read what was found, put it right.

   The stores are what it walks, not this machine's manifests: a chunk is
   checkable wherever it sits, and what a client happens to have cached says
   nothing about the copy a store is keeping. *)
let data_integrity_cmd =
  let current = ref None and planned = ref 0 in
  let checked = ref 0 and unrepairable = ref 0 and corrupt = ref 0 in
  (* [--verify] polls every store at once, so what a reader wants is the run's
     totals rather than whichever member answered last. *)
  let per_store : (string, int * int) Hashtbl.t = Hashtbl.create 4 in
  let sum_stores which =
    Hashtbl.fold (fun _ v acc -> acc + which v) per_store 0
  in
  let report (module C : Conf.S) detail =
    let open Lwt.Syntax in
    let module Cor = Corruption.Make (C) in
    let* r = Cor.list () in
    let entries =
      List.sort
        (fun (a : Corruption.entry) b ->
          compare
            (a.Corruption.store, a.Corruption.chunk_key)
            (b.Corruption.store, b.Corruption.chunk_key))
        r.Corruption.entries
    in
    corrupt := List.length entries;
    let* () =
      Lwt_list.iter_s
        (fun (e : Corruption.entry) ->
          if not detail then (
            Printf.printf "CORRUPT %s on %s\n%!" e.Corruption.chunk_key
              e.Corruption.store;
            Lwt.return_unit)
          else
            let+ found = Cor.detail e in
            let extra =
              match found with
                | Some { Corruption_marker.computed = Some c; size; _ } ->
                    Printf.sprintf " (hashed to %s%s)" c
                      (match size with
                        | Some n -> Printf.sprintf ", %d bytes" n
                        | None -> "")
                | Some { Corruption_marker.reason = Some why; _ } ->
                    Printf.sprintf " (%s)" why
                | _ -> ""
            in
            Printf.printf "CORRUPT %s on %s%s\n%!" e.Corruption.chunk_key
              e.Corruption.store extra)
        entries
    in
    List.iter
      (fun (name, why) -> Printf.printf "UNREACHABLE %s (%s)\n%!" name why)
      r.Corruption.unreachable;
    List.iter
      (fun name -> Printf.printf "NOT CHECKED %s — no verifier\n%!" name)
      r.Corruption.unverified;
    let n = List.length entries in
    let silent =
      r.Corruption.unverified @ List.map fst r.Corruption.unreachable
    in
    (* Never a bare "0 corrupt chunks" while some store has said nothing: that
       line is the one a reader takes away, and alone it reads as a clean bill
       of health for the whole domain. *)
    Printf.printf "%d corrupt chunk%s%s\n" n
      (if n = 1 then "" else "s")
      (match silent with
        | [] -> ""
        | names ->
            Printf.sprintf ", and nothing checked %s" (String.concat ", " names));
    Lwt.return (if n > 0 || silent <> [] then 1 else 0)
  in
  (* What the sweep is doing, from outside it. The requests delete themselves as
     each shard finishes, so counting what is left is the progress bar — and
     markers accumulate as they are found, so a run that is turning things up
     says so while it runs rather than at the end.

     Both are plain listings of prefixes the client already reads. Nothing here
     talks to a function. *)
  let follow (module C : Conf.S) (m : Backend.member) =
    let open Lwt.Syntax in
    let (module B : Backend.S) = m.Backend.backend in
    let jobs = Chunk_layout.verify_jobs_prefix ~chunk_prefix:C.chunk_prefix in
    let corrupted =
      Chunk_layout.corrupted_prefix ~chunk_prefix:C.chunk_prefix
    in
    let count prefix =
      Lwt.catch
        (fun () ->
          let+ es = B.list_prefix ~prefix () in
          List.length es)
        (fun _ -> Lwt.return 0)
    in
    let rec loop stalled last =
      let* left = count jobs in
      let* found = count corrupted in
      Hashtbl.replace per_store m.Backend.name (left, found);
      current := Some (doing m.Backend.name "waiting on the bucket");
      if left = 0 then (
        Printf.eprintf "%s: done — %d corrupt chunk(s)\n%!" m.Backend.name found;
        Lwt.return_unit)
      else (
        Printf.eprintf "%s: %d shard request(s) left, %d corrupt so far\n%!"
          m.Backend.name left found;
        (* A store whose requests are not draining is not a store that is slow:
           nothing is consuming them, which is what an undeployed or misfiltered
           notification looks like from here. Said out loud rather than waited
           on forever. *)
        let stalled = if left = last then stalled + 1 else 0 in
        if stalled >= 5 then (
          Printf.eprintf
            "%s: nothing has been picked up in a while — check the bucket's \
             notification and the function's logs\n\
             %!"
            m.Backend.name;
          Lwt.return_unit)
        else
          let* () = Lwt_unix.sleep 3. in
          loop stalled left)
    in
    loop 0 (-1)
  in
  (* Fails rather than reporting a check that did not happen: a store with
     nothing on its side to run one says so, and saying "queued" anyway would be
     the same lie as printing zero for a store nobody looks at. *)
  let verify (module C : Conf.S) =
    let open Lwt.Syntax in
    let* answers =
      Lwt_list.map_s
        (fun (m : Backend.member) ->
          let (module B : Backend.S) = m.Backend.backend in
          let+ a = B.verify_all ~chunk_prefix:C.chunk_prefix () in
          (m.Backend.name, a))
        C.members
    in
    let queued =
      List.filter_map
        (function name, `Queued n -> Some (name, n) | _, `Unsupported -> None)
        answers
    in
    List.iter
      (fun (name, n) ->
        Printf.eprintf "%s: queued %d shard request(s)\n%!" name n)
      queued;
    List.iter
      (function
        | name, `Unsupported ->
            Printf.eprintf
              "%s: cannot check itself — no verifier runs on that store\n" name
        | _, `Queued _ -> ())
      answers;
    if queued = [] then (
      Printf.eprintf
        "Nothing was asked to check anything. A local store is swept by tsync \
         gc --verify instead.\n";
      Lwt.return 1)
    else
      let+ () =
        Lwt_list.iter_p
          (fun (m : Backend.member) ->
            if List.mem_assoc m.Backend.name queued then follow (module C) m
            else Lwt.return_unit)
          C.members
      in
      0
  in
  let repair (module C : Conf.S) source dry_run verbose =
    let open Lwt.Syntax in
    let module Rp = Repair.Make (C) in
    (* Verbose says every chunk and where it has got to; quiet says only what it
       changed. A stale marker is the one outcome quiet leaves out: it is the
       common case on a store whose events arrived out of order, and it means
       nothing was wrong. *)
    let+ s =
      Rp.run ?source ~dry_run
        ~on_start:(fun ~total ->
          planned := total;
          if verbose then
            Printf.eprintf "%d marked chunk%s to work through\n%!" total
              (if total = 1 then "" else "s"))
        ~on_chunk:(fun ~done_ ~total ~chunk_key ~store outcome ->
          checked := done_;
          if outcome = Repair.Unrepairable then incr unrepairable;
          current := Some (doing store chunk_key);
          let line = Repair.describe ~chunk_key ~store outcome in
          if verbose then
            Printf.printf "[%*d/%d] %s\n%!"
              (String.length (string_of_int total))
              done_ total line
          else if outcome <> Repair.Cleared then Printf.printf "%s\n%!" line)
        ()
    in
    Printf.printf
      "%d chunk%s: %d repaired, %d stale marker%s cleared, %d unrepairable%s\n"
      s.Repair.checked
      (if s.Repair.checked = 1 then "" else "s")
      s.Repair.repaired s.Repair.cleared
      (if s.Repair.cleared = 1 then "" else "s")
      s.Repair.unrepairable
      (if dry_run then " (dry run, nothing written)" else "");
    if s.Repair.unrepairable > 0 then (
      Printf.eprintf
        "\nNo copy of these chunks hashes to its own key anywhere:\n";
      List.iter (fun k -> Printf.eprintf "  %s\n" k) s.Repair.lost;
      Printf.eprintf
        "Nothing here can supply them: re-upload the files that use them, or \
         fill this backend from one that still has them (tsync mirror).\n";
      1)
    else 0
  in
  let run domain do_verify do_repair detail source dry_run verbose =
    set_verbose verbose;
    let (module C : Conf.S) = load_conf ?domain () in
    if do_verify && do_repair then
      failwith "--verify and --repair are separate steps; run one.";
    let code =
      run_lwt
        ~report:(fun () ->
          report_job ?domain
            (module C)
            ~kind:
              (if do_verify then "data-integrity --verify"
               else if do_repair then "data-integrity --repair"
               else "data-integrity")
            ~current:(fun () -> !current)
            ~counters:(fun () ->
              if do_verify then
                [("requests left", sum_stores fst); ("corrupt", sum_stores snd)]
              else if do_repair then
                [
                  ("chunks", !checked);
                  ("planned", !planned);
                  ("unrepairable", !unrepairable);
                ]
              else [("corrupt", !corrupt)])
            ())
        (if do_verify then verify (module C)
         else if do_repair then repair (module C) source dry_run verbose
         else report (module C) detail)
    in
    if code <> 0 then exit code
  in
  let verify_arg =
    Arg.(
      value & flag
      & info ["verify"]
          ~doc:
            "Ask every store that can to check all of its chunks, then follow \
             it: one request per shard is queued, and the count left is \
             reported as the store works through them. Interrupting stops the \
             watching, not the checking. Fails if no store can — a local store \
             is swept by $(b,tsync gc --verify) instead. Reads every byte, on \
             the store's side.")
  in
  let repair_arg =
    Arg.(
      value & flag
      & info ["repair"]
          ~doc:
            "Rewrite what was found, from a copy that hashes to the right key. \
             With $(b,--verbose), every chunk is reported as it is done, with \
             its position in the total.")
  in
  let detail_arg =
    Arg.(
      value & flag
      & info ["detail"]
          ~doc:"With no other flag: also say what each bad chunk hashed to.")
  in
  let source_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["source"] ~docv:"NAME"
          ~doc:
            "With $(b,--repair): take replacement bytes only from this store.")
  in
  let dry_run_arg =
    Arg.(
      value & flag
      & info ["dry-run"]
          ~doc:
            "With $(b,--repair): report what would be rewritten, write nothing.")
  in
  Cmd.v
    (Cmd.info "data-integrity"
       ~doc:
         "Chunks that are not what their names say: ask for a check \
          ($(b,--verify)), list what was found (the default), or put it right \
          ($(b,--repair)).")
    Term.(
      const run $ domain_arg $ verify_arg $ repair_arg $ detail_arg $ source_arg
      $ dry_run_arg $ verbose_arg)

let mirror_cmd =
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
  let path_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["path"] ~docv:"PATH"
          ~doc:
            "Copy only what is under this domain-relative folder: its files, \
             and the chunks their manifests name. Journal, versions and cursor \
             are skipped — they describe the whole domain, not a subtree.")
  in
  let run domain source manifests_only path v =
    set_verbose v;
    (* Mirror copies between the stores themselves, so it reads [C.members]
       rather than going through the composite. *)
    let (module C : Conf.S) = load_conf ?domain () in
    let src =
      Option.value source
        ~default:(match C.members with m :: _ -> m.Backend.name | [] -> "")
    in
    let current = ref None and planned = ref 0 in
    let copied = ref 0 and checked = ref 0 in
    (* Ahead of {!run_lwt} rather than inside the promise it is handed: that
       argument is evaluated before reporting starts, so a raise there is a
       command with no row and no failed state to show. *)
    if List.length C.members < 2 then
      failwith
        (Printf.sprintf
           "mirror needs at least two configured backends; %s has %d."
           C.domain_name (List.length C.members));
    if manifests_only && path <> None then
      failwith "--manifests and --path select different things; run one.";
    let code =
      run_lwt
        ~report:(fun () ->
          report_job ?domain
            (module C)
            ~kind:
              (match (manifests_only, path) with
                | _, Some _ -> "mirror --path"
                | true, None -> "mirror --manifests"
                | false, None -> "mirror")
            ~target:src
            ~current:(fun () -> !current)
            ~counters:(fun () ->
              [
                ("objects", !checked); ("planned", !planned); ("copied", !copied);
              ])
            ())
        (let open Lwt.Syntax in
         begin
           let scope =
             match (manifests_only, path) with
               | _, Some rel -> `Path rel
               | true, None -> `Manifests
               | false, None -> `All
           in
           vprintf "initiating remote sync: copying %s from %s..."
             (match scope with
               | `All -> "all objects"
               | `Manifests -> "manifests"
               | `Path rel -> Printf.sprintf "%s and its chunks" rel)
             src;
           let module M = Mirror.Make (C) in
           let on_list ~name =
             current := Some name;
             vprintf "  %s..." name
           in
           (* Every destination is examined for every source object, and they go
              one after another, so the run's own total is the product. *)
           let destinations =
             List.length
               (List.filter
                  (fun (m : Backend.member) -> m.Backend.name <> src)
                  C.members)
           in
           let on_scan ~objects ~bytes =
             planned := objects * destinations;
             (* A mirror spends its time asking destinations what they hold, and
                mostly they hold it: an estimate against what it happened to
                copy would answer with hours of transfer for a run that has
                minutes of checking left. *)
             Job.Progress.plan ~basis:`Handled
               ~bytes:(Int64.mul bytes (Int64.of_int destinations));
             vprintf "scanned %s: %d object%s to check" src objects
               (if objects = 1 then "" else "s")
           in
           let on_start ~name ~key =
             incr checked;
             current := Some (doing name key)
           in
           (* As each object lands rather than as a list at the end: the list
              was the whole keyspace of a first resync, held to print it. *)
           let on_entry ~name ~key ~size ~outcome =
             let size = Int64.of_int size in
             match outcome with
               | `Present -> Job.Progress.settle ~bytes:size ~sent:0L `Skipped
               | `Copied (reason, bytes) ->
                   Job.Progress.settle ~bytes:size ~sent:(Int64.of_int bytes)
                     `Done;
                   incr copied;
                   let why =
                     match reason with
                       | `Missing -> "missing"
                       | `Wrong_size -> "wrong size"
                   in
                   if !verbose then
                     vprintf "  copied %s (%s, %s) -> %s" key
                       (human_bytes bytes) why name
                   else Printf.printf "copied %s -> %s\n%!" key name
           in
           let+ dests =
             M.resync ~source:src ~scope ~on_scan ~on_list ~on_start ~on_entry
               ()
           in
           List.iter
             (fun (dst : Mirror.dest_stats) ->
               Printf.printf "%s -> %s: %d object%s checked, %d copied (%s)\n"
                 src dst.Mirror.name dst.Mirror.checked
                 (if dst.Mirror.checked = 1 then "" else "s")
                 dst.Mirror.copied
                 (human_bytes dst.Mirror.copied_bytes))
             dests;
           0
         end)
    in
    if code <> 0 then exit code
  in
  Cmd.v
    (Cmd.info "mirror"
       ~doc:
         "Fill one backend from another: copy every object of the domain \
          (manifests, chunks, journal, versions) that is missing or \
          size-mismatched on the other configured backends. Pass --manifests \
          to copy only the manifests, --path to copy one folder and the chunks \
          its files name. A chunk of the right size holding the wrong bytes is \
          data-integrity's to find, not this one's.")
    Term.(
      const run $ domain_arg $ source_arg $ manifests_arg $ path_arg
      $ verbose_arg)

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
    let (module C : Conf.S) = load_conf ?domain () in
    let current = ref None and planned = ref 0 in
    (* The same buckets {!Import.tally} keeps, so the row in [tsync status] and
       the summary this prints cannot disagree about one run. *)
    let imported = ref 0
    and skipped = ref 0
    and symlinks = ref 0
    and failed = ref 0 in
    let failures =
      run_lwt
        ~report:(fun () ->
          report_job ?domain
            (module C)
            ~kind:"import" ~target:src
            ~current:(fun () -> !current)
            ~counters:(fun () ->
              [
                ("files", !imported);
                ("planned", !planned);
                ("skipped", !skipped);
                ("symlinks", !symlinks);
                ("failed", !failed);
              ])
            ())
        (let open Lwt.Syntax in
         let module I = Import.Make (C) in
         vprintf "importing from %s into domain %s" src C.domain_name;
         let+ summary =
           I.run ~only ~exclude ~force_rehash ~src
             ~on_dir:(fun ~rel ->
               current := Some rel;
               Printf.printf "mkdir    %s\n%!" rel)
             ~on_plan:(fun ~files ~bytes ->
               planned := files;
               (* An import is transfer-bound: what is left is uploads, and the
                  rate that predicts them is the one they ran at. *)
               Job.Progress.plan ~basis:`Sent ~bytes)
             ~on_start:(fun ~rel ~size ->
               current := Some rel;
               Job.Progress.start_entry ~size)
             ~on_progress:(fun ~bytes ~sent ->
               Job.Progress.advance ~bytes ~sent)
             ~on_file:(fun ~rel status ->
               match status with
                 | Import.Imported size ->
                     Job.Progress.finish_entry (`Done size);
                     incr imported;
                     Printf.printf "imported %s (%Ld bytes)\n%!" rel size
                 | Import.Skipped_exists ->
                     Job.Progress.finish_entry `Skipped;
                     incr skipped;
                     Printf.printf "skip     %s (already in domain)\n%!" rel
                 | Import.Skipped_symlink ->
                     Job.Progress.finish_entry `Skipped;
                     incr symlinks;
                     Printf.printf "skip     %s (symlink)\n%!" rel
                 | Import.Failed msg ->
                     Job.Progress.finish_entry `Failed;
                     incr failed;
                     Printf.printf "failed   %s: %s\n%!" rel msg)
             ()
         in
         Printf.printf
           "\n%d file%s imported, %d skipped, %d symlinks skipped, %d failed\n"
           summary.Import.imported
           (if summary.Import.imported = 1 then "" else "s")
           summary.Import.skipped summary.Import.skipped_symlinks
           summary.Import.failed;
         summary.Import.failed)
    in
    (* Outside {!run_lwt}: exiting from inside its promise would skip both the
       deferred drain it exists for and the job's own last report. *)
    if failures > 0 then exit 1
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
    let (module C : Conf.S) = load_conf ?domain () in
    let current = ref None and planned = ref 0 in
    (* The same buckets the summary below prints, so the row in [tsync status]
       and that line cannot disagree about one run. *)
    let exported = ref 0 and symlinks = ref 0 and missing = ref 0 in
    let code =
      run_lwt
        ~report:(fun () ->
          report_job ?domain
            (module C)
            ~kind:"export" ~target:dst
            ~current:(fun () -> !current)
            ~counters:(fun () ->
              [
                ("files", !exported);
                ("planned", !planned);
                ("symlinks", !symlinks);
                ("missing", !missing);
              ])
            ())
        (let open Lwt.Syntax in
         let module E = Export.Make (C) in
         vprintf "exporting domain %s to %s" C.domain_name dst;
         let+ summary =
           E.run ~dst
             ~on_plan:(fun ~files -> planned := files)
             ~on_start:(fun ~rel -> current := Some rel)
             ~on_file:(fun ~rel status ->
               match status with
                 | Export.Exported ->
                     incr exported;
                     Printf.printf "exported %s\n%!" rel
                 | Export.Exported_symlink ->
                     incr exported;
                     incr symlinks;
                     Printf.printf "exported %s (symlink)\n%!" rel
                 | Export.Missing_data ->
                     incr missing;
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
    Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let clear_cache_arg =
    Arg.(
      value & flag
      & info ["clear-cache"]
          ~doc:
            "Delete the files the share server has assembled and cached, \
             instead of publishing a link. Published links are not touched and \
             keep working: the next download rebuilds what it needs.")
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
  let clear_cache domain =
    let cfg = load_config () in
    let domain =
      match domain with Some _ -> domain | None -> read_default_domain ()
    in
    let (module C : Conf.S) = make_conf ?domain cfg in
    let module S = Share.Make (C) in
    match run_lwt (S.clear_cache ()) with
      | Error msg ->
          Printf.eprintf "%s\n" msg;
          exit 1
      | Ok (0, _) -> print_endline "Nothing cached."
      | Ok (n, bytes) ->
          Printf.printf "Deleted %d cached object%s (%s).\n" n
            (if n = 1 then "" else "s")
            (human_bytes bytes)
  in
  let publish path expires domain token =
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
  let run path expires domain token clear =
    match (path, clear) with
      | Some path, false -> publish path expires domain token
      | None, true -> clear_cache domain
      | None, false -> failwith "share needs a PATH, or --clear-cache."
      | Some _, true -> failwith "--clear-cache takes no PATH."
  in
  Cmd.v
    (Cmd.info "share"
       ~doc:
         "Print a shareable download URL for a file or folder, or with \
          $(b,--clear-cache), drop what the share server has assembled.")
    Term.(
      const run $ path_arg $ expires_arg $ domain_arg $ token_arg
      $ clear_cache_arg)

let config_cmd =
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
  let edit_arg =
    Arg.(
      value & flag
      & info ["edit"]
          ~doc:
            "Create or edit the configuration interactively instead of \
             printing it.")
  in
  let run edit = if edit then Configure.run () else run () in
  Cmd.v
    (Cmd.info "config"
       ~doc:
         "Print the configuration as the daemon parsed it, secrets hidden. \
          With $(b,--edit), change it interactively.")
    Term.(const run $ edit_arg)

(* What this binary is and where it keeps things, as against [tsync config],
   which is what the operator asked of it. Neither answers the other's question
   and a report usually wants both. *)
let build_info_cmd =
  let features () =
    Printf.printf "frontends: %s\ns3 backend: %b\nlog: %s\n"
      (String.concat ", " (Frontend.names ()))
      S3_link.s3_backend_enabled Log.Daemon.implementation
  in
  let paths () =
    let p = runtime_paths in
    Printf.printf "config:  %s\n" p.Runtime.config_path;
    Printf.printf "cache:   %s\n" p.Runtime.cache_root;
    Printf.printf "data:    %s\n" p.Runtime.data_dir;
    (* Per domain, since that is how many there are: one each under FUSE, the
       same one repeated on macOS. *)
    List.iter
      (fun (name, socket) -> Printf.printf "socket:  %s (%s)\n" socket name)
      (try domain_targets () with _ -> [])
  in
  let run () =
    features ();
    print_newline ();
    paths ()
  in
  Cmd.v
    (Cmd.info "build-info"
       ~doc:
         "Show what was compiled into this binary and the filesystem paths it \
          uses.")
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

let default_domain_cmd =
  let name_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"NAME")
  in
  let clear_arg =
    Arg.(value & flag & info ["clear"] ~doc:"Forget the default domain")
  in
  let show () =
    match read_default_domain () with
      | Some name -> print_endline name
      | None ->
          Printf.eprintf "No default domain set.\n";
          exit 1
  in
  let forget () =
    (try Unix.unlink (default_domain_file ())
     with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
    print_endline "Default domain cleared."
  in
  let set name =
    let cfg = load_config () in
    match
      List.find_opt
        (fun (d : Conf_parsing.domain) -> d.name = name)
        cfg.Conf_parsing.domains
    with
      | None ->
          Printf.eprintf "Domain not found: %s\n" name;
          exit 1
      | Some _ ->
          let file = default_domain_file () in
          Fs_util.mkdir_p_sync (Filename.dirname file);
          let oc = open_out file in
          output_string oc (name ^ "\n");
          close_out oc;
          Printf.printf "Default domain set to: %s\n" name
  in
  let run name clear =
    match (name, clear) with
      | None, false -> show ()
      | None, true -> forget ()
      | Some _, true -> failwith "--clear takes no domain name."
      | Some name, false -> set name
  in
  Cmd.v
    (Cmd.info "default-domain"
       ~doc:
         "Print the domain used when $(b,--domain) is omitted. Name one to set \
          it, or $(b,--clear) to forget it.")
    Term.(const run $ name_arg $ clear_arg)

(* Each registered frontend surfaces its commands as `tsync <cli_group> <verb>`,
   the binary owning [--domain] parsing and checking the frontend is configured
   for that domain before handing over. Groups exist only for frontends linked
   into this binary, so `fileprovider` appears on macOS but not Linux. *)
let frontend_cmds () =
  let args_arg =
    Arg.(
      value & pos_all string []
      & info [] ~docv:"ARG" ~doc:"Arguments for the verb, passed through as-is.")
  in
  let run name (command : Frontend.command) domain args =
    let cfg = load_config () in
    let domain =
      match domain with Some _ -> domain | None -> read_default_domain ()
    in
    let d = Conf_parsing.pick_domain ?domain cfg in
    if not (List.mem name (frontend_names d)) then (
      Printf.eprintf "domain %s has no %s frontend\n" d.Conf_parsing.name name;
      exit 1);
    let (module C : Conf.S) = make_conf ?domain cfg in
    command.Frontend.run (module C) args
  in
  List.filter_map
    (fun (name, cli_group, commands) ->
      match commands with
        | [] -> None
        | _ ->
            (* [Term.(...)] opens a module with a [name] of its own, which would
               otherwise shadow the frontend's. *)
            let frontend_name = name in
            let subs =
              List.map
                (fun (command : Frontend.command) ->
                  Cmd.v
                    (Cmd.info command.Frontend.verb ~doc:command.Frontend.doc)
                    Term.(
                      const (run frontend_name command) $ domain_arg $ args_arg))
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
         build_info_cmd;
         config_cmd;
         restart_cmd;
         default_domain_cmd;
         start_cmd;
         stop_cmd;
         logs_cmd;
         pause_uploads_cmd;
         resume_uploads_cmd;
         status_cmd;
         sync_cmd;
         data_integrity_cmd;
         mirror_cmd;
         import_cmd;
         export_cmd;
         cache_cmd;
         ls_cmd;
         share_cmd;
         versions_cmd;
         trash_cmd;
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
