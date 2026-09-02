open Lwt.Syntax

(* The FUSE kernel's .fuse_hidden* files, created when a file with open
   descriptors is renamed. Kernel-internal and never published, so they are plain
   files under the domain's scratch tree. *)
module Make (C : Conf_lwt.S) = struct
  let make ~fuse_to_key : Path_ops.t =
    let local_path path =
      Cache_layout.scratch_path ~cache_root:C.cache_root
        ~domain_name:C.domain_name (fuse_to_key path)
    in
    {
      mknod =
        (fun path _mode ->
          let* () = Io_lwt.Fs.ensure_parent (local_path path) in
          Lwt_io.with_file ~mode:Lwt_io.Output (local_path path) (fun _ ->
              Lwt.return_unit));
      fopen =
        (fun _path _fi ->
          Lwt.return
            Fuse.{ default_file_info_update with fi_update_direct_io = true });
      read =
        (fun path buf offset _fi ->
          Io_lwt.Fs.read (local_path path) buf ~offset);
      write =
        (fun path buf offset _fi ->
          Io_lwt.Fs.write (local_path path) buf ~offset);
      release = (fun _path _fi -> Lwt.return_unit);
      unlink = (fun path -> Io_lwt.Fs.unlink_quiet (local_path path));
      rename =
        (fun src dst _flags ->
          Lwt.catch
            (fun () -> Io_lwt.Syscalls.rename (local_path src) (local_path dst))
            (function
              | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_unit
              | e -> Lwt.fail e));
      truncate =
        (fun path size _fi ->
          let lp = local_path path in
          let* fd = Io_lwt.Syscalls.openfile lp [Unix.O_WRONLY] 0o644 in
          let* () = Io_lwt.Syscalls.LargeFile.ftruncate fd size in
          Io_lwt.Syscalls.close fd);
    }
end
