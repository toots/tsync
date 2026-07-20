open Lwt.Syntax

module Make (C : Conf.S) = struct
  module Sq = Sync_queue.Make (C)
  module F = File.Make (C) (Sq)
  module Fs = File_store.Make (C)
  module H = Hidden_ops.Make (F)
  module Fd = Fd_cache.Make (F)
  module I = Internal_ops.Make (F)
  module Ih = Ipc_handler.Make (C) (F)
  module Sp = Sync_poller.Make (C) (F)

  (* ── Full-file storage policy ─────────────────────────────────────────────
     Files persist in the local cache. Eviction is deferred while a file has
     open handles; a dirty file is queued for upload on last close.

     All File operations run on the single Lwt event-loop thread. FUSE runs
     Multi_threaded; each handler bridges into that loop with
     [Lwt_preemptive.run_in_main], so a slow operation blocks only its own
     kernel thread while other operations keep making progress on the loop. *)

  let pending_evict : (string, unit) Hashtbl.t = Hashtbl.create 16

  let open_file key =
    F.mark_open key;
    Fd.acquire key

  let close_file key =
    let remaining = F.mark_closed key in
    let* () = Fd.release key in
    if remaining = 0 then
      if F.is_dirty key then begin
        F.clear_dirty key;
        F.queue_put key
      end
      else begin
        let was_pending = Hashtbl.mem pending_evict key in
        Hashtbl.remove pending_evict key;
        if was_pending then F.evict key else Lwt.return_unit
      end
    else Lwt.return_unit

  let request_evict key =
    if not (F.is_open key) then F.evict key
    else begin
      Hashtbl.replace pending_evict key ();
      Lwt.return_unit
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

  (* Run an Lwt computation on the event-loop thread and wait for its result.
     Called from FUSE worker threads (never the loop thread itself). *)
  let on_loop f = Lwt_preemptive.run_in_main f

  (* ── Journal WAL helpers ──────────────────────────────────────────────── *)

  let pending_cursor : string option ref = ref None

  let set_pending_cursor ek =
    match !pending_cursor with
      | Some prev when prev >= ek -> ()
      | _ -> pending_cursor := Some ek

  let drain_pending_cursor () =
    let v = !pending_cursor in
    pending_cursor := None;
    v

  (* ── Shutdown coordination ────────────────────────────────────────────── *)

  let stop_t, stop_wake = Lwt.wait ()

  let do_stop () =
    match Lwt.state stop_t with
      | Lwt.Sleep -> Lwt.wakeup_later stop_wake ()
      | _ -> ()

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
      let rec collect dir acc =
        Array.fold_left
          (fun acc name ->
            let p = Filename.concat dir name in
            if Sys.is_directory p then collect p acc
            else (
              let rel =
                String.sub p
                  (String.length C.cache_root + 1)
                  (String.length p - String.length C.cache_root - 1)
              in
              (C.domain_prefix ^ rel) :: acc))
          acc
          (try Sys.readdir dir with _ -> [||])
      in
      Lwt_list.iter_s request_evict (collect lp [])
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
      let* files = F.list_all_files ~prefix in
      Lwt_list.iter_s
        (fun (e : Backend.file_entry) ->
          Lwt.catch
            (fun () -> F.ensure_cached e.key)
            (fun exn ->
              Log.err "restore %s: %s" e.key (Printexc.to_string exn);
              Lwt.return_unit))
        files
    end
    else F.ensure_cached key

  (* The mirror is cleared and rebuilt by the [sync --full] client before it
     signals us; FUSE re-reads the fresh mirror on the next lookup, so there is
     nothing destructive to do here. *)
  let full_resync () = Lwt.return_unit

  let ipc_hooks mount_point =
    Ih.
      {
        path_to_key = key_of_path mount_point;
        request_evict = evict_key;
        restore = restore_key;
        changed = (fun _ -> ());
        full_resync;
        status_fields = (fun () -> [("mount", `String mount_point)]);
        stats_fields =
          (fun () ->
            [
              ("pendingUploads", `Int (Sq.pending ()));
              ("uploadsCompleted", `Int (Sq.completed_count ()));
            ]);
        on_stop =
          (fun () ->
            do_stop ();
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
    let real = I.make ~fuse_to_key ~open_file ~close_file ~fd_for:Fd.find in
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
          on_loop (fun () ->
              let* st = F.stat (fuse_to_key path) in
              match st with
                | Some st ->
                    let st =
                      if C.read_only then
                        {
                          st with
                          Unix.LargeFile.st_perm = st.st_perm land lnot 0o222;
                        }
                      else st
                    in
                    Lwt.return st
                | None ->
                    Lwt.fail (Unix.Unix_error (Unix.ENOENT, "getattr", path))));
      readlink =
        (fun path ->
          Lwt_preemptive.run_in_main (fun () ->
              let key = fuse_to_key path in
              let* target = F.readlink key in
              match target with
                | Some t -> Lwt.return t
                | None ->
                    Lwt.fail (Unix.Unix_error (Unix.EINVAL, "readlink", path))));
      symlink =
        (fun target path ->
          guard "symlink" path (fun () ->
              on_loop (fun () -> F.symlink ~target (fuse_to_key path))));
      readdir =
        (fun path _offset _fi _flags ->
          on_loop (fun () ->
              let+ entries = F.list_dir (fuse_to_dir_prefix path) in
              List.map entry_of_name ("." :: ".." :: entries)));
      mknod =
        (fun path mode ->
          guard "mknod" path (fun () ->
              on_loop (fun () -> (dispatch path).mknod path mode)));
      fopen =
        (fun path fi ->
          guard "fopen" path (fun () ->
              on_loop (fun () -> (dispatch path).fopen path fi)));
      read =
        (fun path buf offset fi ->
          guard "read" path (fun () ->
              on_loop (fun () -> (dispatch path).read path buf offset fi)));
      write =
        (fun path buf offset fi ->
          guard "write" path (fun () ->
              on_loop (fun () -> (dispatch path).write path buf offset fi)));
      release =
        (fun path fi ->
          guard "release" path (fun () ->
              on_loop (fun () -> (dispatch path).release path fi)));
      unlink =
        (fun path ->
          guard "unlink" path (fun () ->
              on_loop (fun () -> (dispatch path).unlink path)));
      mkdir =
        (fun path _mode ->
          guard "mkdir" path (fun () ->
              on_loop (fun () -> F.mkdir (fuse_to_dir_prefix path))));
      rmdir =
        (fun path ->
          guard "rmdir" path (fun () ->
              on_loop (fun () -> F.rmdir (fuse_to_dir_prefix path))));
      rename =
        (fun src dst flags ->
          guard "rename" src (fun () ->
              on_loop (fun () ->
                  let is_hidden = is_fuse_hidden dst in
                  let* () =
                    (if is_hidden then hidden else real).rename src dst flags
                  in
                  if is_hidden then real.unlink src else Lwt.return_unit)));
      truncate =
        (fun path size fi ->
          guard "truncate" path (fun () ->
              on_loop (fun () -> (dispatch path).truncate path size fi)));
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
      (* Object storage has no meaningful POSIX mode/owner — getattr synthesizes
         them and they aren't persisted. Accept and ignore rather than returning
         ENOSYS: rsync's do_mkstemp() fchmod()s the temp file, so an
         unimplemented chmod surfaces as a spurious "mkstemp failed". *)
      chmod = (fun _path _mode _fi -> ());
      chown = (fun _path _uid _gid _fi -> ());
      (* Writes go straight to the fd via direct_io + pwrite, so there is
         nothing buffered per-fd for flush to push. *)
      flush = (fun _path _fi -> ());
      fsync =
        (fun path _datasync _fi ->
          guard "fsync" path (fun () ->
              on_loop (fun () ->
                  match Fd.find (fuse_to_key path) with
                    | Some fd -> Lwt_unix_retry.fsync fd
                    | None -> Lwt.return_unit)));
    }

  (* ── Main mount ───────────────────────────────────────────────────────── *)

  let cursor_flusher () =
    let rec loop () =
      let* () = Lwt_unix.sleep 2.0 in
      let* () =
        match drain_pending_cursor () with
          | None -> Lwt.return_unit
          | Some ek ->
              Lwt.catch
                (fun () -> Fs.bump_cursor ek)
                (fun exn ->
                  Log.err "bump_cursor: %s" (Printexc.to_string exn);
                  Lwt.return_unit)
      in
      loop ()
    in
    loop ()

  let mount mount_point =
    (* An exception escaping through Lwt.async (e.g. a socket error in a
       library's background loop) must not take down the daemon or, worse,
       leave it half-dead. Log and keep serving. *)
    (Lwt.async_exception_hook :=
       fun exn -> Log.err "async exception: %s" (Printexc.to_string exn));
    Log.debug "auto-evict: %b" (Ipc.auto_evict_enabled ~data_dir:C.data_dir);
    let started = Mutex.create () in
    let started_cond = Condition.create () in
    let ready = ref false in
    let signal_ready () =
      Mutex.lock started;
      ready := true;
      Condition.broadcast started_cond;
      Mutex.unlock started
    in
    let wait_ready () =
      Mutex.lock started;
      while not !ready do
        Condition.wait started_cond started
      done;
      Mutex.unlock started
    in
    let lwt_thread =
      Thread.create
        (fun () ->
          Lwt_main.run
            (let* () =
               Local.init ~cache_root:C.cache_root ~domain_name:C.domain_name
             in
             Log.debug "starting sync queue workers";
             Sq.start
               ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
               ~on_cursor:(fun ~entry_key -> set_pending_cursor entry_key)
               ~on_upload_done:(fun ~key ->
                 let* () =
                   if Ipc.auto_evict_enabled ~data_dir:C.data_dir then
                     request_evict key
                   else Lwt.return_unit
                 in
                 Ipc.notify_uploaded ~path:C.notify_path key;
                 Lwt.return_unit);
             Log.debug "starting sync poller";
             Sp.start ();
             Log.debug "starting cursor flusher";
             Lwt.async cursor_flusher;
             Log.debug "starting IPC server at %s" C.socket_path;
             Lwt.async (fun () ->
                 Ipc.serve ~path:C.socket_path
                   (Ih.handler (ipc_hooks mount_point)));
             signal_ready ();
             let* () = stop_t in
             Log.debug "draining upload queue";
             Sq.drain ()))
        ()
    in
    wait_ready ();
    Log.info "mounting FUSE at %s" mount_point;
    let mount_args =
      if C.read_only then [| "tsync"; mount_point; "-o"; "ro" |]
      else [| "tsync"; mount_point |]
    in
    Fuse.main ~loop_mode:Fuse.Multi_threaded mount_args
      (make_operations mount_point);
    Log.debug "FUSE loop exited, stopping services";
    on_loop (fun () ->
        do_stop ();
        Lwt.return_unit);
    Thread.join lwt_thread;
    try Unix.unlink C.socket_path with _ -> ()
end
