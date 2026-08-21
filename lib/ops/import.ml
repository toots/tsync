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

  (* Where a symlink points, as a path this process can stat. *)
  let target_path ~src rel target =
    if Filename.is_relative target then
      Filename.concat (Filename.dirname (Filename.concat src rel)) target
    else target

  (* What importing this symlink will report as its size, which is what makes
     the plan and the run agree: [`Keep] stores the target string, whose length
     is the lstat size {!Manifest.make_symlink} records; [`Follow] stores the
     target's own bytes; [`Skip] imports nothing. A broken link is skipped
     either way. *)
  let symlink_bytes ~src rel target =
    match C.symlink_policy with
      | `Skip -> Lwt.return 0L
      | `Keep -> Lwt.return (Int64.of_int (String.length target))
      | `Follow -> (
          (* [stat], not [lstat]: a link to a link is followed by the upload
             too, and a broken chain is imported as nothing. *)
          let+ st = Fs_util.stat_opt_large (target_path ~src rel target) in
          match st with Some st -> st.Unix.LargeFile.st_size | None -> 0L)

  (* An excluded directory is not descended into, and neither is a dir-symlink
     whatever the policy: the caller handles those. [seen] guards against
     cycles.

     Entries carry the size their import will report, taken from the lstat the
     walk already does: an import holds its whole listing, so this is a word
     beside a path it is keeping anyway, and the alternative is stat'ing the
     tree a second time to say how big it is. *)
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
              | `File size -> Lwt.return (dirs, (r, size) :: files, symlinks)
              | `Symlink target ->
                  let+ bytes = symlink_bytes ~src r target in
                  (dirs, files, (r, target, bytes) :: symlinks)
              | `Missing -> Lwt.return (dirs, files, symlinks)))
        acc names
    in
    let+ dirs, files, symlinks = walk "" ([], [], []) in
    ( List.sort compare dirs,
      List.sort (fun (a, _) (b, _) -> compare a b) files,
      List.sort (fun (a, _, _) (b, _, _) -> compare a b) symlinks )

  (* A key already in the domain (local sidecar or remote manifest) is never
     overwritten by an import. *)
  let exists key =
    let* sidecar = Mf.read key in
    match sidecar with
      | Some _ -> Lwt.return_true
      | None ->
          let+ head = Fs.head_manifest_opt ~key in
          Option.is_some head

  let import_file ~force_rehash ~on_progress ~src_root rel =
    let key = C.domain_prefix ^ rel in
    let* skip = if force_rehash then Lwt.return_false else exists key in
    if skip then Lwt.return Skipped_exists
    else (
      let src_path = Filename.concat src_root rel in
      let* st = Lwt_unix_retry.stat src_path in
      let* chunk_size = R.chunk_size () in
      let* state =
        R.upload ~key ~src_path ~mtime:st.Unix.st_mtime ~chunk_size
          ~on_progress:(fun ~bytes ~sent ->
            on_progress ~bytes:(Int64.of_int bytes) ~sent)
          ()
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
     where they are already in that form. Spooled to disk rather than held in
     memory, where they and the string they encode grow with the tree rather
     than with what is in flight. *)
  module Spool = struct
    let dir = Filename.concat C.cache_root "import"
    let create () = Spool.create ~dir ~name:"journal"
    let add t ops = Spool.append t (Journal.encode ops)
    let remove t = Spool.drop t
    let body t = Spool.seal t

    (* A killed import leaves its spool behind with nothing else to reap it. *)
    let reap () = Spool.reap ~dir
  end

  (* A deferred replica queues an entry behind the objects it names, so
     covering a whole run with one entry hides everything the run imported from
     that replica's readers until its backlog drains. *)
  let entry_ops = 2000

  (* A count alone bounds nothing a reader can feel: an import of a few hundred
     large files runs for minutes and never reaches the cap, so every peer sees
     the run's folders and none of its files until it ends. *)
  let entry_age = 10.

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
      ?(entry_ops = entry_ops) ?(entry_age = entry_age)
      ?(on_dir = fun ~rel:_ -> ()) ?(on_plan = fun ~files:_ ~bytes:_ -> ())
      ?(on_start = fun ~rel:_ ~size:_ -> ())
      ?(on_progress = fun ~bytes:_ ~sent:_ -> ()) ~src ~on_file () =
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
    let files = List.filter (fun (rel, _) -> kept rel) files in
    let symlinks = List.filter (fun (rel, _, _) -> kept rel) symlinks in
    (* Under [only], markers are kept for ancestors of kept entries alone, so
       non-matching branches leave no empty folders. *)
    let dirs =
      if only = [] then dirs
      else (
        let keep = Hashtbl.create 64 in
        List.iter
          (fun (rel, _) ->
            List.iter (fun d -> Hashtbl.replace keep d ()) (ancestors rel))
          files;
        List.iter
          (fun (rel, _, _) ->
            List.iter (fun d -> Hashtbl.replace keep d ()) (ancestors rel))
          symlinks;
        List.filter (Hashtbl.mem keep) dirs)
    in
    let planned_bytes =
      List.fold_left
        (fun acc (_, size) -> Int64.add acc size)
        (List.fold_left
           (fun acc (_, _, bytes) -> Int64.add acc bytes)
           0L symlinks)
        files
    in
    on_plan
      ~files:(List.length files + List.length symlinks)
      ~bytes:planned_bytes;
    (* Around every per-entry unit of work in both loops, which is what makes it
       the one place that knows what the import is on right now: [on_file] fires
       once an entry is done, and a large file spends its whole life between the
       two. *)
    let guard rel ~size f =
      on_start ~rel ~size;
      Lwt.catch f (fun exn ->
          let msg = Printexc.to_string exn in
          Log.err "import %s: %s" rel msg;
          Lwt.return (Failed msg))
    in
    let counts =
      ref { imported = 0; skipped = 0; skipped_symlinks = 0; failed = 0 }
    in
    let* () = Spool.reap () in
    let* spool = Spool.create () in
    let spool = ref spool in
    let batched = ref 0 in
    let published_at = ref (Unix.gettimeofday ()) in
    (* The spool is sealed to be read back, so what is published is replaced
       rather than reused. Every pass below adds in sequence: an op appended
       in parallel with this would land in a spool already sealed. *)
    let publish () =
      if !batched = 0 then Lwt.return_unit
      else (
        let full = !spool in
        let* fresh = Spool.create () in
        spool := fresh;
        batched := 0;
        published_at := Unix.gettimeofday ();
        Lwt.finalize
          (fun () ->
            let* body = Spool.body full in
            let* entry_key = Fs.write_journal_entry_body body in
            Fs.bump_cursor entry_key)
          (fun () -> Spool.remove full))
    in
    (* One op at a time, so a caller handing over a whole tree's worth at once
       is split the same as a file arriving per call. *)
    let add ops =
      Lwt_list.iter_s
        (fun op ->
          let* () = Spool.add !spool [op] in
          incr batched;
          if
            !batched >= entry_ops
            || Unix.gettimeofday () -. !published_at >= entry_age
          then publish ()
          else Lwt.return_unit)
        ops
    in
    Lwt.finalize
      (fun () ->
        let record ~rel status =
          on_file ~rel status;
          counts := tally !counts status;
          match status with
            | Imported size -> add [`Put (rel, size)]
            | Skipped_exists | Skipped_symlink | Failed _ -> Lwt.return_unit
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
        (* A peer resolves a file's folder by the id its marker carries, so
           every mkdir is published before a put can name the folder. *)
        let* () = if mkdirs = [] then Lwt.return_unit else add mkdirs in
        let* () = publish () in
        let* () =
          Lwt_list.iter_s
            (fun (rel, size) ->
              let* status =
                guard rel ~size (fun () ->
                    import_file ~force_rehash ~on_progress ~src_root:src rel)
              in
              record ~rel status)
            files
        in
        let* () =
          Lwt_list.iter_s
            (fun (rel, target, bytes) ->
              let* status =
                guard rel ~size:bytes (fun () ->
                    match C.symlink_policy with
                      | `Keep ->
                          import_symlink ~force_rehash ~src_root:src rel target
                      | `Follow -> (
                          let* kind =
                            Fs_util.lstat_kind (target_path ~src rel target)
                          in
                          match kind with
                            | `Missing -> Lwt.return Skipped_symlink
                            | _ ->
                                import_file ~force_rehash ~on_progress
                                  ~src_root:src rel)
                      | `Skip -> Lwt.return Skipped_symlink)
              in
              record ~rel status)
            symlinks
        in
        let+ () = publish () in
        !counts)
      (fun () -> Spool.remove !spool)
end
