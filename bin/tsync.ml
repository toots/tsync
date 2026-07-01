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

let make_backend (bc : Conf_parsing.backend_config) =
  Backend.make ~backend_type:bc.backend_type
    ~get_field:(fun k -> List.assoc_opt k bc.fields)

let make_conf ?domain cfg : (module Conf.S) =
  let d = Conf_parsing.pick_domain ?domain cfg in
  (module struct
    let versioning = cfg.Conf_parsing.versioning
    let domain_name = d.Conf_parsing.name
    let domain_prefix = Conf_parsing.domain_prefix d
    let chunk_prefix = Conf_parsing.chunk_prefix d
    let trash_prefix = Conf_parsing.trash_prefix d
    let journal_prefix = Conf_parsing.journal_prefix d
    let version_key = Conf_parsing.version_key d
    let backends = List.map make_backend d.Conf_parsing.backends
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
        | None -> Filename.concat (Sys.getenv "HOME") ("tsync/" ^ C.domain_name)
    in
    mkdir_p mount_point;
    Runtime.pre_start ~mount_point;
    Log.init ();
    let module R = Runtime.Make (C) in
    R.mount mount_point
  in
  Cmd.v
    (Cmd.info "start" ~doc:"Mount the filesystem (run via systemd unit)")
    Term.(const run $ mount_arg $ domain_arg)

(* ── tsync stop ─────────────────────────────────────────────────────────── *)

let stop_cmd =
  let run () =
    let resp = Ipc.send ~socket_path:runtime_paths.Runtime.socket_path "STOP" in
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
    let module Fs = File_store.Make (C) in
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
      (fun (e : Backend.file_entry) ->
        let name =
          if String.length e.key > dp_len then
            String.sub e.key dp_len (String.length e.key - dp_len)
          else e.key
        in
        let cached =
          Local.is_cached ~cache_root:C.cache_root ~domain_name:C.domain_name
            ~domain_prefix:C.domain_prefix e.key
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
  let run domain =
    let cfg = Conf_parsing.load runtime_paths.Runtime.config_path in
    let (module C : Conf.S) = make_conf ?domain cfg in
    let module J = Journal.Make (C) in
    let module Fs = File_store.Make (C) in
    let module Sq = Sync_queue.Make (C) in
    let module F = File.Make (C) (Sq) in
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
                              | `Put (k, _) | `Delete k | `Mkdir k | `Rmdir k ->
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
                          Fs.rename_directory ~src_prefix:(src_key ^ "/")
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
      let touched_keys = Hashtbl.fold (fun k () acc -> k :: acc) touched [] in
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
    let prompt_bool msg =
      Printf.printf "%s [y/N]: %!" msg;
      match String.lowercase_ascii (read_line ()) with
        | "y" | "yes" -> true
        | _ -> false
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
    let prompt_backend () =
      let backend_type = prompt "  Backend type (s3/local)" (Some "s3") in
      match backend_type with
        | "local" ->
            let path = prompt "  Local path" None in
            `Assoc [("type", `String "local"); ("path", `String path)]
        | _ ->
            let bucket = prompt "  S3 bucket" None in
            let region = prompt "  AWS region" (Some "us-east-1") in
            let access_key_id = prompt "  AWS Access Key ID" None in
            let secret_access_key = read_password "  AWS Secret Access Key" in
            `Assoc
              [
                ("type", `String "s3");
                ("bucket", `String bucket);
                ("region", `String region);
                ("accessKeyId", `String access_key_id);
                ("secretAccessKey", `String secret_access_key);
              ]
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
      let backends = prompt_backends () in
      `Assoc
        [
          ("name", `String name);
          ("prefix", `String key_prefix);
          ("backends", `List backends);
        ]
    in
    Printf.printf "tsync configuration\n-------------------\n";
    let versioning = prompt_bool "Enable versioning (trash on delete)?" in
    let domains = ref [] in
    let continue_ = ref true in
    while !continue_ do
      Printf.printf "\nDomain %d\n" (List.length !domains + 1);
      domains := !domains @ [prompt_domain ()];
      continue_ := prompt_bool "Add another domain?"
    done;
    let config_path = runtime_paths.Runtime.config_path in
    mkdir_p (Filename.dirname config_path);
    let json =
      `Assoc
        [
          ("versioning", `Bool versioning);
          ("domains", `List !domains);
        ]
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

(* ── Main ────────────────────────────────────────────────────────────────── *)

let () =
  let cmd =
    Cmd.group
      (Cmd.info "tsync" ~doc:"S3-backed filesystem sync")
      [
        configure_cmd;
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
