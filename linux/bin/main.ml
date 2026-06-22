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
  let store =
    S3_store.make ~client ~domain_name ~domain_prefix ~chunk_prefix
      ~trash_prefix ~versioning:cfg.Config.versioning
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
    Log.init ();
    let ctx =
      Fuse_fs.
        {
          store;
          domain_name;
          domain_prefix = S3_store.domain_prefix store;
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
    let prefix = S3_store.domain_prefix store in
    let all =
      S3_client.list_all
        ( S3_store.domain_prefix store |> fun _ ->
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
      let dp = S3_store.domain_prefix store in
      if dir = mount_point then dp else dp ^ Filename.basename dir ^ "/"
    in
    let files, subdirs = S3_store.list_directory store ~prefix in
    let domain_prefix = S3_store.domain_prefix store in
    let dp_len = String.length domain_prefix in
    List.iter
      (fun (e : S3_client.file_entry) ->
        let name =
          if String.length e.key > dp_len then
            String.sub e.key dp_len (String.length e.key - dp_len)
          else e.key
        in
        let cached = Cache.is_cached ~domain_name ~domain_prefix e.key in
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

(* ── Main ────────────────────────────────────────────────────────────────── *)

let () =
  let cmd =
    Cmd.group
      (Cmd.info "tsync" ~doc:"S3-backed FUSE filesystem sync")
      [
        start_cmd;
        stop_cmd;
        status_cmd;
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
