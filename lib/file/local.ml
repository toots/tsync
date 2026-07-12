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
    (Fs_util.encode_key (strip_prefix ~domain_prefix key))

let mkdir_p = Fs_util.mkdir_p
let ensure_parent_dir = Fs_util.ensure_parent

let manifest_path ~cache_root ~domain_name ~domain_prefix key =
  Filename.concat
    (manifest_dir ~cache_root domain_name)
    (Fs_util.encode_key (strip_prefix ~domain_prefix key))

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

(* All manifest sidecars under the domain's manifest tree, as domain-relative
   paths (unsorted). Empty when the tree does not exist. *)
let walk_manifests ~cache_root ~domain_name () =
  let root = manifest_dir ~cache_root domain_name in
  let rec walk rel acc =
    let dir = if rel = "" then root else Filename.concat root rel in
    let* names = readdir_list dir in
    Lwt_list.fold_left_s
      (fun acc name ->
        let r = if rel = "" then name else rel ^ "/" ^ name in
        let* is_dir = is_directory (Filename.concat root r) in
        if is_dir then walk r acc
        else if Filename.check_suffix name ".tmp" then Lwt.return acc
        else Lwt.return (Fs_util.decode_key r :: acc))
      acc names
  in
  let* root_ok = is_directory root in
  if root_ok then walk "" [] else Lwt.return_nil

let is_cached ~cache_root ~domain_name ~domain_prefix key =
  Lwt_unix_retry.file_exists
    (cache_path ~cache_root ~domain_name ~domain_prefix key)

let read_manifest ~cache_root ~domain_name ~domain_prefix key =
  let path = manifest_path ~cache_root ~domain_name ~domain_prefix key in
  let* exists = Lwt_unix_retry.file_exists path in
  if not exists then Lwt.return_none
  else
    Lwt.catch
      (fun () ->
        let+ s = Lwt_unix_retry.with_file ~mode:Lwt_io.Input path Lwt_io.read in
        Some s)
      (fun _ -> Lwt.return_none)

let write_manifest ~cache_root ~domain_name ~domain_prefix key data =
  let path = manifest_path ~cache_root ~domain_name ~domain_prefix key in
  let* () = ensure_parent_dir path in
  let tmp = path ^ ".tmp" in
  let* () =
    Lwt_unix_retry.with_file ~mode:Lwt_io.Output tmp (fun oc ->
        Lwt_io.write oc data)
  in
  Lwt_unix_retry.rename tmp path

let delete_manifest ~cache_root ~domain_name ~domain_prefix key =
  let path = manifest_path ~cache_root ~domain_name ~domain_prefix key in
  Lwt.catch
    (fun () -> Lwt_unix_retry.unlink path)
    (function Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e)

let rename_manifest ~cache_root ~domain_name ~domain_prefix ~src_key ~dst_key =
  let src = manifest_path ~cache_root ~domain_name ~domain_prefix src_key in
  let* exists = Lwt_unix_retry.file_exists src in
  if not exists then Lwt.return_unit
  else (
    let dst = manifest_path ~cache_root ~domain_name ~domain_prefix dst_key in
    let* () = ensure_parent_dir dst in
    Lwt_unix_retry.rename src dst)

let rec clean_tmp_manifests dir =
  let* exists = Lwt_unix_retry.file_exists dir in
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
              (fun () -> Lwt_unix_retry.unlink path)
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
    (fun () -> Lwt_unix_retry.unlink path)
    (function Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e)
