module Make (F : File.S) = struct
  let make ~fuse_to_key : Path_ops.t =
    let file path = fuse_to_key path in
    {
      mknod =
        (fun path _mode ->
          try F.create (file path)
          with exn ->
            Log.err "mknod %s: %s" path (Printexc.to_string exn);
            raise (Unix.Unix_error (Unix.EIO, "mknod", path)));
      fopen =
        (fun path fi ->
          let flags = fi.fi_flags in
          let creating = List.mem Unix.O_CREAT flags in
          let truncating = List.mem Unix.O_TRUNC flags in
          let f = file path in
          Log.debug "fopen %s flags=%s cached=%b" path
            (if creating && truncating then "CREAT|TRUNC"
             else if creating then "CREAT"
             else if truncating then "TRUNC"
             else if flags = [Unix.O_RDONLY] then "RDONLY"
             else "OTHER")
            (F.is_cached f);
          if truncating && not (F.is_cached f) then F.create f
          else if truncating then begin
            ignore (F.cancel_upload f);
            let fd =
              Unix.openfile (F.local_path f) [Unix.O_WRONLY; Unix.O_TRUNC] 0o644
            in
            Unix.close fd;
            F.mark_dirty f
          end
          else if not (F.is_cached f) then (
            match (creating, F.read_manifest f) with
              | true, None -> F.create f
              | _ -> F.ensure_cached f);
          F.open_file f;
          Fuse.{ default_file_info_update with fi_update_direct_io = true });
      read =
        (fun path buf offset _fi ->
          if offset = 0L then Log.debug "read %s: offset=0" path;
          F.read (file path) buf ~offset);
      write = (fun path buf offset _fi -> F.write (file path) buf ~offset);
      release = (fun path _fi -> F.close_file (file path));
      unlink = (fun path -> F.delete (file path));
      rename = (fun src dst _flags -> F.rename ~src:(file src) ~dst:(file dst));
      truncate = (fun path size _fi -> F.truncate (file path) size);
    }
end
