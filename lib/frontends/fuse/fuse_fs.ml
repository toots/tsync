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

  (* FUSE runs Multi_threaded while all File operations run on the single Lwt
     event-loop thread, so each handler bridges with [Lwt_preemptive.run_in_main]
     and a slow operation blocks only its own kernel thread. *)
  let fuse_to_key path =
    let rel =
      if path = "/" then "" else String.sub path 1 (String.length path - 1)
    in
    C.domain_prefix ^ rel

  let fuse_to_dir_prefix path = Key.ensure_slash (fuse_to_key path)

  (* The FUSE kernel creates .fuse_hidden* files when renaming a file with open
     descriptors. Kernel-internal: never mirror to the backend. *)
  let is_fuse_hidden path =
    let basename = Filename.basename path in
    let prefix = ".fuse_hidden" in
    String.length basename >= String.length prefix
    && String.sub basename 0 (String.length prefix) = prefix

  (* Counted at the FUSE boundary because nothing below sees these numbers: a
     read served from the chunk cache never reaches a backend, so {!Metrics} stays
     at zero while a mount streams gigabytes. Incremented inside [on_loop], on the
     event-loop thread, so plain ints suffice. *)
  let open_handles = ref 0
  let files_opened = ref 0

  (* Rolling rate as well as total: a total cannot say whether the mount is
     streaming right now. *)
  let read_bytes = Metrics.counter ()
  let written_bytes = Metrics.counter ()

  let fuse_stats_fields () =
    [
      ("openHandles", `Int !open_handles);
      ("filesOpened", `Int !files_opened);
      ("bytesRead", `Int (Metrics.total read_bytes));
      ("bytesWritten", `Int (Metrics.total written_bytes));
      ("bytesReadPerSec", `Int (int_of_float (Metrics.rate read_bytes)));
      ("bytesWrittenPerSec", `Int (int_of_float (Metrics.rate written_bytes)));
    ]

  let guard op path f =
    try f () with
      | Unix.Unix_error _ as e -> raise e
      | exn ->
          Log.err "fuse %s %s: unexpected exception: %s" op path
            (Printexc.to_string exn);
          raise (Unix.Unix_error (Unix.EIO, op, path))

  (* Called from FUSE worker threads, never the loop thread itself. *)
  let on_loop f = Lwt_preemptive.run_in_main f

  (* Deliberately unbounded: a wedged stop should hang so the supervisor's own
     timeout kills us and reports the unit failed. A timer of our own would
     abandon the same pending work, quietly and with an exit status saying all was
     well. Steps waiting on something remote carry their own bounds
     ({!Domain_store.drain}). *)
  let stop_t, stop_wake = Lwt.wait ()

  let do_stop () =
    match Lwt.state stop_t with
      | Lwt.Sleep -> Lwt.wakeup_later stop_wake ()
      | _ -> ()

  (* [Fuse.main] holds the main thread until the mount is gone, so a stop asked
     from the inside must unmount too or the process drains and then sits there.
     Set only in that case: when the FUSE loop exits on its own the mount is
     already gone and unmounting again would only warn. *)
  let unmount_needed = ref false

  let request_stop () =
    unmount_needed := true;
    do_stop ()

  (* [Lwt_preemptive.run_in_main] cannot be used here: it blocks until the loop
     picks the job up, and by then the loop may be finished, leaving the main
     thread waiting forever. A notification is engine-delivered, safe from any
     thread, and a no-op if the loop is already gone. *)
  let stop_notification = ref None

  let notify_stop_from_main () =
    match !stop_notification with
      | Some n -> ( try Lwt_unix.send_notification n with _ -> ())
      | None -> ()

  (* [Lwt_process] reaps the child through the event loop, so no thread blocks on
     it, and shutdown awaits this promise, so [exit] cannot happen with the
     unmount pending. It takes an argument array, so the mount path needs no
     quoting. The delay lets the IPC [stop] reply reach its caller first. *)
  let unmount mount_point =
    if not !unmount_needed then Lwt.return_unit
    else
      let* () = Lwt_unix.sleep 0.1 in
      let+ status =
        Lwt_process.exec ("", [| "fusermount3"; "-u"; mount_point |])
      in
      match status with
        | Unix.WEXITED 0 -> ()
        (* A mount that stays up leaves [Fuse.main] blocked for good, so this is
           the only notice anyone gets. *)
        | Unix.WEXITED n ->
            Log.warn "fusermount3 -u %s exited %d; it may still be mounted"
              mount_point n
        | Unix.WSIGNALED n | Unix.WSTOPPED n ->
            Log.warn "fusermount3 -u %s killed by signal %d" mount_point n

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

  (* Directories exist only in the manifest mirror. *)
  let is_dir_key key =
    Key.is_dir key
    ||
    let mp = F.manifest_path key in
    Sys.file_exists mp && Sys.is_directory mp

  (* Given a directory, both apply to the whole subtree; one file's failure must
     not abort the rest. *)
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

  (* The [sync --full] client clears and rebuilds the mirror before signalling
     us, and FUSE re-reads it on the next lookup. *)
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
        (* A domain can run several frontends, each its own process with its own
           counters, so the numbers have to name themselves. *)
        stats_fields =
          (fun () ->
            ("frontend", `String "fuse")
            :: ("mountPoint", `String mount_point)
            :: fuse_stats_fields ()
            @ E.stats_fields ());
        on_stop = (fun () -> request_stop ());
      }

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
              (* Files and directories are two listings of one namespace, and a
                 name can land in both -- a file key and a folder marker that
                 share it. Concatenated, the directory then returns that name
                 twice, which no caller is prepared for: `ls` prints it twice
                 and anything building a map from the listing loses one silently.
                 A stress run caught a mount doing exactly this.

                 Whatever produced the collision is upstream of here and is not
                 something readdir can repair, so it is logged rather than
                 quietly absorbed. What readdir owes its caller either way is a
                 listing with each name once. *)
              let names =
                let seen = Hashtbl.create 16 in
                List.filter
                  (fun n ->
                    if Hashtbl.mem seen n then begin
                      Log.warn "readdir %s: %S is both a file and a directory"
                        path n;
                      false
                    end
                    else begin
                      Hashtbl.add seen n ();
                      true
                    end)
                  names
              in
              List.map entry_of_name ("." :: ".." :: names)));
      mknod =
        (fun path mode ->
          guard "mknod" path (fun () ->
              on_loop (fun () -> (dispatch path).mknod path mode)));
      (* Inside [on_loop], so it runs on the event-loop thread and only on
         success. *)
      fopen =
        (fun path fi ->
          guard "fopen" path (fun () ->
              on_loop (fun () ->
                  let+ update = (dispatch path).fopen path fi in
                  incr open_handles;
                  incr files_opened;
                  update)));
      read =
        (fun path buf offset fi ->
          guard "read" path (fun () ->
              on_loop (fun () ->
                  let+ n = (dispatch path).read path buf offset fi in
                  Metrics.count read_bytes n;
                  n)));
      write =
        (fun path buf offset fi ->
          guard "write" path (fun () ->
              on_loop (fun () ->
                  let+ n = (dispatch path).write path buf offset fi in
                  Metrics.count written_bytes n;
                  n)));
      release =
        (fun path fi ->
          guard "release" path (fun () ->
              on_loop (fun () ->
                  let+ () = (dispatch path).release path fi in
                  (* A release without a matching fopen (a handle inherited
                     across a remount) must not drive the gauge negative. *)
                  if !open_handles > 0 then decr open_handles)));
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
      (* The store has no size, but a write lands on the cache filesystem before
         it is uploaded, so report that one: what df shows is then the space a
         write can actually use. Inode counts stay nominal — nothing here maps to
         one. One statvfs, no cache walk, since df-alikes poll this. *)
      statfs =
        (fun _path ->
          let bsize = 4096L in
          let blocks bytes = Int64.div bytes bsize in
          let total, avail =
            match Fs_util.disk_space C.cache_root with
              | Some (avail, total) -> (blocks total, blocks avail)
              | None -> (0L, 0L)
          in
          Unix_util.
            {
              f_bsize = bsize;
              f_frsize = bsize;
              f_blocks = total;
              f_bfree = avail;
              f_bavail = avail;
              f_files = Int64.of_int max_int;
              f_ffree = Int64.of_int max_int;
              f_favail = Int64.of_int max_int;
              f_fsid = 0L;
              f_flag = 0L;
              f_namemax = 255L;
            });
      utimens = (fun _path _atime _mtime _fi -> ());
      (* Object storage has no POSIX mode/owner: getattr synthesizes them and
         they are not persisted. Accepted rather than ENOSYS because rsync's
         do_mkstemp() fchmod()s its temp file, and an unimplemented chmod surfaces
         as a spurious "mkstemp failed". *)
      chmod = (fun _path _mode _fi -> ());
      chown = (fun _path _uid _gid _fi -> ());
      (* Nothing is buffered per-fd: a write lands in a staged chunk body before
         returning. Still must succeed rather than ENOSYS, or an app fsyncing its
         own file sees an error. *)
      flush = (fun _path _fi -> ());
      fsync = (fun _path _datasync _fi -> ());
    }

  (* The event loop runs on a thread of its own here, and every FUSE handler
     reaches it through [Lwt_preemptive.run_in_main]. An exception escaping
     [Lwt_main.run] therefore does not stop the process: it leaves one with no
     loop, in which every filesystem call blocks on a thread that is gone, and
     nothing reports it until a stop is attempted and hangs. One of these sat
     silent for 47 minutes after an SSL read raised inside libev's dispatch --
     outside any promise, so neither [Lwt.catch] nor {!Lwt.async_exception_hook}
     could see it.

     There is nothing to recover to, so the process ends at once and says why; a
     supervisor restarts it in seconds. [Unix._exit], because at_exit handlers
     would drain through the loop that just died, which is the wedge again. *)
  let loop_died exn =
    Log.err "event loop stopped: %s\n%s" (Printexc.to_string exn)
      (Printexc.get_backtrace ());
    flush stdout;
    flush stderr;
    Unix._exit 1

  let mount ?(allow_other = false) mount_point =
    (* An exception escaping through Lwt.async (a socket error in a library's
       background loop) must not take down the daemon or leave it half-dead. *)
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
          match
            Lwt_main.run
              (let* () =
               (* A FUSE mount is the filesystem, so a finished upload changes
                  nothing a reader can observe. *)
               E.start
                 ~freshness:
                   (* This mount has to be told. [cache_opts] turns off the
                      attribute and entry timeouts, which is why a re-lookup
                      sees fresh data -- but it does not stop the kernel
                      answering a lookup from a dentry it already holds, and a
                      name another client renamed away stays resolvable in a
                      directory already open. Claiming {!Frontend.Revalidates}
                      was claiming a coherence the mount did not have.

                      Pushing an invalidation is the part that was missing, not
                      a shorter timeout. *)
                   (Frontend.Notify
                      (fun key ->
                        (* Backend key to the path this mount shows. A key
                           outside the domain is not ours to invalidate. *)
                        let rel =
                          Key.chop_slash
                            (Key.strip_prefix ~domain_prefix:C.domain_prefix key)
                        in
                        (* Never from inside an operation on this path: the
                           kernel waits on the request, and the invalidation
                           waits on the kernel. This runs on the event loop,
                           which is not a FUSE thread. *)
                        try Fuse.invalidate_path ("/" ^ rel)
                        with Unix.Unix_error (e, _, _) ->
                          (* The kernel not holding it is the state we wanted;
                             anything else the mount cannot fix, and silence
                             here is a stale name nobody can account for. *)
                          Log.debug "invalidate %s: %s" rel
                            (Unix.error_message e)))
                 ~on_upload_done:(fun ~key:_ -> Lwt.return_unit)
                 ()
             in
             Log.debug "starting IPC server at %s" C.socket_path;
             Lwt.async (fun () ->
                 Ipc.serve ~path:C.socket_path
                   (Ih.handler (ipc_hooks mount_point)));
             (* A plain SIGTERM reaches this group too: from a supervisor that
                only signals, and always from the parent when this frontend was
                forked. libfuse may install its own handlers in [Fuse.main] and
                override these, but that route exits the FUSE loop and drains just
                the same. This covers the case where it installs none, where the
                default action would kill the process mid-queue. *)
             List.iter
               (fun s ->
                 ignore (Lwt_unix.on_signal s (fun _ -> request_stop ())))
               [Sys.sigterm; Sys.sigint];
             (* Before [signal_ready], so the main thread sees it once past
                [wait_ready]. *)
             stop_notification := Some (Lwt_unix.make_notification do_stop);
             signal_ready ();
             let* () = stop_t in
             (* Concurrent: the unmount is what lets the main thread out of
                [Fuse.main] to join this one, so it must not wait behind the
                drain. *)
             let unmount_t = unmount mount_point in
             Log.debug "draining upload queue and backends";
               let* () = E.drain () in
               unmount_t)
          with
            | () -> ()
            | exception exn -> loop_died exn)
        ()
    in
    wait_ready ();
    Log.info "mounting FUSE at %s" mount_point;
    (* [allow_other] lets other users reach the mount; it also needs
       [user_allow_other] in /etc/fuse.conf. *)
    (* The kernel's own caches, turned off.

       They assume this filesystem changes only through the kernel's own calls,
       which is false the moment a second client shares the domain: a rename
       made elsewhere left the old name in the dentry cache, listed but no longer
       openable, and the new one invisible -- until the mount was taken down.
       Nothing invalidated them, because libfuse's high-level API offers no way
       to; [fuse_lowlevel_notify_inval_entry] is not reachable from this binding.

       So freshness is bought by re-asking: a LOOKUP per path access rather than
       one per timeout. That is the standing cost of {!Frontend.Revalidates}
       here, and the reason to want a lowlevel binding is to stop paying it.

       It buys resolution, not enumeration. A name another client has since
       created or moved now resolves correctly -- opening it works where it used
       to fail -- but the kernel's cached listing of a directory is not covered
       by these timeouts, and this API cannot invalidate it either, so a stale
       readdir survives until the directory is opened afresh. Closing that needs
       [fuse_lowlevel_notify_inval_entry], which means a lowlevel binding; the
       directory's mtime already moves when a foreign change lands, so the
       signal a smarter cache would need is there. *)
    let cache_opts =
      ["entry_timeout=0"; "attr_timeout=0"; "negative_timeout=0"; "auto_cache"]
    in
    let opts =
      (if C.read_only then ["ro"] else [])
      @ (if allow_other then ["allow_other"] else [])
      @ cache_opts
    in
    let mount_args =
      Array.of_list
        (["tsync"; mount_point]
        @ match opts with [] -> [] | _ -> ["-o"; String.concat "," opts])
    in
    Fuse.main ~loop_mode:Fuse.Multi_threaded mount_args
      (make_operations mount_point);
    Log.debug "FUSE loop exited, stopping services";
    (* The loop may have exited on request or on its own (a manual unmount).
       Either way this releases the Lwt side; in the first case it already
       happened. *)
    notify_stop_from_main ();
    Thread.join lwt_thread;
    try Unix.unlink C.socket_path with _ -> ()
end
