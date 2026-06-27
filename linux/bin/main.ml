open Cmdliner
open Tsync_lib

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let default_mount_point cfg domain_name =
  ignore cfg;
  Filename.concat (Sys.getenv "HOME") ("tsync/" ^ domain_name)

let load_store ?domain_name () =
  let cfg = Config.load () in
  let domain_name =
    match domain_name with
      | Some n -> n
      | None -> (
          match cfg.Config.domains with
            | [] -> failwith "No domains configured"
            | d :: _ -> d.Config.name)
  in
  let client =
    S3_client.make ~bucket:cfg.Config.bucket ~region:cfg.Config.aws_region
      ~access_key_id:cfg.Config.access_key_id
      ~secret_access_key:cfg.Config.secret_access_key
  in
  let domain_prefix = Config.domain_prefix cfg domain_name in
  let chunk_prefix = Config.chunk_prefix cfg in
  let trash_prefix = Config.trash_prefix cfg domain_name in
  let journal_prefix = Config.journal_prefix cfg domain_name in
  let version_key = Config.version_key cfg domain_name in
  let store =
    File_store.make ~client ~domain_name ~domain_prefix ~chunk_prefix
      ~trash_prefix ~versioning:cfg.Config.versioning ~journal_prefix
      ~version_key
  in
  (cfg, domain_name, store)

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
      & info ["domain"] ~docv:"NAME"
          ~doc:"Domain name (default: first configured)")
  in
  let run mount domain =
    let cfg, domain_name, store = load_store ?domain_name:domain () in
    let mount_point =
      match mount with
        | Some p -> p
        | None -> default_mount_point cfg domain_name
    in
    mkdir_p mount_point;
    (* Clean up any stale FUSE mount left by a previous crash *)
    ignore (Sys.command (Printf.sprintf "fusermount3 -u %s 2>/dev/null" (Filename.quote mount_point)));
    Log.init ();
    let ctx =
      Fuse_fs.
        {
          store;
          domain_name;
          domain_prefix = File_store.domain_prefix store;
          mount_point;
        }
    in
    Fuse_fs.mount ctx [| "tsync"; mount_point |]
  in
  Cmd.v
    (Cmd.info "start" ~doc:"Mount the filesystem (run via systemd unit)")
    Term.(const run $ mount_arg $ domain_arg)

(* ── tsync stop ─────────────────────────────────────────────────────────── *)

let stop_cmd =
  let run () =
    let resp = Ipc.send "STOP" in
    if resp = "OK" || resp = "STOP" then print_endline "Stopped."
    else Printf.eprintf "Error: %s\n" resp
  in
  Cmd.v
    (Cmd.info "stop" ~doc:"Stop the sync daemon")
    Term.(const run $ const ())

(* ── tsync status ────────────────────────────────────────────────────────── *)

let status_cmd =
  let run () =
    try print_endline (Ipc.send "STATUS")
    with _ -> print_endline "Daemon not running"
  in
  Cmd.v
    (Cmd.info "status" ~doc:"Show daemon status")
    Term.(const run $ const ())

(* ── tsync evict ─────────────────────────────────────────────────────────── *)

let evict_cmd =
  let path_arg =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let run path =
    let resp = Ipc.send ("EVICT " ^ path) in
    if resp = "OK" then Printf.printf "Evicted: %s\n" path
    else Printf.eprintf "Error: %s\n" resp
  in
  Cmd.v
    (Cmd.info "evict" ~doc:"Evict a file from local cache")
    Term.(const run $ path_arg)

(* ── tsync restore ───────────────────────────────────────────────────────── *)

let restore_cmd =
  let path_arg =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let run path =
    let resp = Ipc.send ("RESTORE " ^ path) in
    if resp = "OK" then Printf.printf "Restore requested: %s\n" path
    else Printf.eprintf "Error: %s\n" resp
  in
  Cmd.v
    (Cmd.info "restore" ~doc:"Download an evicted file")
    Term.(const run $ path_arg)

(* ── tsync wait ──────────────────────────────────────────────────────────── *)

let wait_cmd =
  let path_arg =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let timeout_arg =
    Arg.(
      value & opt float 60.0
      & info ["timeout"] ~docv:"SECONDS" ~doc:"Timeout in seconds (default 60)")
  in
  let run path timeout =
    let deadline = Unix.gettimeofday () +. timeout in
    let rec poll () =
      let resp = Ipc.send ("WAIT " ^ path) in
      if resp = "OK" then (
        Printf.printf "Ready: %s\n" path;
        exit 0)
      else if Unix.gettimeofday () >= deadline then (
        Printf.eprintf "Timeout waiting for %s\n" path;
        exit 1)
      else (
        Unix.sleepf 0.5;
        poll ())
    in
    poll ()
  in
  Cmd.v
    (Cmd.info "wait" ~doc:"Wait until a file is cached locally")
    Term.(const run $ path_arg $ timeout_arg)

(* ── tsync pull ──────────────────────────────────────────────────────────── *)

let pull_cmd =
  let path_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let force_arg =
    Arg.(value & flag & info ["force"] ~doc:"Restore even if already cached")
  in
  let run path force =
    let _cfg, domain_name, store = load_store () in
    let mount_point =
      match path with
        | Some p -> p
        | None ->
            let home = Sys.getenv "HOME" in
            Filename.concat home ("tsync/" ^ domain_name)
    in
    let prefix = File_store.domain_prefix store in
    let all =
      S3_client.list_all
        ( File_store.domain_prefix store |> fun _ ->
          (* ponytail: access client via store internals not exposed — use list_directory *)
          failwith "todo" )
        ~prefix ()
    in
    ignore (mount_point, force, all);
    Printf.eprintf "pull: not yet implemented\n"
  in
  Cmd.v
    (Cmd.info "pull" ~doc:"Download all evicted files")
    Term.(const run $ path_arg $ force_arg)

(* ── tsync ls ────────────────────────────────────────────────────────────── *)

let ls_cmd =
  let path_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let run path =
    let _cfg, domain_name, store = load_store () in
    let mount_point =
      let home = Sys.getenv "HOME" in
      Filename.concat home ("tsync/" ^ domain_name)
    in
    let dir = match path with Some p -> p | None -> mount_point in
    let prefix =
      let dp = File_store.domain_prefix store in
      if dir = mount_point then dp else dp ^ Filename.basename dir ^ "/"
    in
    let files, subdirs = File_store.list_directory store ~prefix in
    let domain_prefix = File_store.domain_prefix store in
    let dp_len = String.length domain_prefix in
    List.iter
      (fun (e : S3_client.file_entry) ->
        let name =
          if String.length e.key > dp_len then
            String.sub e.key dp_len (String.length e.key - dp_len)
          else e.key
        in
        let cached = File_store.is_cached store e.key in
        Printf.printf "%s  %s  %d bytes\n"
          (if cached then "local" else "cloud")
          name e.size)
      files;
    List.iter (fun d -> Printf.printf "dir    %s/\n" d) subdirs
  in
  Cmd.v
    (Cmd.info "ls" ~doc:"List files with cache status")
    Term.(const run $ path_arg)

(* ── tsync history ───────────────────────────────────────────────────────── *)

let history_cmd =
  let path_arg =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let run _path = Printf.eprintf "history: not yet implemented\n" in
  Cmd.v
    (Cmd.info "history" ~doc:"Show version history for a file")
    Term.(const run $ path_arg)

(* ── tsync purge ─────────────────────────────────────────────────────────── *)

let purge_cmd =
  let path_arg =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let run _path = Printf.eprintf "purge: not yet implemented\n" in
  Cmd.v
    (Cmd.info "purge" ~doc:"Delete all versions from trash")
    Term.(const run $ path_arg)

(* ── tsync auto-evict ────────────────────────────────────────────────────── *)

let auto_evict_cmd =
  let state_arg =
    Arg.(
      value
      & pos 0 (some string) None
      & info [] ~docv:"on|off|status"
          ~doc:"Enable, disable, or query auto-evict after upload")
  in
  let run state =
    match state with
      | None | Some "status" -> (
          let resp = Ipc.send "AUTO_EVICT status" in
          match resp with
            | "on" | "off" -> Printf.printf "auto-evict: %s\n" resp
            | _ -> Printf.eprintf "Error: %s\n" resp)
      | Some ("on" | "off" as s) ->
          let resp = Ipc.send ("AUTO_EVICT " ^ s) in
          if resp = "OK" then Printf.printf "auto-evict: %s\n" s
          else Printf.eprintf "Error: %s\n" resp
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
      & info ["domain"] ~docv:"NAME"
          ~doc:"Domain name (default: first configured)")
  in
  let run domain =
    let _cfg, domain_name, store = load_store ?domain_name:domain () in
    File_store.recover_pending_ops store;
    let last_sync_file =
      Filename.concat (Journal.share_dir ()) ("last-sync-" ^ domain_name)
    in
    let last_sync_key =
      if Sys.file_exists last_sync_file then (
        let ic = open_in last_sync_file in
        let s = input_line ic in
        close_in ic;
        String.trim s)
      else ""
    in
    let all_keys = File_store.list_journal_keys store () in
    let need_full_resync =
      if last_sync_key = "" then true
      else
        match all_keys with
          | [] -> false
          | (oldest_key, _) :: _ ->
              Journal.timestamp_ms_of_filename oldest_key
              > Journal.timestamp_ms_of_filename last_sync_key
    in
    if need_full_resync then begin
      (try
         let resp = Ipc.send "FULL_RESYNC" in
         if resp <> "OK" then
           Printf.eprintf "Warning: FULL_RESYNC response: %s\n" resp
       with _ -> ());
      let new_key = File_store.journal_prefix store ^ Journal.entry_key () in
      let oc = open_out last_sync_file in
      output_string oc new_key;
      close_out oc;
      Printf.printf "full resync\n"
    end else begin
      let my_uuid = Journal.client_uuid () in
      let recent_foreign =
        all_keys
        |> List.filter (fun (k, _) -> k > last_sync_key)
        |> List.filter (fun (_, uuid) -> uuid <> my_uuid)
      in
      let touched = Hashtbl.create 16 in
      List.iter
        (fun (ek, _) ->
          match File_store.get_journal_entry store ek with
            | None -> ()
            | Some ops ->
                List.iter
                  (fun op ->
                    match op with
                      | `Put (k, _) | `Delete k | `Mkdir k | `Rmdir k ->
                          Hashtbl.replace touched k ()
                      | `Rename (k, src, _) ->
                          Hashtbl.replace touched k ();
                          Hashtbl.replace touched src ())
                  ops)
        recent_foreign;
      let touched_keys = Hashtbl.fold (fun k () acc -> k :: acc) touched [] in
      List.iter
        (fun rel_key ->
          (* prepend "/" so ipc_handler's fuse_to_key strips it correctly *)
          let resp = Ipc.send ("EVICT /" ^ rel_key) in
          if resp <> "OK" then
            Printf.eprintf "Warning: evict %s: %s\n" rel_key resp)
        touched_keys;
      (match all_keys with
        | [] -> ()
        | _ ->
            let last_key, _ = List.nth all_keys (List.length all_keys - 1) in
            (* store full S3 key for cross-platform compatibility *)
            let oc = open_out last_sync_file in
            let store_val = File_store.journal_prefix store ^ last_key in
            output_string oc store_val;
            close_out oc);
      let n = List.length touched_keys in
      Printf.printf "%d change%s\n" n (if n = 1 then "" else "s")
    end
  in
  Cmd.v
    (Cmd.info "sync" ~doc:"Sync local cache with remote journal changes")
    Term.(const run $ domain_arg)

(* ── Main ────────────────────────────────────────────────────────────────── *)

let () =
  let cmd =
    Cmd.group
      (Cmd.info "tsync" ~doc:"S3-backed FUSE filesystem sync")
      [
        start_cmd;
        stop_cmd;
        status_cmd;
        sync_cmd;
        evict_cmd;
        restore_cmd;
        pull_cmd;
        wait_cmd;
        ls_cmd;
        history_cmd;
        purge_cmd;
        auto_evict_cmd;
      ]
  in
  exit (Cmd.eval cmd)
