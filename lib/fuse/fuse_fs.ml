open Lwt.Syntax

module Make (C : Conf.S) = struct
  module E = Domain_engine.Make (C)
  module Sq = E.Sq
  module F = E.F
  module Ih = E.Ih
  module Sp = E.Sp
  module Fs = File_store.Make (C)
  module H = Hidden_ops.Make (C)
  module I = Internal_ops.Make (F)

  (* ── Full-file storage policy ─────────────────────────────────────────────
     Files persist in the local cache. Eviction is deferred while a file has
     open handles; a dirty file is queued for upload on last close.

     All File operations run on the single Lwt event-loop thread. FUSE runs
     Multi_threaded; each handler bridges into that loop with
     [Lwt_preemptive.run_in_main], so a slow operation blocks only its own
     kernel thread while other operations keep making progress on the loop. *)

  (* ── Path helpers ─────────────────────────────────────────────────────── *)

  let fuse_to_key path =
    let rel =
      if path = "/" then "" else String.sub path 1 (String.length path - 1)
    in
    C.domain_prefix ^ rel

  let fuse_to_dir_prefix path = Key.ensure_slash (fuse_to_key path)

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

  (* Deliberately unbounded: if the stop sequence wedges, hanging is the correct
     behaviour. Whatever supervises the process is what notices — it gives up on
     its own stop timeout, kills us and reports the unit as failed, which someone
     sees. Giving up on a timer of our own would abandon exactly the pending work
     a kill does, only quietly and with an exit status saying all was well. The
     individual steps that wait on something remote carry their own bounds
     ({!Backfill_backend.drain_all}); a hang here means something is stuck that is
     not supposed to be. *)
  let stop_t, stop_wake = Lwt.wait ()

  let do_stop () =
    match Lwt.state stop_t with
      | Lwt.Sleep -> Lwt.wakeup_later stop_wake ()
      | _ -> ()

  (* [Fuse.main] holds the main thread until the mount is gone, so a stop asked
     for from the inside has to unmount as well or the process would drain and
     then sit there. Set only in that case: when the FUSE loop exits on its own
     (a manual [fusermount -u], or libfuse acting on a signal itself) the mount is
     already gone and unmounting again would only warn. *)
  let unmount_needed = ref false

  let request_stop () =
    unmount_needed := true;
    do_stop ()

  (* How the main thread asks the Lwt thread to stop once [Fuse.main] has
     returned. It cannot use [Lwt_preemptive.run_in_main] for this: that blocks
     until the loop picks the job up, and by then the loop may already have
     finished — the main thread would then wait forever on a loop that will never
     run again. A notification is delivered by the engine, is safe to send from
     any thread, and is a no-op if the loop is already gone. *)
  let stop_notification = ref None

  let notify_stop_from_main () =
    match !stop_notification with
      | Some n -> ( try Lwt_unix.send_notification n with _ -> ())
      | None -> ()

  (* Released on the Lwt side rather than from a thread: [Lwt_process] reaps the
     child through the event loop, so nothing is blocked waiting on it, and the
     process cannot reach [exit] with the unmount still pending because the
     shutdown sequence awaits it. No shell, so the mount path needs no quoting.
     The short delay lets the IPC [stop] reply reach its caller before the mount
     it is talking about disappears. *)
  let unmount mount_point =
    if not !unmount_needed then Lwt.return_unit
    else
      let* () = Lwt_unix.sleep 0.1 in
      let+ status =
        Lwt_process.exec ("", [| "fusermount3"; "-u"; mount_point |])
      in
      match status with
        | Unix.WEXITED 0 -> ()
        (* A mount that stays up leaves [Fuse.main] blocked for good, so this
           warning is the only notice anyone gets. *)
        | Unix.WEXITED n ->
            Log.warn "fusermount3 -u %s exited %d; it may still be mounted"
              mount_point n
        | Unix.WSIGNALED n | Unix.WSTOPPED n ->
            Log.warn "fusermount3 -u %s killed by signal %d" mount_point n

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

  (* Directories exist only in the manifest mirror, so that is what decides
     whether a key names one. *)
  let is_dir_key key =
    Key.is_dir key
    ||
    let mp = F.manifest_path key in
    Sys.file_exists mp && Sys.is_directory mp

  (* Evict and restore both apply to a whole subtree when given a directory. One
     file's failure must not abort the rest. *)
  let on_subtree what f key =
    if not (is_dir_key key) then f key
    else (
      let prefix = Key.ensure_slash key in
      let* files = F.list_tree ~prefix in
      Lwt_list.iter_s
        (fun (e : Backend.file_entry) ->
          Lwt.catch
            (fun () -> f e.key)
            (fun exn ->
              Log.err "%s %s: %s" what e.key (Printexc.to_string exn);
              Lwt.return_unit))
        files)

  let evict_key = on_subtree "evict" F.evict
  let restore_key = on_subtree "restore" F.ensure_cached

  (* The mirror is cleared and rebuilt by the [sync --full] client before it
     signals us; FUSE re-reads the fresh mirror on the next lookup, so there is
     nothing destructive to do here. *)
  let full_resync () = Lwt.return_unit

  let ipc_hooks mount_point =
    Ih.
      {
        path_to_key = key_of_path mount_point;
        evict = evict_key;
        restore = restore_key;
        changed = (fun _ -> ());
        full_resync;
        status_fields = (fun () -> [("mount", `String mount_point)]);
        stats_fields = E.stats_fields;
        on_stop = (fun () -> request_stop ());
      }

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
              let+ files, dirs =
                F.list_children ~prefix:(fuse_to_dir_prefix path)
              in
              let names =
                List.map
                  (fun (e : Backend.file_entry) ->
                    Filename.basename e.Backend.key)
                  files
                @ List.map fst dirs
              in
              List.map entry_of_name ("." :: ".." :: names)));
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
      (* Nothing is buffered per-fd: a write lands in a staged chunk body before
         it returns, and there is no long-lived handle to sync. Both must still
         succeed rather than report ENOSYS — an app that fsyncs its own file must
         not see an error. *)
      flush = (fun _path _fi -> ());
      fsync = (fun _path _datasync _fi -> ());
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

  let mount ?(allow_other = false) mount_point =
    (* An exception escaping through Lwt.async (e.g. a socket error in a
       library's background loop) must not take down the daemon or, worse,
       leave it half-dead. Log and keep serving. *)
    (Lwt.async_exception_hook :=
       fun exn -> Log.err "async exception: %s" (Printexc.to_string exn));
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
               E.start
                 ~on_cursor:(fun ~entry_key -> set_pending_cursor entry_key)
                 ~on_upload_done:(fun ~key ->
                   Ipc.notify_uploaded ~path:C.notify_path key;
                   Lwt.return_unit)
                 ()
             in
             Log.debug "starting cursor flusher";
             Lwt.async cursor_flusher;
             Log.debug "starting IPC server at %s" C.socket_path;
             Lwt.async (fun () ->
                 Ipc.serve ~path:C.socket_path
                   (Ih.handler (ipc_hooks mount_point)));
             (* A supervisor is expected to stop this group with [tsync stop], but
                a plain SIGTERM reaches it too — from the supervisor if that call
                fails or if it only ever signals, and always from the parent
                process when this frontend was forked. libfuse
                installs its own handlers in [Fuse.main] and would override
                these; that route exits the FUSE loop, which drains below just
                the same, so whichever handler wins the queue is flushed. This is
                here for the case where it does not install any, where the
                default action would kill the process mid-queue. *)
             List.iter
               (fun s ->
                 ignore (Lwt_unix.on_signal s (fun _ -> request_stop ())))
               [Sys.sigterm; Sys.sigint];
             (* Set before [signal_ready], so the main thread is guaranteed to
                see it once it is past [wait_ready]. *)
             stop_notification := Some (Lwt_unix.make_notification do_stop);
             signal_ready ();
             let* () = stop_t in
             (* Concurrently: the unmount is what lets the main thread out of
                [Fuse.main] so it can join this one, and it must not wait behind
                the drain. Both are awaited before this thread ends. *)
             let unmount_t = unmount mount_point in
             Log.debug "draining upload queue and backends";
             let* () = E.drain () in
             unmount_t))
        ()
    in
    wait_ready ();
    Log.info "mounting FUSE at %s" mount_point;
    (* [allow_other] lets other users (e.g. a media server running as its own
       service account) reach the mount; it also needs [user_allow_other] in
       /etc/fuse.conf. *)
    let opts =
      (if C.read_only then ["ro"] else [])
      @ if allow_other then ["allow_other"] else []
    in
    let mount_args =
      Array.of_list
        (["tsync"; mount_point]
        @ match opts with [] -> [] | _ -> ["-o"; String.concat "," opts])
    in
    Fuse.main ~loop_mode:Fuse.Multi_threaded mount_args
      (make_operations mount_point);
    Log.debug "FUSE loop exited, stopping services";
    (* The loop may have exited because something asked us to stop, or on its own
       (a manual unmount). Either way this is what releases the Lwt side, and it
       has already happened in the first case. *)
    notify_stop_from_main ();
    Thread.join lwt_thread;
    try Unix.unlink C.socket_path with _ -> ()
end
