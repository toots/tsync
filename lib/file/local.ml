open Lwt.Syntax

let data_dir ~cache_root domain_name = Filename.concat cache_root domain_name

let manifest_dir ~cache_root domain_name =
  Filename.concat cache_root (".manifest/" ^ domain_name)

let strip_prefix ~domain_prefix key =
  let pfx = String.length domain_prefix in
  if String.length key >= pfx && String.sub key 0 pfx = domain_prefix then
    String.sub key pfx (String.length key - pfx)
  else key

let cache_path ~cache_root ~domain_name ~domain_prefix key =
  Filename.concat
    (data_dir ~cache_root domain_name)
    (strip_prefix ~domain_prefix key)

let mkdir_p = Fs_util.mkdir_p
let ensure_parent_dir = Fs_util.ensure_parent

let manifest_path ~cache_root ~domain_name ~domain_prefix key =
  Filename.concat
    (manifest_dir ~cache_root domain_name)
    (strip_prefix ~domain_prefix key)

let create_dir ~cache_root ~domain_name ~domain_prefix key =
  mkdir_p (manifest_path ~cache_root ~domain_name ~domain_prefix key)

let readdir_list = Fs_util.readdir_list
let is_directory = Fs_util.is_directory

let delete_dir ~cache_root ~domain_name ~domain_prefix key =
  Fs_util.rm_rf (manifest_path ~cache_root ~domain_name ~domain_prefix key)

let list_dir ~cache_root ~domain_name ~domain_prefix key =
  let path = manifest_path ~cache_root ~domain_name ~domain_prefix key in
  let* is_dir = is_directory path in
  if is_dir then readdir_list path else Lwt.return_nil

let is_cached ~cache_root ~domain_name ~domain_prefix key =
  Lwt_unix.file_exists (cache_path ~cache_root ~domain_name ~domain_prefix key)

let read_manifest ~cache_root ~domain_name ~domain_prefix key =
  let path = manifest_path ~cache_root ~domain_name ~domain_prefix key in
  let* exists = Lwt_unix.file_exists path in
  if not exists then Lwt.return_none
  else
    Lwt.catch
      (fun () ->
        let+ s = Lwt_io.with_file ~mode:Lwt_io.Input path Lwt_io.read in
        Some s)
      (fun _ -> Lwt.return_none)

let delete_manifest ~cache_root ~domain_name ~domain_prefix key =
  let path = manifest_path ~cache_root ~domain_name ~domain_prefix key in
  Lwt.catch
    (fun () -> Lwt_unix.unlink path)
    (function Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e)

let rename_manifest ~cache_root ~domain_name ~domain_prefix ~src_key ~dst_key =
  let src = manifest_path ~cache_root ~domain_name ~domain_prefix src_key in
  let* exists = Lwt_unix.file_exists src in
  if not exists then Lwt.return_unit
  else (
    let dst = manifest_path ~cache_root ~domain_name ~domain_prefix dst_key in
    let* () = ensure_parent_dir dst in
    Lwt_unix.rename src dst)

let rec clean_tmp_manifests dir =
  let* exists = Lwt_unix.file_exists dir in
  if not exists then Lwt.return_unit
  else
    let* is_dir = is_directory dir in
    if not is_dir then Lwt.return_unit
    else
      let* names = readdir_list dir in
      Lwt_list.iter_s
        (fun name ->
          let path = Filename.concat dir name in
          let* is_dir = is_directory path in
          if is_dir then clean_tmp_manifests path
          else if Filename.check_suffix name ".tmp" then
            Lwt.catch
              (fun () -> Lwt_unix.unlink path)
              (function
                | Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e)
          else Lwt.return_unit)
        names

let init ~cache_root ~domain_name =
  let root = manifest_dir ~cache_root domain_name in
  let* () = mkdir_p root in
  clean_tmp_manifests root

let evict ~cache_root ~domain_name ~domain_prefix key =
  let path = cache_path ~cache_root ~domain_name ~domain_prefix key in
  Lwt.catch
    (fun () -> Lwt_unix.unlink path)
    (function Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e)
