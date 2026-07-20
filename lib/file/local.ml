open Lwt.Syntax

(* Cache layout is defined once in {!Cache_layout}. *)
let data_dir ~cache_root domain_name =
  Cache_layout.cached_dir ~cache_root domain_name

let manifest_dir ~cache_root domain_name =
  Cache_layout.manifests_dir ~cache_root domain_name

let strip_prefix ~domain_prefix key =
  if String.starts_with ~prefix:domain_prefix key then (
    let pfx = String.length domain_prefix in
    String.sub key pfx (String.length key - pfx))
  else key

let chop_trailing_slash s =
  if String.ends_with ~suffix:"/" s then String.sub s 0 (String.length s - 1)
  else s

let cache_path ~cache_root ~domain_name ~domain_prefix key =
  Filename.concat
    (data_dir ~cache_root domain_name)
    (Name_escape.encode_key (strip_prefix ~domain_prefix key))

let mkdir_p = Fs_util.mkdir_p
let ensure_parent_dir = Fs_util.ensure_parent

let manifest_path ~cache_root ~domain_name ~domain_prefix key =
  Filename.concat
    (manifest_dir ~cache_root domain_name)
    (Name_escape.encode_key (strip_prefix ~domain_prefix key))

(* Write [name] into an escaped directory's marker file so readdir can recover
   its real name; skipped when already present. *)
let write_marker path name =
  let* exists = Lwt_unix_retry.file_exists path in
  if exists then Lwt.return_unit
  else (
    let tmp = path ^ ".tmp" in
    let* () =
      Lwt_unix_retry.with_file ~mode:Lwt_io.Output tmp (fun oc ->
          Lwt_io.write oc name)
    in
    Lwt_unix_retry.rename tmp path)

let read_marker path =
  Lwt.catch
    (fun () ->
      let+ s = Lwt_unix_retry.with_file ~mode:Lwt_io.Input path Lwt_io.read in
      s)
    (fun _ -> Lwt.return "")

(* Real name of a listed subdirectory [dir_path] whose on-disk name is [name]:
   its marker when the name is escaped, else the on-disk name itself. *)
let real_dir_name dir_path name =
  if Name_escape.is_escaped name then
    read_marker (Filename.concat dir_path Name_escape.dir_marker)
  else Lwt.return name

(* After a directory moves, its escaped on-disk name is a hash of the *new* name
   while the marker inside still holds the old one — rewrite it so readdir shows
   the new name. No-op for a name the filesystem can hold verbatim. *)
let refresh_dir_marker ~cache_root ~domain_name ~domain_prefix key =
  let rel = chop_trailing_slash (strip_prefix ~domain_prefix key) in
  let leaf = if rel = "" then "" else Filename.basename rel in
  if
    rel = "" || not (Name_escape.is_escaped (Name_escape.encode_component leaf))
  then Lwt.return_unit
  else (
    let dir =
      Filename.concat
        (manifest_dir ~cache_root domain_name)
        (Name_escape.encode_key rel)
    in
    let path = Filename.concat dir Name_escape.dir_marker in
    let tmp = path ^ ".tmp" in
    let* () =
      Lwt_unix_retry.with_file ~mode:Lwt_io.Output tmp (fun oc ->
          Lwt_io.write oc leaf)
    in
    Lwt_unix_retry.rename tmp path)

let join_rel rel name = if rel = "" then name else rel ^ "/" ^ name

(* Create the escaped directory chain for real relative path [rel] under [root],
   writing a name marker inside each escaped component. *)
let ensure_dirs root rel =
  let components =
    String.split_on_char '/' rel |> List.filter (fun c -> c <> "")
  in
  let* () = mkdir_p root in
  let rec go dir = function
    | [] -> Lwt.return_unit
    | c :: rest ->
        let enc = Name_escape.encode_component c in
        let dir = Filename.concat dir enc in
        let* () = mkdir_p dir in
        let* () =
          if Name_escape.is_escaped enc then
            write_marker (Filename.concat dir Name_escape.dir_marker) c
          else Lwt.return_unit
        in
        go dir rest
  in
  go root components

let create_dir ~cache_root ~domain_name ~domain_prefix key =
  ensure_dirs
    (manifest_dir ~cache_root domain_name)
    (strip_prefix ~domain_prefix key)

let readdir_list = Fs_util.readdir_list
let is_directory = Fs_util.is_directory

let delete_dir ~cache_root ~domain_name ~domain_prefix key =
  Fs_util.rm_rf (manifest_path ~cache_root ~domain_name ~domain_prefix key)

let list_dir ~cache_root ~domain_name ~domain_prefix key =
  let path = manifest_path ~cache_root ~domain_name ~domain_prefix key in
  let* is_dir = is_directory path in
  if is_dir then readdir_list path else Lwt.return_nil

let list_directory ~cache_root ~domain_name ~domain_prefix ~prefix () =
  let reldir = strip_prefix ~domain_prefix prefix in
  let reldir_clean = chop_trailing_slash reldir in
  let root = manifest_dir ~cache_root domain_name in
  let dir =
    if reldir_clean = "" then root
    else Filename.concat root (Name_escape.encode_key reldir_clean)
  in
  let* dir_exists = is_directory dir in
  if not dir_exists then Lwt.return ([], [])
  else (
    (* Logical keys are rebuilt from the listing position (this directory) plus
       each manifest's leaf [name] — the on-disk filename may be escaped. *)
    let child_base =
      if reldir_clean = "" then domain_prefix
      else domain_prefix ^ reldir_clean ^ "/"
    in
    let* names = readdir_list dir in
    Lwt_list.fold_left_s
      (fun (files, dirs) name ->
        if
          Filename.check_suffix name ".tmp"
          || name = Name_escape.dir_marker
          || name = Folder_ids.marker_name
        then Lwt.return (files, dirs)
        else (
          let path = Filename.concat dir name in
          let* is_dir = is_directory path in
          if is_dir then
            let+ real =
              if Name_escape.is_escaped name then
                read_marker (Filename.concat path Name_escape.dir_marker)
              else Lwt.return name
            in
            (files, real :: dirs)
          else
            let+ content =
              Lwt.catch
                (fun () ->
                  let+ s =
                    Lwt_unix_retry.with_file ~mode:Lwt_io.Input path Lwt_io.read
                  in
                  Some s)
                (fun _ -> Lwt.return_none)
            in
            (* The real name is the manifest's own leaf [name], not the
               (possibly escaped) on-disk filename. *)
              match content with
              | Some s -> (
                  match Manifest.of_string s with
                    | `Clean m ->
                        let entry =
                          Backend.
                            {
                              key = child_base ^ m.Manifest.name;
                              size = Int64.to_int m.size;
                              last_modified = m.mtime;
                            }
                        in
                        (entry :: files, dirs)
                    | `Dirty -> (files, dirs)
                    | exception _ -> (files, dirs))
              | None -> (files, dirs)))
      ([], []) names)

(* Every file entry under [prefix] in the local manifest mirror (recursive),
   with real keys derived from each manifest body's [path]. Serves the recursive
   enumeration the backend used to answer, now that keys there are hashed. *)
let list_all ~cache_root ~domain_name ~domain_prefix ~prefix () =
  let reldir = chop_trailing_slash (strip_prefix ~domain_prefix prefix) in
  let root = manifest_dir ~cache_root domain_name in
  let start =
    if reldir = "" then root
    else Filename.concat root (Name_escape.encode_key reldir)
  in
  let rec walk dir rel acc =
    let* names = readdir_list dir in
    Lwt_list.fold_left_s
      (fun acc name ->
        if
          Filename.check_suffix name ".tmp"
          || name = Name_escape.dir_marker
          || name = Folder_ids.marker_name
        then Lwt.return acc
        else (
          let path = Filename.concat dir name in
          let* is_dir = is_directory path in
          if is_dir then
            let* real = real_dir_name path name in
            walk path (join_rel rel real) acc
          else
            let* content =
              Lwt.catch
                (fun () ->
                  let+ s =
                    Lwt_unix_retry.with_file ~mode:Lwt_io.Input path Lwt_io.read
                  in
                  Some s)
                (fun _ -> Lwt.return_none)
            in
            match content with
              | Some s -> (
                  match Manifest.of_string s with
                    | `Clean m ->
                        Lwt.return
                          (Backend.
                             {
                               key =
                                 domain_prefix ^ join_rel rel m.Manifest.name;
                               size = Int64.to_int m.size;
                               last_modified = m.mtime;
                             }
                          :: acc)
                    | `Dirty -> Lwt.return acc
                    | exception _ -> Lwt.return acc)
              | None -> Lwt.return acc))
      acc names
  in
  let* ok = is_directory start in
  if ok then walk start reldir [] else Lwt.return_nil

(* All manifest sidecars under the domain's manifest tree, as domain-relative
   paths (unsorted). Empty when the tree does not exist. *)
let walk_manifests ~cache_root ~domain_name () =
  let root = manifest_dir ~cache_root domain_name in
  let rec walk dir rel acc =
    let* names = readdir_list dir in
    Lwt_list.fold_left_s
      (fun acc name ->
        if
          Filename.check_suffix name ".tmp"
          || name = Name_escape.dir_marker
          || name = Folder_ids.marker_name
        then Lwt.return acc
        else (
          let path = Filename.concat dir name in
          let* is_dir = is_directory path in
          if is_dir then
            let* real = real_dir_name path name in
            walk path (join_rel rel real) acc
          else
            let* content =
              Lwt.catch
                (fun () ->
                  let+ s =
                    Lwt_unix_retry.with_file ~mode:Lwt_io.Input path Lwt_io.read
                  in
                  Some s)
                (fun _ -> Lwt.return_none)
            in
            match content with
              | Some s -> (
                  match Manifest.of_string s with
                    | `Clean m ->
                        Lwt.return (join_rel rel m.Manifest.name :: acc)
                    | `Dirty -> Lwt.return acc
                    | exception _ -> Lwt.return acc)
              | None -> Lwt.return acc))
      acc names
  in
  let* root_ok = is_directory root in
  if root_ok then walk root "" [] else Lwt.return_nil

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

let ensure_manifest_parent ~cache_root ~domain_name ~domain_prefix key =
  let rel = strip_prefix ~domain_prefix key in
  let reldir = match Filename.dirname rel with "." -> "" | d -> d in
  ensure_dirs (manifest_dir ~cache_root domain_name) reldir

let write_manifest ~cache_root ~domain_name ~domain_prefix key data =
  let path = manifest_path ~cache_root ~domain_name ~domain_prefix key in
  let* () =
    ensure_manifest_parent ~cache_root ~domain_name ~domain_prefix key
  in
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
    let* () =
      ensure_manifest_parent ~cache_root ~domain_name ~domain_prefix dst_key
    in
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
