open Lwt.Syntax

module Make (F : File_ops.S with type 'a io := 'a Lwt.t) = struct
  let make ~fuse_to_key : Path_ops.t =
    let file path = fuse_to_key path in
    {
      (* No local catch: the binding records anything that is not a
         [Unix_error] and answers EIO, and catching here first loses it. *)
      mknod = (fun path _mode -> F.create (file path));
      fopen =
        (fun path fi ->
          let flags = fi.fi_flags in
          let creating = List.mem Unix.O_CREAT flags in
          let truncating = List.mem Unix.O_TRUNC flags in
          let f = file path in
          Log.debug "fopen %s flags=%s" path
            (if creating && truncating then "CREAT|TRUNC"
             else if creating then "CREAT"
             else if truncating then "TRUNC"
             else if flags = [Unix.O_RDONLY] then "RDONLY"
             else "OTHER");
          (* Nothing to prepare: the first read resolves the file and fetches
             only the chunks it needs. *)
          let* () =
            if truncating then F.truncate f 0L
            else if creating then
              let* m = F.published_here f in
              match m with None -> F.create f | Some _ -> Lwt.return_unit
            else Lwt.return_unit
          in
          Lwt.return
            Fuse.{ default_file_info_update with fi_update_direct_io = true });
      read =
        (fun path buf offset _fi ->
          let f = file path in
          if offset = 0L then Log.debug "read %s: offset=0" path;
          F.read f buf ~offset);
      write = (fun path buf offset _fi -> F.write (file path) buf ~offset);
      release = (fun path _fi -> F.close (file path));
      unlink = (fun path -> F.delete (file path));
      rename = (fun src dst _flags -> F.rename ~src:(file src) ~dst:(file dst));
      truncate = (fun path size _fi -> F.truncate (file path) size);
    }
end
