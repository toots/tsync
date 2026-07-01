open Cmdliner

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let () =
  if not Runtime.implemented then (
    Printf.eprintf "No backend available at compile-time!\n%!";
    exit 1)

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let runtime_paths = Runtime.default_paths ()

let make_conf ?domain cfg : (module Conf.S) =
  let domain_name =
    match domain with Some d -> d | None -> cfg.Conf_parsing.domain_name
  in
  (module struct
    let bucket = cfg.Conf_parsing.bucket
    let prefix = cfg.Conf_parsing.prefix
    let aws_region = cfg.Conf_parsing.aws_region
    let versioning = cfg.Conf_parsing.versioning
    let access_key_id = cfg.Conf_parsing.access_key_id
    let secret_access_key = cfg.Conf_parsing.secret_access_key
    let domain_name = domain_name
    let domain_prefix = Conf_parsing.domain_prefix cfg domain_name
    let chunk_prefix = Conf_parsing.chunk_prefix cfg
    let trash_prefix = Conf_parsing.trash_prefix cfg domain_name
    let journal_prefix = Conf_parsing.journal_prefix cfg domain_name
    let version_key = Conf_parsing.version_key cfg domain_name
    let client =
      S3_client.make ~bucket ~region:aws_region ~access_key_id
        ~secret_access_key
    let cache_root = runtime_paths.Runtime.cache_root
    let data_dir = runtime_paths.Runtime.data_dir
    let socket_path = runtime_paths.Runtime.socket_path
    let notify_path =
      Filename.concat runtime_paths.Runtime.data_dir "notify.sock"
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
  let run mount domain =
    let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
    let (module C : Conf.S) = make_conf ?domain cfg in
    let mount_point =
      match mount with
        | Some p -> p
        | None ->
            Filename.concat (Sys.getenv "HOME") ("tsync/" ^ C.domain_name)
    in
    mkdir_p mount_point;
    Runtime.pre_start ~mount_point;
    Log.init ();
    let module R = Runtime.Make(C) in
    R.mount mount_point
  in
  Cmd.v
    (Cmd.info "start" ~doc:"Mount the filesystem (run via systemd unit)")
    Term.(const run $ mount_arg $ domain_arg)

(* ── tsync stop ─────────────────────────────────────────────────────────── *)

let stop_cmd =
  let run () =
    let resp =
      Ipc.send ~socket_path:runtime_paths.Runtime.socket_path "STOP"
    in
    if resp = "OK" || resp = "STOP" then print_endline "Stopped."
    else Printf.eprintf "Error: %s\n" resp
  in
  Cmd.v
    (Cmd.info "stop" ~doc:"Stop the sync daemon")
    Term.(const run $ const ())

(* ── tsync status ────────────────────────────────────────────────────────── *)

let status_cmd =
  let run () =
    try
      print_endline
        (Ipc.send ~socket_path:runtime_paths.Runtime.socket_path "STATUS")
    with _ -> print_endline "Daemon not running"
  in
  Cmd.v
    (Cmd.info "status" ~doc:"Show daemon status")
    Term.(const run $ const ())

(* ── tsync evict ─────────────────────────────────────────────────────────── *)

let evict_cmd =
  let path_arg = Arg.(non_empty & pos_all string [] & info [] ~docv:"PATH") in
  let run paths =
    List.iter
      (fun path ->
        let resp =
          Ipc.send ~socket_path:runtime_paths.Runtime.socket_path
            ("EVICT " ^ path)
        in
        if resp = "OK" then Printf.printf "Evicted: %s\n" path
        else Printf.eprintf "Error: %s\n" resp)
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
        let resp =
          Ipc.send ~socket_path:runtime_paths.Runtime.socket_path
            ("RESTORE " ^ path)
        in
        if resp = "OK" then Printf.printf "Restored: %s\n" path
        else Printf.eprintf "Error: %s\n" resp)
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
  let run path =
    let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
    let (module C : Conf.S) = make_conf cfg in
    let module Fs = File_store.Make(C) in
    let mount_point =
      Filename.concat (Sys.getenv "HOME") ("tsync/" ^ C.domain_name)
    in
    let dir = match path with Some p -> p | None -> mount_point in
    let prefix =
      let dp = C.domain_prefix in
      if dir = mount_point then dp else dp ^ Filename.basename dir ^ "/"
    in
    let files, subdirs = Fs.list_directory ~prefix in
    let dp_len = String.length C.domain_prefix in
    List.iter
      (fun (e : S3_client.file_entry) ->
        let name =
          if String.length e.key > dp_len then
            String.sub e.key dp_len (String.length e.key - dp_len)
          else e.key
        in
        let cached =
          Local.is_cached ~cache_root:C.cache_root
            ~domain_name:C.domain_name ~domain_prefix:C.domain_prefix e.key
        in
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
          let resp =
            Ipc.send ~socket_path:runtime_paths.Runtime.socket_path
              "AUTO_EVICT status"
          in
          match resp with
            | "on" | "off" -> Printf.printf "auto-evict: %s\n" resp
            | _ -> Printf.eprintf "Error: %s\n" resp)
      | Some (("on" | "off") as s) ->
          let resp =
            Ipc.send ~socket_path:runtime_paths.Runtime.socket_path
              ("AUTO_EVICT " ^ s)
          in
          if resp = "OK" then Printf.printf "auto-evict: %s\n" s
          else Printf.eprintf "Error: %s\n" resp
      | Some other ->
          Printf.eprintf "Expected on|off|status, got: %s\n" other
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
  let run domain =
    let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
    let (module C : Conf.S) = make_conf ?domain cfg in
    let module J = Journal.Make(C) in
    let module Fs = File_store.Make(C) in
    let module Sq = Sync_queue.Make(C) in
    let module F = File.Make(C)(Sq) in
    Sq.start
      ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
      ~on_version:(fun ~entry_key:_ -> ())
      ~on_upload_done:(fun ~key:_ -> ());
    let my_uuid = J.client_uuid () in
    let recover_pending_ops () =
      List.iter
        (fun (entry_key, ops) ->
          let remote_key = C.journal_prefix ^ entry_key in
          if Fs.head_opt ~key:remote_key <> None then
            J.delete_local_pending ~entry_key
          else begin
            let newer_keys = Fs.list_journal_keys ~start_after:entry_key () in
            let remotely_modified = Hashtbl.create 16 in
            List.iter
              (fun (ek, uuid) ->
                if uuid <> my_uuid then (
                  match Fs.get_journal_entry ek with
                    | None -> ()
                    | Some remote_ops ->
                        List.iter
                          (fun op ->
                            match op with
                              | `Put (k, _)
                              | `Delete k
                              | `Mkdir k
                              | `Rmdir k ->
                                  Hashtbl.replace remotely_modified k ()
                              | `Rename { Journal.dst; src; _ } ->
                                  Hashtbl.replace remotely_modified dst ();
                                  Hashtbl.replace remotely_modified src ())
                          remote_ops))
              newer_keys;
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
            List.iter
              (fun op ->
                try
                  match op with
                    | `Put (rel_key, _) ->
                        let key = C.domain_prefix ^ rel_key in
                        if F.is_cached key then F.upload key
                    | `Delete rel_key ->
                        F.apply_delete (C.domain_prefix ^ rel_key)
                    | `Mkdir rel_key ->
                        Fs.create_directory ~key:(C.domain_prefix ^ rel_key)
                    | `Rmdir rel_key ->
                        Fs.delete_dir ~prefix:(C.domain_prefix ^ rel_key)
                    | `Rename
                        { Journal.dst = dst_rel; src = src_rel; is_dir; _ } ->
                        let src_key = C.domain_prefix ^ src_rel in
                        let dst_key = C.domain_prefix ^ dst_rel in
                        if is_dir then
                          Fs.rename_directory
                            ~src_prefix:(src_key ^ "/")
                            ~dst_prefix:(dst_key ^ "/")
                        else Fs.rename_file ~src_key ~dst_key
                with exn ->
                  Log.err "recover_pending_ops: %s" (Printexc.to_string exn))
              replayed;
            if replayed <> [] then begin
              ignore (Fs.write_journal_entry ~entry_key replayed);
              Fs.bump_version entry_key
            end;
            J.delete_local_pending ~entry_key
          end)
        (J.local_pending_entries ~uuid:my_uuid)
    in
    recover_pending_ops ();
    Sq.drain ();
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
    let all_keys = Fs.list_journal_keys () in
    let need_full_resync =
      if last_sync_key = "" then true
      else (
        match all_keys with
          | [] -> false
          | (oldest_key, _) :: _ ->
              Journal.timestamp_ms_of_filename oldest_key
              > Journal.timestamp_ms_of_filename last_sync_key)
    in
    if need_full_resync then begin
      (try
         let resp = Ipc.send ~socket_path:C.socket_path "FULL_RESYNC" in
         if resp <> "OK" then
           Printf.eprintf "Warning: FULL_RESYNC response: %s\n" resp
       with _ -> ());
      let new_key = C.journal_prefix ^ J.entry_key () in
      let oc = open_out last_sync_file in
      output_string oc new_key;
      close_out oc;
      Printf.printf "full resync\n"
    end
    else begin
      let last_sync_basename = Filename.basename last_sync_key in
      let recent_foreign =
        all_keys
        |> List.filter (fun (k, _) -> k > last_sync_basename)
        |> List.filter (fun (_, uuid) -> uuid <> my_uuid)
      in
      let touched = Hashtbl.create 16 in
      List.iter
        (fun (ek, _) ->
          match Fs.get_journal_entry ek with
            | None -> ()
            | Some ops ->
                List.iter
                  (fun op ->
                    match op with
                      | `Put (k, _) | `Delete k | `Mkdir k | `Rmdir k ->
                          Hashtbl.replace touched k ()
                      | `Rename { Journal.dst; src; _ } ->
                          Hashtbl.replace touched dst ();
                          Hashtbl.replace touched src ())
                  ops)
        recent_foreign;
      let touched_keys =
        Hashtbl.fold (fun k () acc -> k :: acc) touched []
      in
      List.iter
        (fun rel_key ->
          let resp =
            Ipc.send ~socket_path:C.socket_path ("EVICT /" ^ rel_key)
          in
          if resp <> "OK" then
            Printf.eprintf "Warning: evict %s: %s\n" rel_key resp)
        touched_keys;
      (match all_keys with
        | [] -> ()
        | _ ->
            let last_key, _ = List.nth all_keys (List.length all_keys - 1) in
            let oc = open_out last_sync_file in
            let store_val = C.journal_prefix ^ last_key in
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
      (Cmd.info "tsync" ~doc:"S3-backed filesystem sync")
      [
        start_cmd;
        stop_cmd;
        status_cmd;
        sync_cmd;
        evict_cmd;
        restore_cmd;
        pull_cmd;
        ls_cmd;
        history_cmd;
        purge_cmd;
        auto_evict_cmd;
      ]
  in
  exit (Cmd.eval cmd)
