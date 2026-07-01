module Make (F : File.S) = struct
  let make ~fuse_to_key : Path_ops.t =
    let local_path path = F.local_path (fuse_to_key path) in
    {
      mknod =
        (fun path _mode ->
          F.ensure_parent_dir (fuse_to_key path);
          close_out (open_out_bin (local_path path)));
      fopen =
        (fun _path _fi ->
          Fuse.{ default_file_info_update with fi_update_direct_io = true });
      read =
        (fun path buf offset _fi -> Local_io.read (local_path path) buf ~offset);
      write =
        (fun path buf offset _fi ->
          Local_io.write (local_path path) buf ~offset);
      release = (fun _path _fi -> ());
      unlink =
        (fun path ->
          try Unix.unlink (local_path path)
          with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      rename =
        (fun src dst _flags ->
          try Unix.rename (local_path src) (local_path dst)
          with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      truncate =
        (fun path size _fi ->
          let lp = local_path path in
          let fd = Unix.openfile lp [Unix.O_WRONLY] 0o644 in
          Unix.ftruncate fd (Int64.to_int size);
          Unix.close fd);
    }
end
