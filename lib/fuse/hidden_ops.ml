open Lwt.Syntax

(* The FUSE kernel's .fuse_hidden* files: scratch created when a file with open
   descriptors is renamed. They are kernel-internal and never reach the backend,
   so they are plain local files under the domain's scratch tree — the one place
   left that keeps a whole file on disk. *)
module Make (C : Conf.S) = struct
  let make ~fuse_to_key : Path_ops.t =
    let local_path path =
      Filename.concat
        (Cache_layout.scratch_dir ~cache_root:C.cache_root C.domain_name)
        (Name_escape.encode_key
           (Key.strip_prefix ~domain_prefix:C.domain_prefix (fuse_to_key path)))
    in
    {
      mknod =
        (fun path _mode ->
          let* () = Fs_util.ensure_parent (local_path path) in
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
      unlink = (fun path -> Fs_util.unlink_quiet (local_path path));
      rename =
        (fun src dst _flags ->
          Lwt.catch
            (fun () -> Lwt_unix_retry.rename (local_path src) (local_path dst))
            (function
              | Unix.Unix_error (Unix.ENOENT, _, _) -> Lwt.return_unit
              | e -> Lwt.fail e));
      truncate =
        (fun path size _fi ->
          let lp = local_path path in
          let* fd = Lwt_unix_retry.openfile lp [Unix.O_WRONLY] 0o644 in
          let* () = Lwt_unix_retry.LargeFile.ftruncate fd size in
          Lwt_unix_retry.close fd);
    }
end
