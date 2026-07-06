open Lwt.Syntax

module Make (F : File.S) = struct
  let make ~fuse_to_key ~open_file ~close_file ~fd_for : Path_ops.t =
    let file path = fuse_to_key path in
    {
      mknod =
        (fun path _mode ->
          Lwt.catch
            (fun () -> F.create (file path))
            (fun exn ->
              Log.err "mknod %s: %s" path (Printexc.to_string exn);
              Lwt.fail (Unix.Unix_error (Unix.EIO, "mknod", path))));
      fopen =
        (fun path fi ->
          let flags = fi.fi_flags in
          let creating = List.mem Unix.O_CREAT flags in
          let truncating = List.mem Unix.O_TRUNC flags in
          let f = file path in
          let* cached = F.is_cached f in
          Log.debug "fopen %s flags=%s cached=%b" path
            (if creating && truncating then "CREAT|TRUNC"
             else if creating then "CREAT"
             else if truncating then "TRUNC"
             else if flags = [Unix.O_RDONLY] then "RDONLY"
             else "OTHER")
            cached;
          let* () =
            if truncating && not cached then F.create f
            else if truncating then begin
              ignore (F.cancel_upload f);
              let* fd =
                Lwt_unix.openfile (F.local_path f)
                  [Unix.O_WRONLY; Unix.O_TRUNC]
                  0o644
              in
              let* () = Lwt_unix.close fd in
              F.mark_dirty f
            end
            else if not cached then
              let* m = F.read_manifest f in
              match (creating, m) with
                | true, None -> F.create f
                | _ -> F.ensure_cached f
            else Lwt.return_unit
          in
          let* () = open_file f in
          Lwt.return
            Fuse.{ default_file_info_update with fi_update_direct_io = true });
      read =
        (fun path buf offset _fi ->
          let f = file path in
          if offset = 0L then Log.debug "read %s: offset=0" path;
          let* cached = F.is_cached f in
          if not cached then
            Log.debug "read %s: not in local cache, fetching from backend" path;
          let* () = F.ensure_cached f in
          match fd_for f with
            | Some fd -> Local_io.pread fd buf ~offset
            | None -> Local_io.read (F.local_path f) buf ~offset);
      write =
        (fun path buf offset _fi ->
          let f = file path in
          let* () = F.mark_dirty f in
          match fd_for f with
            | Some fd -> Local_io.pwrite fd buf ~offset
            | None -> Local_io.write (F.local_path f) buf ~offset);
      release = (fun path _fi -> close_file (file path));
      unlink = (fun path -> F.delete (file path));
      rename = (fun src dst _flags -> F.rename ~src:(file src) ~dst:(file dst));
      truncate = (fun path size _fi -> F.truncate (file path) size);
    }
end
