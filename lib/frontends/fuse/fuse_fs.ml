open Lwt.Syntax

(* Carries the backtrace of a raise across [Lwt_preemptive.run_in_main], which
   re-raises on the calling thread and so replaces the backtrace of what
   actually failed with its own line. The exception value is the only thing
   that crosses, so the backtrace travels inside it. *)
exception With_backtrace of exn * Printexc.raw_backtrace

module Make (C : Conf.S) (D : Domain_engine.Domain) = struct
  module F = D.F
  module Ih = D.Ih
  module H = Hidden_ops.Make (C)
  module I = Internal_ops.Make (F)

  (* FUSE runs Multi_threaded while every File operation runs on the single Lwt
     event-loop thread, so each handler bridges with [Lwt_preemptive.run_in_main]
     and a slow operation blocks only its own kernel thread.

     Nothing is reported from there: the binding records what a handler raised
     and answers EIO, and formatting a message on a thread that has just failed
     is how the exception used to be lost. *)
  module Lk = Logical_key.Make (C)

  let fuse_to_key path = if path = "/" then Lk.root else Lk.file path
  let fuse_to_dir_prefix path = if path = "/" then Lk.root else Lk.dir path

  (* The FUSE kernel creates .fuse_hidden* files when renaming a file with open
     descriptors. Kernel-internal: never mirror to the backend. *)
  let is_fuse_hidden path =
    let basename = Filename.basename path in
    let prefix = ".fuse_hidden" in
    String.length basename >= String.length prefix
    && String.sub basename 0 (String.length prefix) = prefix

  (* Counted at the FUSE boundary because nothing below sees these numbers: a
     read served from the chunk cache never reaches a backend, so {!Metrics}
     stays at zero while a mount streams gigabytes. Incremented on the
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
      ("handlerFailures", `Int (Fuse.error_count ()));
    ]

  let on_loop f =
    Lwt_preemptive.run_in_main (fun () ->
        Lwt.catch f (function
          (* Matched before the capture rather than after: a [Unix_error] is an
             answer rather than a failure and wants no backtrace, matching
             cannot raise, and [getattr] answering ENOENT is the hot path. *)
          | Unix.Unix_error _ as exn -> Lwt.fail exn
          | exn ->
              let backtrace = Printexc.get_raw_backtrace () in
              Lwt.fail (With_backtrace (exn, backtrace))))

  (* What the binding recorded, logged from the loop rather than from the
     handler that failed.

     Polled because there is nothing to be notified by: recording a failure has
     to stay free of anything that can fail, which rules out waking a reader. *)
  let report_interval = 30.

  let rec report_recorded_failures last_seen =
    let* () = Lwt_unix.sleep report_interval in
    let fresh =
      List.filter
        (fun e -> e.Fuse.ticket >= last_seen)
        (Array.to_list (Fuse.recent_errors ()))
    in
    List.iter
      (fun e ->
        (* The wrapped backtrace is the raise itself; the binding's own is the
           crossing, and only worth having for handlers that do not cross. *)
        let exn, backtrace =
          match e.Fuse.exn with
            | With_backtrace (exn, raw) -> (exn, Some raw)
            | exn -> (exn, e.Fuse.backtrace)
        in
        Log.err "fuse %s %s: %s" e.Fuse.op e.Fuse.path (Printexc.to_string exn);
        match backtrace with
          | Some raw when Printexc.raw_backtrace_length raw > 0 ->
              Log.err "%s" (Printexc.raw_backtrace_to_string raw)
          | _ -> ())
      fresh;
    let last_seen =
      match List.rev fresh with e :: _ -> e.Fuse.ticket + 1 | [] -> last_seen
    in
    (* A count that outran the entries means the ring wrapped between polls, and
       the missing ones are gone rather than pending. *)
    let count = Fuse.error_count () in
    if count > last_seen then begin
      Log.err "fuse: %d handler failures went unreported" (count - last_seen);
      report_recorded_failures count
    end
    else report_recorded_failures last_seen

  (* Deliberately unbounded: a wedged stop should hang so the supervisor's own
     timeout kills us and reports the unit failed, where a timer of our own would
     abandon the same pending work with an exit status saying all was well.
     Steps waiting on something remote carry their own bounds
     ({!Domain_store.drain}). *)
  let stop_t, stop_wake = Lwt.wait ()

  let do_stop () =
    match Lwt.state stop_t with
      | Lwt.Sleep -> Lwt.wakeup_later stop_wake ()
      | _ -> ()

  (* [Fuse.main] holds the main thread until the mount is gone, so a stop asked
     from the inside must unmount too or the process drains and then sits there.
     Set only in that case: when the FUSE loop exits on its own the mount is
     already gone. *)
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

  let exit_status = function
    | Unix.WEXITED n -> Printf.sprintf "exited %d" n
    | Unix.WSIGNALED n -> Printf.sprintf "killed by signal %d" n
    | Unix.WSTOPPED n -> Printf.sprintf "stopped by signal %d" n

  (* [-u] refuses while anything still holds the mount, leaving every open
     descriptor valid; [-z] detaches from the tree regardless and lets those
     descriptors fail afterwards, which is only the right trade once the mount is
     going away anyway. *)
  let detach ?(lazily = false) mount_point =
    Lwt_process.exec
      ("", [| "fusermount3"; (if lazily then "-uz" else "-u"); mount_point |])

  (* Shutdown awaits this promise, so [exit] cannot happen with the unmount
     pending; the delay lets the IPC [stop] reply reach its caller first.

     A clean detach fails whenever anything still holds the mount -- one media
     server keeping a file open across the stop is enough -- and the lazy one
     then keeps the mount point from being left behind as a stale entry nobody
     can reach or remove. It does not end the session: that is {!finish_stop}'s
     part. *)
  let unmount mount_point =
    if not !unmount_needed then Lwt.return_unit
    else
      let* () = Lwt_unix.sleep 0.1 in
      let* status = detach mount_point in
      match status with
        | Unix.WEXITED 0 -> Lwt.return_unit
        | status -> (
            Log.info "fusermount3 -u %s %s; detaching lazily" mount_point
              (exit_status status);
            let+ status = detach ~lazily:true mount_point in
            match status with
              | Unix.WEXITED 0 -> ()
              (* Nothing further to try from in here, and the next start clears
                 the leftover ({!Fuse_frontend.prepare_mount_point}). Worth an
                 error: it is the one path where a mount outlives the daemon. *)
              | status ->
                  Log.err
                    "fusermount3 -uz %s %s; the mount point is left behind"
                    mount_point (exit_status status))

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
    Logical_key.kind key = `Dir
    ||
    let mp = F.manifest_path key in
    Sys.file_exists mp && Sys.is_directory mp

  (* Given a directory this applies to the whole subtree, and one file's failure
     must not abort the rest. *)
  let on_subtree what f key =
    if not (is_dir_key key) then f key
    else (
      let prefix = Lk.dir (Logical_key.path key) in
      let* files = F.list_tree ~prefix in
      Lwt_list.iter_s
        (fun (e : Checkout.listed) ->
          Lwt.catch
            (fun () -> f e.key)
            (fun exn ->
              Log.err "%s %s: %s" what
                (Logical_key.to_string e.key)
                (Printexc.to_string exn);
              Lwt.return_unit))
        files)

  let evict_key = on_subtree "evict" F.evict
  let restore_key = on_subtree "restore" F.ensure_cached

  (* The [sync --full] client clears and rebuilds the mirror before signalling
     us, and FUSE re-reads it on the next lookup. *)
  let full_resync () = Lwt.return_unit

  (* What a domain backed only by object storage reports. Its size is not ours
     to know and no local disk bounds it, so the figure only has to be large
     enough that nothing sizing a write against it ever refuses. *)
  let unlimited_bytes = Int64.shift_left 1L 50

  let store_capacity () =
    match Conf.capacity C.members with
      | Some space -> space
      | None ->
          Io_lwt.Fs.
            {
              avail = unlimited_bytes;
              free = unlimited_bytes;
              total = unlimited_bytes;
            }

  (* This mount has to be told a key changed: [cache_opts] turns off the
     attribute and entry timeouts, but that does not stop the kernel answering a
     lookup from a dentry it already holds, so a name another client renamed away
     stays resolvable in a directory already open. *)
  (* The path this mount shows for a key. *)
  let invalidate key =
    let rel = Logical_key.path key in
    (* Never from inside an operation on this path: the kernel waits on the
       request, and the invalidation waits on the kernel. Every caller is on the
       event loop, which is not a FUSE thread. *)
    try Fuse.invalidate_path ("/" ^ rel)
    with Unix.Unix_error (e, _, _) ->
      (* The kernel not holding it is the state we wanted; anything else the
         mount cannot fix, and silence here is a stale name nobody can account
         for. *)
      Log.debug "invalidate %s: %s" rel (Unix.error_message e)

  let ipc_hooks mount_point =
    Ih.
      {
        evict = evict_key;
        restore = restore_key;
        changed = invalidate;
        full_resync;
        status_fields = (fun () -> [("mount", `String mount_point)]);
        (* A domain can run several frontends, each its own process with its own
           counters, so the numbers have to name themselves. *)
        stats_fields =
          (fun () ->
            ("frontend", `String "fuse")
            :: ("mountPoint", `String mount_point)
            :: fuse_stats_fields ()
            @ D.stats_fields ());
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
          on_loop (fun () ->
              let key = fuse_to_key path in
              let* target = F.readlink key in
              match target with
                | Some t -> Lwt.return t
                | None ->
                    Lwt.fail (Unix.Unix_error (Unix.EINVAL, "readlink", path))));
      symlink =
        (fun target path ->
          on_loop (fun () -> F.symlink ~target (fuse_to_key path)));
      readdir =
        (fun path _offset _fi _flags ->
          on_loop (fun () ->
              let+ files, dirs =
                F.list_children ~prefix:(fuse_to_dir_prefix path)
              in
              let names =
                List.map
                  (fun (e : Checkout.listed) -> Logical_key.leaf e.key)
                  files
                @ List.map fst dirs
              in
              (* Files and directories are two listings of one namespace and a
                 name can land in both, which a stress run caught a mount doing:
                 concatenated, the directory returns that name twice and anything
                 building a map from the listing loses one silently.

                 The collision is upstream of here and not something readdir can
                 repair, so it is logged rather than quietly absorbed. *)
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
        (fun path mode -> on_loop (fun () -> (dispatch path).mknod path mode));
      (* Bumped on the event-loop thread, and only on success. *)
      fopen =
        (fun path fi ->
          on_loop (fun () ->
              let+ update = (dispatch path).fopen path fi in
              incr open_handles;
              incr files_opened;
              update));
      read =
        (fun path buf offset fi ->
          on_loop (fun () ->
              let+ n = (dispatch path).read path buf offset fi in
              Metrics.count read_bytes n;
              n));
      write =
        (fun path buf offset fi ->
          on_loop (fun () ->
              let+ n = (dispatch path).write path buf offset fi in
              Metrics.count written_bytes n;
              n));
      release =
        (fun path fi ->
          on_loop (fun () ->
              let+ () = (dispatch path).release path fi in
              (* A release without a matching fopen (a handle inherited across a
                 remount) must not drive the gauge negative. *)
              if !open_handles > 0 then decr open_handles));
      unlink = (fun path -> on_loop (fun () -> (dispatch path).unlink path));
      mkdir =
        (fun path _mode ->
          on_loop (fun () -> F.mkdir (fuse_to_dir_prefix path)));
      rmdir =
        (fun path -> on_loop (fun () -> F.rmdir (fuse_to_dir_prefix path)));
      rename =
        (fun src dst flags ->
          on_loop (fun () ->
              let is_hidden = is_fuse_hidden dst in
              let* () =
                (if is_hidden then hidden else real).rename src dst flags
              in
              if is_hidden then real.unlink src else Lwt.return_unit));
      truncate =
        (fun path size fi ->
          on_loop (fun () -> (dispatch path).truncate path size fi));
      (* What a file costs is room in the domain's stores, not in the cache it is
         staged through, so df reports the stores; inode counts stay nominal,
         nothing here mapping to one. One statvfs per bounded store and no cache
         walk, since df-alikes poll this. *)
      statfs =
        (fun _path ->
          let bsize = 4096L in
          let blocks bytes = Int64.div bytes bsize in
          let { Io_lwt.Fs.avail; free; total } = store_capacity () in
          Unix_util.
            {
              f_bsize = bsize;
              f_frsize = bsize;
              f_blocks = blocks total;
              (* df derives its used column from f_bfree, which counts the margin
                 reserved for root; only f_bavail says what this writer gets. *)
              f_bfree = blocks free;
              f_bavail = blocks avail;
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

  (* The main thread cannot be waited on here: [Fuse.main] returns when the
     kernel drops the connection, and the session outlives the mount point for as
     long as another process holds a descriptor on it, which a reader need never
     let go of.

     By this point everything this process owed is done, and exiting is what
     closes /dev/fuse and turns the reader's descriptor into ESTALE; waiting
     instead is the 90-second stop that ends in SIGABRT. *)
  let finish_stop () =
    Log.debug "stop complete, exiting";
    (try Unix.unlink C.socket_path with _ -> ());
    flush stdout;
    flush stderr;
    Unix._exit 0

  let mount ?(allow_other = false) mount_point =
    (* Worth the allocation it costs on the failing thread: an
       [Invalid_argument] from some [String.sub] names neither the file it came
       from nor the caller that reached it, and the count that says a handler
       failed at all is bumped before the capture either way. *)
    Fuse.set_backtrace_capture true;
    (* An exception escaping through Lwt.async (a socket error in a library's
       background loop) must not take down the daemon or leave it half-dead. *)
    (Lwt.async_exception_hook :=
       fun exn -> Log.err "async exception: %s" (Printexc.to_string exn));
    Domain_engine.run
      ~after:(fun () ->
        (* Only for a stop we asked for. When the FUSE loop exits on its own --
           someone unmounted from outside -- the main thread is already on its
           way out and does the same cleanup in order. *)
        if !unmount_needed then finish_stop ())
      ~main_thread:(fun () ->
        Log.info "mounting FUSE at %s" mount_point;
        (* [allow_other] lets other users reach the mount; it also needs
           [user_allow_other] in /etc/fuse.conf. *)
        (* The kernel's own caches, turned off: they assume this filesystem
           changes only through the kernel's own calls, which is false the moment
           a second client shares the domain, and freshness is bought instead by
           a LOOKUP per path access.

           That buys resolution, not enumeration -- a directory's cached listing
           is not covered by these timeouts and this API cannot invalidate it
           either, so a stale readdir survives until the directory is opened
           afresh. Closing that needs [fuse_lowlevel_notify_inval_entry], hence a
           lowlevel binding. *)
        let cache_opts =
          [
            "entry_timeout=0";
            "attr_timeout=0";
            "negative_timeout=0";
            "auto_cache";
          ]
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
        notify_stop_from_main ())
      (fun ~ready ->
        let* () =
          (* A FUSE mount is the filesystem, so a finished upload changes
             nothing a reader can observe. *)
          D.start ~on_upload_done:(fun ~key:_ -> Lwt.return_unit) ()
        in
        Log.debug "starting IPC server at %s" C.socket_path;
        Lwt.async (fun () ->
            Ipc_lwt.serve ~path:C.socket_path
              (Ih.handler (ipc_hooks mount_point)));
        Lwt.async (fun () -> report_recorded_failures 0);
        (* A plain SIGTERM reaches this group too, from a supervisor that only
           signals and always from the parent when this frontend was forked.
           libfuse may install its own handlers in [Fuse.main] and override
           these; this covers the case where it installs none, in which the
           default action would kill the process mid-queue. *)
        List.iter
          (fun s -> ignore (Lwt_unix.on_signal s (fun _ -> request_stop ())))
          [Sys.sigterm; Sys.sigint];
        (* Before [ready], so the main thread sees it once it starts. *)
        stop_notification := Some (Lwt_unix.make_notification do_stop);
        ready ();
        let* () = stop_t in
        (* Concurrent: the unmount is what lets the main thread out of
           [Fuse.main], so it must not wait behind the drain. *)
        let unmount_t = unmount mount_point in
        Log.debug "draining upload queue and backends";
        let* () = D.drain () in
        unmount_t);
    try Unix.unlink C.socket_path with _ -> ()
end
