let make ~(ctx : Context.t) : Path_ops.t =
  let file path =
    File.make ~store:ctx.files ~key:(Context.fuse_to_key ctx path)
  in
  {
    mknod =
      (fun path _mode ->
        try File.create (file path)
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
          (File.is_cached f);
        if truncating && not (File.is_cached f) then File.create f
        else if truncating then begin
          ignore (File.cancel_upload f);
          let fd =
            Unix.openfile (File.local_path f)
              [Unix.O_WRONLY; Unix.O_TRUNC]
              0o644
          in
          Unix.close fd;
          File.mark_dirty f
        end
        else if not (File.is_cached f) then (
          match (creating, File.read_manifest f) with
            | true, None -> File.create f
            | _ -> File.ensure_cached f);
        File.open_file f;
        Fuse.{ default_file_info_update with fi_update_direct_io = true });
    read =
      (fun path buf offset _fi ->
        if offset = 0L then Log.debug "read %s: offset=0" path;
        File.read (file path) buf ~offset);
    write = (fun path buf offset _fi -> File.write (file path) buf ~offset);
    release = (fun path _fi -> File.close_file (file path));
    unlink = (fun path -> File.delete (file path));
    rename =
      (fun src dst _flags ->
        File.rename
          ~src:(File.make ~store:ctx.files ~key:(Context.fuse_to_key ctx src))
          ~dst:(File.make ~store:ctx.files ~key:(Context.fuse_to_key ctx dst)));
    truncate = (fun path size _fi -> File.truncate (file path) size);
  }
