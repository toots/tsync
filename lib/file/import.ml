open Lwt.Syntax

type status =
  | Imported of int64
  | Skipped_exists
  | Skipped_symlink
  | Failed of string

type summary = {
  imported : int;
  skipped : int;
  skipped_symlinks : int;
  failed : int;
}

module Make (C : Conf.S) = struct
  module R = Remote.Make (C)
  module Fs = File_store.Make (C)
  module St = Store.Make (C) (Layout.Inode.Make (C))

  (* [rel] is excluded when any glob matches either the full relative path or
     the basename, so [node_modules] prunes any directory of that name and
     [*.tmp] excludes any such file anywhere in the tree. *)
  let excluded globs rel =
    List.exists
      (fun g -> Glob.matches g rel || Glob.matches g (Filename.basename rel))
      globs

  (* All directories, files, and symlinks under [src], as relative paths,
     sorted. Entries matching [exclude] are pruned; excluded directories are
     not descended into. Dir-symlinks are not descended into regardless of
     policy (the caller handles them). [seen] guards against cycles. *)
  let walk_source ~exclude src =
    let globs = List.map Glob.of_pattern exclude in
    let seen = Hashtbl.create 16 in
    let rec walk rel acc =
      let dir = if rel = "" then src else Filename.concat src rel in
      let* names =
        Lwt.catch
          (fun () -> Fs_util.readdir_list dir)
          (fun exn ->
            Log.warn "import: cannot read directory %s: %s" dir
              (Printexc.to_string exn);
            Lwt.return [])
      in
      Lwt_list.fold_left_s
        (fun (dirs, files, symlinks) name ->
          let r = if rel = "" then name else rel ^ "/" ^ name in
          if excluded globs r then Lwt.return (dirs, files, symlinks)
          else (
            let abs = Filename.concat src r in
            let* kind = Fs_util.lstat_kind abs in
            match kind with
              | `Dir ->
                  let realp = try Unix.realpath abs with _ -> abs in
                  if Hashtbl.mem seen realp then
                    Lwt.return (dirs, files, symlinks)
                  else (
                    Hashtbl.replace seen realp ();
                    walk r (r :: dirs, files, symlinks))
              | `File -> Lwt.return (dirs, r :: files, symlinks)
              | `Symlink target ->
                  Lwt.return (dirs, files, (r, target) :: symlinks)
              | `Missing -> Lwt.return (dirs, files, symlinks)))
        acc names
    in
    let+ dirs, files, symlinks = walk "" ([], [], []) in
    ( List.sort compare dirs,
      List.sort compare files,
      List.sort (fun (a, _) (b, _) -> compare a b) symlinks )

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

  let import_file ~force_rehash ~src_root rel =
    let key = C.domain_prefix ^ rel in
    let* skip = if force_rehash then Lwt.return_false else exists key in
    if skip then Lwt.return Skipped_exists
    else (
      let src_path = Filename.concat src_root rel in
      let* st = Lwt_unix_retry.stat src_path in
      let* state = R.upload ~key ~src_path ~mtime:st.Unix.st_mtime () in
      let+ () =
        Local.write_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
          ~domain_prefix:C.domain_prefix key (Manifest.to_string state)
      in
      match state with
        | `Clean m -> Imported m.Manifest.size
        | `Dirty -> assert false)

  (* Write a symlink manifest to all backends and the local sidecar. No cache
     entry: there is no file data to cache for a symlink. *)
  let import_symlink ~force_rehash ~src_root rel target =
    let key = C.domain_prefix ^ rel in
    let* skip = if force_rehash then Lwt.return_false else exists key in
    if skip then Lwt.return Skipped_exists
    else (
      let src_path = Filename.concat src_root rel in
      let* st = Lwt_unix_retry.lstat src_path in
      let state =
        Manifest.make_symlink ~name:(Filename.basename rel) ~target
          ~mtime:st.Unix.st_mtime
      in
      let data = Manifest.to_string state in
      let* () = St.put_manifest ~key ~data in
      let* () =
        Local.write_manifest ~cache_root:C.cache_root ~domain_name:C.domain_name
          ~domain_prefix:C.domain_prefix key data
      in
      match state with
        | `Clean m -> Lwt.return (Imported m.Manifest.size)
        | `Dirty -> assert false)

  (* Import every file under [src] into the domain: upload data to all
     backends, write manifest sidecars (no local cache data — files read as
     not cached and are fetched from the backend on demand), and publish a
     single journal entry so other clients pick the files up incrementally.
     Existing keys are skipped.

     Symlink handling is controlled by [C.symlink_policy]:
     - [`Keep]   — store as a first-class symlink object
     - [`Follow] — dereference and upload target content; broken links skipped
     - [`Skip]   — skip and count, no upload *)
  let run ?(exclude = []) ?(force_rehash = false) ?(on_dir = fun ~rel:_ -> ())
      ~src ~on_file () =
    let src =
      let p =
        if Filename.is_relative src then Filename.concat (Sys.getcwd ()) src
        else src
      in
      try Unix.realpath p with _ -> p
    in
    let* dirs, files, symlinks = walk_source ~exclude src in
    let guard rel f =
      Lwt.catch f (fun exn ->
          let msg = Printexc.to_string exn in
          Log.err "import %s: %s" rel msg;
          Lwt.return (Failed msg))
    in
    let* file_statuses =
      Lwt_list.map_s
        (fun rel ->
          let+ status =
            guard rel (fun () -> import_file ~force_rehash ~src_root:src rel)
          in
          on_file ~rel status;
          (rel, status))
        files
    in
    let* symlink_statuses =
      Lwt_list.map_s
        (fun (rel, target) ->
          let* status =
            guard rel (fun () ->
                match C.symlink_policy with
                  | `Keep ->
                      import_symlink ~force_rehash ~src_root:src rel target
                  | `Follow -> (
                      let abs_target =
                        if Filename.is_relative target then
                          Filename.concat
                            (Filename.dirname (Filename.concat src rel))
                            target
                        else target
                      in
                      let* kind = Fs_util.lstat_kind abs_target in
                      match kind with
                        | `Missing -> Lwt.return Skipped_symlink
                        | _ -> import_file ~force_rehash ~src_root:src rel)
                  | `Skip -> Lwt.return Skipped_symlink)
          in
          on_file ~rel status;
          Lwt.return (rel, status))
        symlinks
    in
    let all_statuses = file_statuses @ symlink_statuses in
    (* Under the inode layout every folder needs its own marker (files no longer
       encode their path), so write one for every directory. [dirs] is sorted, so
       parents precede children and id resolution finds them. *)
    let* () =
      Lwt_list.iter_s
        (fun rel ->
          let key = C.domain_prefix ^ rel ^ "/" in
          let* () =
            Local.create_dir ~cache_root:C.cache_root ~domain_name:C.domain_name
              ~domain_prefix:C.domain_prefix key
          in
          let* () = St.put_folder_marker ~key in
          Lwt.return (on_dir ~rel))
        dirs
    in
    let ops =
      List.map (fun d -> `Mkdir (d ^ "/")) dirs
      @ List.filter_map
          (function
            | rel, Imported size -> Some (`Put (rel, size))
            | _, (Skipped_exists | Skipped_symlink | Failed _) -> None)
          all_statuses
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
          (List.filter
             (function _, Imported _ -> true | _ -> false)
             all_statuses);
      skipped =
        List.length
          (List.filter
             (function _, Skipped_exists -> true | _ -> false)
             all_statuses);
      skipped_symlinks =
        List.length
          (List.filter
             (function _, Skipped_symlink -> true | _ -> false)
             all_statuses);
      failed =
        List.length
          (List.filter
             (function _, Failed _ -> true | _ -> false)
             all_statuses);
    }
end
