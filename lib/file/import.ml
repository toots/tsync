open Lwt.Syntax

type status = Imported of int64 | Skipped_exists
type summary = { imported : int; skipped : int }

module Make (C : Conf.S) = struct
  module R = Remote.Make (C)
  module Fs = File_store.Make (C)

  (* [rel] is excluded when any glob matches either the full relative path or
     the basename, so [node_modules] prunes any directory of that name and
     [*.tmp] excludes any such file anywhere in the tree. *)
  let excluded globs rel =
    List.exists
      (fun g -> Glob.matches g rel || Glob.matches g (Filename.basename rel))
      globs

  (* All directories and files under [src], as relative paths, sorted.
     Entries matching [exclude] are pruned; excluded directories are not
     descended into. *)
  let walk_source ~exclude src =
    let globs = List.map Glob.of_pattern exclude in
    let rec walk rel acc =
      let dir = if rel = "" then src else Filename.concat src rel in
      let* names = Fs_util.readdir_list dir in
      Lwt_list.fold_left_s
        (fun (dirs, files) name ->
          let r = if rel = "" then name else rel ^ "/" ^ name in
          if excluded globs r then Lwt.return (dirs, files)
          else
            let* is_dir = Fs_util.is_directory (Filename.concat src r) in
            if is_dir then walk r (r :: dirs, files)
            else Lwt.return (dirs, r :: files))
        acc names
    in
    let+ dirs, files = walk "" ([], []) in
    (List.sort compare dirs, List.sort compare files)

  (* A key already in the domain (local sidecar or remote manifest) is never
     overwritten by an import. *)
  let exists key =
    let* sidecar =
      Local.read_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
        ~domain_prefix:C.domain_prefix key
    in
    match sidecar with
      | Some _ -> Lwt.return_true
      | None ->
          let+ head = Fs.head_opt ~key in
          Option.is_some head

  let import_file ~src_root rel =
    let key = C.domain_prefix ^ rel in
    let* skip = exists key in
    if skip then Lwt.return Skipped_exists
    else (
      let src_path = Filename.concat src_root rel in
      let* st = Lwt_unix.stat src_path in
      let* state = R.upload ~key ~src_path ~mtime:st.Unix.st_mtime () in
      let* () =
        Local.write_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
          ~domain_prefix:C.domain_prefix key (Manifest.to_string state)
      in
      (* Symlink the source file into the cache instead of copying: the file
         reads as cached at zero data cost, and evicting it just removes the
         link. If the source is later moved, the dangling link makes the file
         read as not cached and it is re-fetched from the backend. *)
      let cache_path =
        Local.cache_path ~cache_root:C.cache_root ~domain_name:C.domain_name
          ~domain_prefix:C.domain_prefix key
      in
      let* () = Local.ensure_parent_dir cache_path in
      let* () =
        Lwt.catch
          (fun () -> Lwt_unix.unlink cache_path)
          (function Unix.Unix_error _ -> Lwt.return_unit | e -> Lwt.fail e)
      in
      let+ () = Lwt_unix.symlink src_path cache_path in
      match state with
        | `Clean m -> Imported m.Manifest.size
        | `Dirty -> assert false)

  (* Import every file under [src] into the domain: upload data to all
     backends, write manifest sidecars (data stays in [src], symlinked into
     the cache), and publish a single journal entry so other clients pick the
     files up incrementally. Existing keys are skipped. *)
  let run ?(exclude = []) ~src ~on_file () =
    let src =
      if Filename.is_relative src then Filename.concat (Sys.getcwd ()) src
      else src
    in
    let* dirs, files = walk_source ~exclude src in
    let* () =
      Lwt_list.iter_s
        (fun rel ->
          let key = C.domain_prefix ^ rel ^ "/" in
          let* () =
            Local.create_dir ~cache_root:C.cache_root ~domain_name:C.domain_name
              ~domain_prefix:C.domain_prefix key
          in
          Fs.create_directory ~key)
        dirs
    in
    let* statuses =
      Lwt_list.map_s
        (fun rel ->
          let+ status = import_file ~src_root:src rel in
          on_file ~rel status;
          (rel, status))
        files
    in
    let ops =
      List.map (fun d -> `Mkdir (d ^ "/")) dirs
      @ List.filter_map
          (function
            | rel, Imported size -> Some (`Put (rel, size))
            | _, Skipped_exists -> None)
          statuses
    in
    let+ () =
      if ops = [] then Lwt.return_unit
      else
        let* entry_key = Fs.write_journal_entry ops in
        Fs.bump_cursor entry_key
    in
    {
      imported =
        List.length
          (List.filter (function _, Imported _ -> true | _ -> false) statuses);
      skipped =
        List.length
          (List.filter
             (function _, Skipped_exists -> true | _ -> false)
             statuses);
    }
end
