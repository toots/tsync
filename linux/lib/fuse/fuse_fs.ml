module Make (C : Conf.S) = struct
  module Sq = Sync_queue.Make (C)
  module F = File.Make (C) (Sq)
  module Fs = File_store.Make (C)
  module H = Hidden_ops.Make (F)
  module I = Internal_ops.Make (F)

  (* ── Path helpers ─────────────────────────────────────────────────────── *)

  let fuse_to_key path =
    let rel =
      if path = "/" then "" else String.sub path 1 (String.length path - 1)
    in
    C.domain_prefix ^ rel

  let fuse_to_dir_prefix path =
    let key = fuse_to_key path in
    if key = C.domain_prefix then key
    else if String.length key > 0 && key.[String.length key - 1] = '/' then key
    else key ^ "/"

  (* ── The FUSE kernel creates .fuse_hidden* files when renaming a file that
     has open file descriptors. These are kernel-internal; never mirror to S3. *)
  let is_fuse_hidden path =
    let basename = Filename.basename path in
    let prefix = ".fuse_hidden" in
    String.length basename >= String.length prefix
    && String.sub basename 0 (String.length prefix) = prefix

  (* ── Exception guard ──────────────────────────────────────────────────── *)

  let guard op path f =
    try f () with
      | Unix.Unix_error _ as e -> raise e
      | exn ->
          Log.err "fuse %s %s: unexpected exception: %s" op path
            (Printexc.to_string exn);
          raise (Unix.Unix_error (Unix.EIO, op, path))

  (* ── Journal WAL helpers ──────────────────────────────────────────────── *)

  let pending_version_key : string option ref = ref None
  let pending_version_mutex = Mutex.create ()

  let set_pending_version ek =
    Mutex.lock pending_version_mutex;
    (match !pending_version_key with
      | Some prev when prev >= ek -> ()
      | _ -> pending_version_key := Some ek);
    Mutex.unlock pending_version_mutex

  let drain_pending_version () =
    Mutex.lock pending_version_mutex;
    let v = !pending_version_key in
    pending_version_key := None;
    Mutex.unlock pending_version_mutex;
    v

  (* ── IPC ──────────────────────────────────────────────────────────────── *)

  let key_of_path mount_point path =
    let path =
      if String.length path >= 2 && path.[0] = '~' && path.[1] = '/' then
        Sys.getenv "HOME" ^ String.sub path 1 (String.length path - 1)
      else path
    in
    if
      String.length path > String.length mount_point
      && String.sub path 0 (String.length mount_point) = mount_point
    then
      fuse_to_key
        (String.sub path
           (String.length mount_point)
           (String.length path - String.length mount_point))
    else fuse_to_key path

  let ipc_handler mount_point line =
    match Ipc.parse_command line with
      | Evict arg ->
          let key = key_of_path mount_point arg in
          let lp = F.local_path key in
          if Sys.file_exists lp && Sys.is_directory lp then begin
            let rec walk dir =
              Array.iter
                (fun name ->
                  let p = Filename.concat dir name in
                  if Sys.is_directory p then walk p
                  else begin
                    let rel =
                      String.sub p
                        (String.length C.cache_root + 1)
                        (String.length p - String.length C.cache_root - 1)
                    in
                    F.request_evict (C.domain_prefix ^ rel)
                  end)
                (try Sys.readdir dir with _ -> [||])
            in
            walk lp
          end
          else F.request_evict key;
          "OK"
      | Restore arg ->
          let key = key_of_path mount_point arg in
          let lp = F.local_path key in
          let is_dir =
            (String.length key > 0 && key.[String.length key - 1] = '/')
            || (Sys.file_exists lp && Sys.is_directory lp)
          in
          if is_dir then begin
            let prefix =
              if String.length key > 0 && key.[String.length key - 1] = '/' then
                key
              else key ^ "/"
            in
            let files = Fs.list_all_files ~prefix in
            List.iter
              (fun (e : Backend.file_entry) ->
                try F.ensure_cached e.key
                with exn ->
                  Log.err "restore %s: %s" e.key (Printexc.to_string exn))
              files;
            "OK"
          end
          else (
            try
              F.ensure_cached key;
              "OK"
            with exn -> "ERROR " ^ Printexc.to_string exn)
      | Status ->
          Printf.sprintf {|STATUS {"mount":"%s","domain":"%s","running":true}|}
            mount_point C.domain_name
      | Stop ->
          let _ =
            Thread.create
              (fun () ->
                Unix.sleepf 0.1;
                ignore
                  (Sys.command (Printf.sprintf "fusermount3 -u %s" mount_point)))
              ()
          in
          "STOP"
      | Auto_evict arg -> (
          match arg with
            | "on" ->
                let p = Filename.concat C.data_dir "auto-evict" in
                F.auto_evict := true;
                (try close_out (open_out p) with _ -> ());
                "OK"
            | "off" ->
                let p = Filename.concat C.data_dir "auto-evict" in
                F.auto_evict := false;
                (try Unix.unlink p
                 with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
                "OK"
            | "status" -> if !F.auto_evict then "on" else "off"
            | _ -> "ERROR expected on|off|status")
      | Full_resync ->
          let rec walk dir =
            if Sys.file_exists dir then
              Array.iter
                (fun name ->
                  let p = Filename.concat dir name in
                  if Sys.is_directory p then walk p
                  else (try Unix.unlink p with _ -> ()))
                (try Sys.readdir dir with _ -> [||])
          in
          walk C.cache_root;
          "OK"
      | exception Failure msg -> msg

  (* ── FUSE operations ──────────────────────────────────────────────────── *)

  let make_operations mount_point =
    let open Fuse in
    let hidden = H.make ~fuse_to_key in
    let real = I.make ~fuse_to_key in
    let dispatch path = if is_fuse_hidden path then hidden else real in
    let entry_of_name name =
      {
        entry_name = name;
        entry_stats = None;
        entry_offset = None;
        entry_flags = { fill_dir_plus = false };
      }
    in
    {
      default_operations with
      init = (fun () -> ());
      getattr =
        (fun path _fi ->
          let key = fuse_to_key path in
          match F.stat key with
            | Some st -> st
            | None -> raise (Unix.Unix_error (Unix.ENOENT, "getattr", path)));
      readdir =
        (fun path _offset _fi _flags ->
          let key = fuse_to_dir_prefix path in
          let entries = F.list_dir key in
          List.map entry_of_name ("." :: ".." :: entries));
      mknod =
        (fun path mode ->
          guard "mknod" path (fun () -> (dispatch path).mknod path mode));
      fopen =
        (fun path fi ->
          guard "fopen" path (fun () -> (dispatch path).fopen path fi));
      read =
        (fun path buf offset fi ->
          guard "read" path (fun () -> (dispatch path).read path buf offset fi));
      write =
        (fun path buf offset fi ->
          guard "write" path (fun () ->
              (dispatch path).write path buf offset fi));
      release =
        (fun path fi ->
          guard "release" path (fun () -> (dispatch path).release path fi));
      unlink =
        (fun path ->
          guard "unlink" path (fun () -> (dispatch path).unlink path));
      mkdir =
        (fun path _mode ->
          guard "mkdir" path (fun () ->
              let key = fuse_to_dir_prefix path in
              F.mkdir key));
      rmdir =
        (fun path ->
          guard "rmdir" path (fun () ->
              let key = fuse_to_dir_prefix path in
              F.rmdir key));
      rename =
        (fun src dst flags ->
          guard "rename" src (fun () ->
              let is_hidden = is_fuse_hidden dst in
              (if is_hidden then hidden else real).rename src dst flags;
              if is_hidden then real.unlink src));
      truncate =
        (fun path size fi ->
          guard "truncate" path (fun () ->
              (dispatch path).truncate path size fi));
      statfs =
        (fun _path ->
          Unix_util.
            {
              f_bsize = 4096L;
              f_frsize = 4096L;
              f_blocks = Int64.of_int max_int;
              f_bfree = Int64.of_int max_int;
              f_bavail = Int64.of_int max_int;
              f_files = Int64.of_int max_int;
              f_ffree = Int64.of_int max_int;
              f_favail = Int64.of_int max_int;
              f_fsid = 0L;
              f_flag = 0L;
              f_namemax = 255L;
            });
      utimens = (fun _path _atime _mtime _fi -> ());
    }

  (* ── Main mount ───────────────────────────────────────────────────────── *)

  let mount mount_point =
    F.auto_evict := Sys.file_exists (Filename.concat C.data_dir "auto-evict");
    Sq.start
      ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
      ~on_version:set_pending_version
      ~on_upload_done:(fun ~key ->
        F.on_upload_done key;
        Ipc.notify_uploaded ~path:C.notify_path key);
    let _ipc_thread =
      Thread.create
        (fun () -> Ipc.serve ~path:C.socket_path (ipc_handler mount_point))
        ()
    in
    let _version_flusher =
      Thread.create
        (fun () ->
          while true do
            Unix.sleepf 2.0;
            match drain_pending_version () with
              | None -> ()
              | Some ek -> (
                  try Fs.bump_version ek
                  with exn ->
                    Log.err "bump_version: %s" (Printexc.to_string exn))
          done)
        ()
    in
    Fuse.main ~loop_mode:Fuse.Single_threaded [| "tsync"; mount_point |]
      (make_operations mount_point);
    Sq.drain ()
end
