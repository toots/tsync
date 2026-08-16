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
  module Mf = Manifest.Make (C)

  (* [rel] is excluded when any glob matches either the full relative path or
     the basename, so [node_modules] prunes any directory of that name and
     [*.tmp] excludes any such file anywhere in the tree. *)
  let excluded globs rel =
    List.exists
      (fun g -> Glob.matches g rel || Glob.matches g (Filename.basename rel))
      globs

  (* An excluded directory is not descended into, and neither is a dir-symlink
     whatever the policy: the caller handles those. [seen] guards against
     cycles. *)
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
          let r = Key.join rel name in
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
    let* sidecar = Mf.read key in
    match sidecar with
      | Some _ -> Lwt.return_true
      | None ->
          let+ head = Fs.head_manifest_opt ~key in
          Option.is_some head

  let import_file ~force_rehash ~src_root rel =
    let key = C.domain_prefix ^ rel in
    let* skip = if force_rehash then Lwt.return_false else exists key in
    if skip then Lwt.return Skipped_exists
    else (
      let src_path = Filename.concat src_root rel in
      let* st = Lwt_unix_retry.stat src_path in
      let* chunk_size = R.chunk_size () in
      let* state =
        R.upload ~key ~src_path ~mtime:st.Unix.st_mtime ~chunk_size ()
      in
      let+ () = Mf.write key state in
      Imported state.Manifest.size)

  (* No cache entry: a symlink has no file data. *)
  let import_symlink ~force_rehash ~src_root rel target =
    let key = C.domain_prefix ^ rel in
    let* skip = if force_rehash then Lwt.return_false else exists key in
    if skip then Lwt.return Skipped_exists
    else (
      let src_path = Filename.concat src_root rel in
      let* st = Lwt_unix_retry.lstat src_path in
      let name = Filename.basename rel in
      let state = Manifest.make_symlink ~name ~target ~mtime:st.Unix.st_mtime in
      let data = Manifest.to_string ~name state in
      let* () = St.put_manifest ~key ~data in
      let* () = Mf.write key state in
      Lwt.return (Imported state.Manifest.size))

  (* A journal entry is one JSON object per line, so an import records its ops
     where they are already in that form. Held in a list until the end, they and
     the string they encode to grow with the tree rather than with what is in
     flight, which on a small machine is the largest thing the run keeps. *)
  (* A journal entry is one JSON object per line, so an import records its ops
     where they are already in that form. Held in a list until the end, they and
     the string they encode to grow with the tree rather than with what is in
     flight, which on a small machine is the largest thing the run keeps. *)
  module Spool = struct
    let dir = Filename.concat C.cache_root "import"
    let create () = Spool.create ~dir ~name:"journal"
    let add t ops = Spool.append t (Journal.encode ops)

    (* [src] is taken as finished: what it holds is only all of it once its own
       channel has been flushed. *)
    let append t src =
      let* () = Spool.close src in
      Spool.append_file t ~src:(Spool.path src)

    let remove t = Spool.drop t
    let body t = Spool.seal t

    (* A killed import leaves its spool behind with nothing else to reap it. *)
    let reap () = Spool.reap ~dir
  end

  let tally summary = function
    | Imported _ -> { summary with imported = summary.imported + 1 }
    | Skipped_exists -> { summary with skipped = summary.skipped + 1 }
    | Skipped_symlink ->
        { summary with skipped_symlinks = summary.skipped_symlinks + 1 }
    | Failed _ -> { summary with failed = summary.failed + 1 }

  (* Ancestor directory rels, root first ("a/b/c" → ["a"; "a/b"]). *)
  let ancestors rel =
    let rec go acc d =
      if d = "." || d = "/" || d = "" then acc
      else go (d :: acc) (Filename.dirname d)
    in
    go [] (Filename.dirname rel)

  let run ?(only = []) ?(exclude = []) ?(force_rehash = false)
      ?(on_dir = fun ~rel:_ -> ()) ~src ~on_file () =
    let src =
      let p =
        if Filename.is_relative src then Filename.concat (Sys.getcwd ()) src
        else src
      in
      try Unix.realpath p with _ -> p
    in
    let* dirs, files, symlinks = walk_source ~exclude src in
    (* [exclude] was applied during the walk, so this composes as
       (all \ exclude) ∩ only. Empty [only] keeps everything. *)
    let only_globs = List.map Glob.of_pattern only in
    (* [only foo] selects everything under a matching directory, mirroring how
       [exclude foo] prunes one. *)
    let kept rel =
      only = [] || excluded only_globs rel
      || List.exists (excluded only_globs) (ancestors rel)
    in
    let files = List.filter kept files in
    let symlinks = List.filter (fun (rel, _) -> kept rel) symlinks in
    (* Under [only], markers are kept for ancestors of kept entries alone, so
       non-matching branches leave no empty folders. *)
    let dirs =
      if only = [] then dirs
      else (
        let keep = Hashtbl.create 64 in
        List.iter
          (fun rel ->
            List.iter (fun d -> Hashtbl.replace keep d ()) (ancestors rel))
          files;
        List.iter
          (fun (rel, _) ->
            List.iter (fun d -> Hashtbl.replace keep d ()) (ancestors rel))
          symlinks;
        List.filter (Hashtbl.mem keep) dirs)
    in
    let guard rel f =
      Lwt.catch f (fun exn ->
          let msg = Printexc.to_string exn in
          Log.err "import %s: %s" rel msg;
          Lwt.return (Failed msg))
    in
    let counts =
      ref { imported = 0; skipped = 0; skipped_symlinks = 0; failed = 0 }
    in
    let* () = Spool.reap () in
    let* puts = Spool.create () in
    Lwt.finalize
      (fun () ->
        let record ~rel status =
          on_file ~rel status;
          counts := tally !counts status;
          match status with
            | Imported size -> Spool.add puts [`Put (rel, size)]
            | Skipped_exists | Skipped_symlink | Failed _ -> Lwt.return_unit
        in
        let* () =
          Lwt_list.iter_s
            (fun rel ->
              let* status =
                guard rel (fun () ->
                    import_file ~force_rehash ~src_root:src rel)
              in
              record ~rel status)
            files
        in
        let* () =
          Lwt_list.iter_s
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
              record ~rel status)
            symlinks
        in
        (* Every folder needs its own marker under the inode layout, files not
           encoding their path. [dirs] is sorted, so parents precede children
           and id resolution finds them. *)
        let* dir_ids =
          Lwt_list.map_s
            (fun rel ->
              let key = C.domain_prefix ^ rel ^ "/" in
              let* () = Mf.create_dir key in
              let* () = St.put_folder_marker ~key in
              (* Minted by the marker above; read back so the journal entry
                 carries the id a peer resolves the folder by. *)
              let* id =
                Folder_ids.ensure_id ~cache_root:C.cache_root
                  ~domain_name:C.domain_name rel
              in
              on_dir ~rel;
              Lwt.return (rel, id))
            dirs
        in
        let mkdirs =
          List.map (fun (d, id) -> `Mkdir (d ^ "/", Some id)) dir_ids
        in
        (* A peer replays the entry in order and resolves a file's folder by the
           id its marker carries, so the markers go ahead of the puts the passes
           above recorded. *)
        let+ () =
          if mkdirs = [] && !counts.imported = 0 then Lwt.return_unit
          else
            let* entry = Spool.create () in
            Lwt.finalize
              (fun () ->
                let* () =
                  if mkdirs = [] then Lwt.return_unit
                  else Spool.add entry mkdirs
                in
                let* () = Spool.append entry puts in
                let* body = Spool.body entry in
                let* entry_key = Fs.write_journal_entry_body body in
                Fs.bump_cursor entry_key)
              (fun () -> Spool.remove entry)
        in
        !counts)
      (fun () -> Spool.remove puts)
end
