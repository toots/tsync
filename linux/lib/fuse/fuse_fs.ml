module Make (C : Conf.S) = struct
  module Sq = Sync_queue.Make (C)
  module F = File.Make (C) (Sq)
  module Fs = File_store.Make (C)
  module H = Hidden_ops.Make (F)
  module I = Internal_ops.Make (F)
  module Ih = Ipc_handler.Make (C) (F)

  (* ── Full-file storage policy ─────────────────────────────────────────────
     Files persist in the local cache. Eviction is deferred while a file has
     open handles; a dirty file is queued for upload on last close. *)

  let open_count : (string, int) Hashtbl.t = Hashtbl.create 64
  let open_count_mutex = Mutex.create ()
  let pending_evict : (string, unit) Hashtbl.t = Hashtbl.create 16
  let pending_evict_mutex = Mutex.create ()

  let open_file key =
    Mutex.lock open_count_mutex;
    let n = Option.value ~default:0 (Hashtbl.find_opt open_count key) in
    Hashtbl.replace open_count key (n + 1);
    Mutex.unlock open_count_mutex

  let close_file key =
    Mutex.lock open_count_mutex;
    let n = Option.value ~default:0 (Hashtbl.find_opt open_count key) in
    let n' = max 0 (n - 1) in
    if n' = 0 then Hashtbl.remove open_count key
    else Hashtbl.replace open_count key n';
    Mutex.unlock open_count_mutex;
    if n' = 0 then
      if F.is_dirty key then begin
        F.clear_dirty key;
        F.queue_put key
      end
      else begin
        Mutex.lock pending_evict_mutex;
        let was_pending = Hashtbl.mem pending_evict key in
        Hashtbl.remove pending_evict key;
        Mutex.unlock pending_evict_mutex;
        if was_pending then F.evict key
      end

  let request_evict key =
    Mutex.lock open_count_mutex;
    let count = Option.value ~default:0 (Hashtbl.find_opt open_count key) in
    Mutex.unlock open_count_mutex;
    if count = 0 then F.evict key
    else begin
      Mutex.lock pending_evict_mutex;
      Hashtbl.replace pending_evict key ();
      Mutex.unlock pending_evict_mutex
    end

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
     has open file descriptors. These are kernel-internal; never mirror to backend. *)
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

  let evict_key key =
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
              request_evict (C.domain_prefix ^ rel)
            end)
          (try Sys.readdir dir with _ -> [||])
      in
      walk lp
    end
    else request_evict key

  let restore_key key =
    let lp = F.local_path key in
    let is_dir =
      (String.length key > 0 && key.[String.length key - 1] = '/')
      || (Sys.file_exists lp && Sys.is_directory lp)
    in
    if is_dir then begin
      let prefix =
        if String.length key > 0 && key.[String.length key - 1] = '/' then key
        else key ^ "/"
      in
      let files = Fs.list_all_files ~prefix in
      List.iter
        (fun (e : Backend.file_entry) ->
          try F.ensure_cached e.key
          with exn -> Log.err "restore %s: %s" e.key (Printexc.to_string exn))
        files
    end
    else F.ensure_cached key

  let full_resync () =
    let rec walk dir =
      if Sys.file_exists dir then
        Array.iter
          (fun name ->
            let p = Filename.concat dir name in
            if Sys.is_directory p then walk p
            else (try Unix.unlink p with _ -> ()))
          (try Sys.readdir dir with _ -> [||])
    in
    walk C.cache_root

  let ipc_hooks mount_point =
    Ih.
      {
        path_to_key = key_of_path mount_point;
        request_evict = evict_key;
        restore = restore_key;
        full_resync;
        status_fields = (fun () -> [("mount", `String mount_point)]);
        on_stop =
          (fun () ->
            ignore
              (Thread.create
                 (fun () ->
                   Unix.sleepf 0.1;
                   ignore
                     (Sys.command
                        (Printf.sprintf "fusermount3 -u %s" mount_point)))
                 ()));
      }

  (* ── FUSE operations ──────────────────────────────────────────────────── *)

  let make_operations mount_point =
    let open Fuse in
    let hidden = H.make ~fuse_to_key in
    let real = I.make ~fuse_to_key ~open_file ~close_file in
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
    Log.debug "auto-evict: %b" (Ipc.auto_evict_enabled ~data_dir:C.data_dir);
    Log.debug "starting sync queue workers";
    Sq.start
      ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
      ~on_version:(fun ~entry_key -> set_pending_version entry_key)
      ~on_upload_done:(fun ~key ->
        if Ipc.auto_evict_enabled ~data_dir:C.data_dir then request_evict key;
        Ipc.notify_uploaded ~path:C.notify_path key);
    Log.debug "starting IPC server at %s" C.socket_path;
    let _ipc_thread =
      Thread.create
        (fun () ->
          Ipc.serve ~path:C.socket_path (Ih.handler (ipc_hooks mount_point)))
        ()
    in
    Log.debug "starting version flusher";
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
    Log.info "mounting FUSE at %s" mount_point;
    Fuse.main ~loop_mode:Fuse.Single_threaded [| "tsync"; mount_point |]
      (make_operations mount_point);
    Log.debug "FUSE loop exited, draining upload queue";
    Sq.drain ()
end
