open Lwt.Syntax

type data_source = Local_cache | Remote_chunks | Symlink
type status = Exported of data_source | Missing_data
type summary = { exported : int; missing : int }

let is_marker key = String.length key > 0 && key.[String.length key - 1] = '/'

let copy_file ~src ~dst =
  let* src_fd = Lwt_unix_retry.openfile src [Unix.O_RDONLY] 0 in
  Lwt.finalize
    (fun () ->
      let* dst_fd =
        Lwt_unix_retry.openfile dst
          [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC]
          0o644
      in
      Lwt.finalize
        (fun () ->
          let buffer = Bytes.create (1 lsl 20) in
          let rec copy () =
            let* bytes_read =
              Lwt_unix_retry.read src_fd buffer 0 (Bytes.length buffer)
            in
            if bytes_read = 0 then Lwt.return_unit
            else (
              let rec write_all pos =
                if pos >= bytes_read then copy ()
                else
                  let* written =
                    Lwt_unix_retry.write dst_fd buffer pos (bytes_read - pos)
                  in
                  write_all (pos + written)
              in
              write_all 0)
          in
          copy ())
        (fun () -> Lwt_unix_retry.close dst_fd))
    (fun () -> Lwt_unix_retry.close src_fd)

module Make (C : Conf.S) = struct
  module R = Remote.Make (C)

  let primary () =
    match C.backends with
      | [] -> failwith "no backends configured"
      | b :: _ -> b

  let rel_of_key key =
    let pfx = String.length C.domain_prefix in
    String.sub key pfx (String.length key - pfx)

  (* Prefer the local sidecar (the only place a Dirty state lives), else the
     remote manifest. *)
  let manifest_for key =
    let* sidecar =
      Local.read_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
        ~domain_prefix:C.domain_prefix key
    in
    match sidecar with
      | Some s -> (
          try Lwt.return_some (Manifest.of_string s)
          with _ -> R.fetch_manifest ~key ())
      | None -> R.fetch_manifest ~key ()

  let export_file ~dst rel =
    let key = C.domain_prefix ^ rel in
    let dst_path = Filename.concat dst rel in
    let* () = Fs_util.ensure_parent dst_path in
    let cache_path =
      Local.cache_path ~cache_root:C.cache_root ~domain_name:C.domain_name
        ~domain_prefix:C.domain_prefix key
    in
    let* cached = Lwt_unix_retry.file_exists cache_path in
    if cached then
      let* () = copy_file ~src:cache_path ~dst:dst_path in
      let* st = Lwt_unix_retry.stat cache_path in
      let+ () =
        Lwt_unix_retry.utimes dst_path st.Unix.st_atime st.Unix.st_mtime
      in
      Exported Local_cache
    else
      let* manifest = manifest_for key in
      match manifest with
        | Some (`Clean ({ symlink = Some target; _ } as m)) ->
            let* () =
              Lwt.catch
                (fun () -> Lwt_unix_retry.unlink dst_path)
                (function
                  | Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e)
            in
            let+ () = Lwt_unix_retry.symlink target dst_path in
            ignore m;
            Exported Symlink
        | Some (`Clean m) ->
            (* Recompose from remote chunks straight to the destination — the
               local cache is deliberately not populated. *)
            let* () = R.download_chunks ~dst_path m in
            let+ () =
              Lwt_unix_retry.utimes dst_path m.Manifest.mtime m.Manifest.mtime
            in
            Exported Remote_chunks
        | Some `Dirty | None ->
            (* Dirty with no local data, or a sidecar-less key that vanished
               remotely: nothing to export from. *)
            Lwt.return Missing_data

  (* Export every file of the domain to [dst]. Files are the union of the
     backend listing and the local sidecar tree (which adds local-only files
     whose upload is still pending). *)
  let run ~dst ~on_file () =
    let (module B : Backend.S) = primary () in
    let* entries = B.list_all ~prefix:C.domain_prefix () in
    let remote_dirs, remote_files =
      List.partition (fun (e : Backend.file_entry) -> is_marker e.key) entries
    in
    let* local_rels =
      Local.walk_manifests ~cache_root:C.cache_root ~domain_name:C.domain_name
        ()
    in
    let files =
      List.sort_uniq compare
        (List.map
           (fun (e : Backend.file_entry) -> rel_of_key e.key)
           remote_files
        @ local_rels)
    in
    let* () = Fs_util.mkdir_p dst in
    let* () =
      Lwt_list.iter_s
        (fun (e : Backend.file_entry) ->
          Fs_util.mkdir_p (Filename.concat dst (rel_of_key e.key)))
        remote_dirs
    in
    let+ statuses =
      Lwt_list.map_s
        (fun rel ->
          let+ status = export_file ~dst rel in
          on_file ~rel status;
          status)
        files
    in
    {
      exported =
        List.length
          (List.filter (function Exported _ -> true | _ -> false) statuses);
      missing =
        List.length
          (List.filter (function Missing_data -> true | _ -> false) statuses);
    }
end
