open Lwt.Syntax

module Make (F : File.S) = struct
  let make ~fuse_to_key : Path_ops.t =
    let local_path path = F.local_path (fuse_to_key path) in
    {
      mknod =
        (fun path _mode ->
          let* () = F.ensure_parent_dir (fuse_to_key path) in
          Lwt_io.with_file ~mode:Lwt_io.Output (local_path path) (fun _ ->
              Lwt.return_unit));
      fopen =
        (fun _path _fi ->
          Lwt.return
            Fuse.{ default_file_info_update with fi_update_direct_io = true });
      read =
        (fun path buf offset _fi -> Local_io.read (local_path path) buf ~offset);
      write =
        (fun path buf offset _fi ->
          Local_io.write (local_path path) buf ~offset);
      release = (fun _path _fi -> Lwt.return_unit);
      unlink =
        (fun path ->
          Lwt.catch
            (fun () -> Lwt_unix.unlink (local_path path))
            (function
              | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_unit
              | e -> Lwt.fail e));
      rename =
        (fun src dst _flags ->
          Lwt.catch
            (fun () -> Lwt_unix.rename (local_path src) (local_path dst))
            (function
              | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_unit
              | e -> Lwt.fail e));
      truncate =
        (fun path size _fi ->
          let lp = local_path path in
          let* fd = Lwt_unix.openfile lp [Unix.O_WRONLY] 0o644 in
          let* () = Lwt_unix.LargeFile.ftruncate fd size in
          Lwt_unix.close fd);
    }
end
