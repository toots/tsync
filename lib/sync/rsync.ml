open Tsync_core

module Make (C : Engine_ctx.S) = struct
  include Import.Make (C)

  (* 05 §4.5: every domain fact read from the local tree after one arrival,
     every local one from the filesystem; each action runs on the facts its
     decision was made on. *)
  let rsync ?(narrate = Narrate.none) ?(cancelled = Fun.const false)
      ?(move = false) ?(dry_run = false) ~(src : Rsync_plan.endpoint)
      ~(dst : Rsync_plan.endpoint) () : Rsync_plan.report =
    let run = Bulk.run () in
    ignore (run_cycle ~push_now:false ());
    let in_domain rel =
      match kind rel with
        | `Dir -> `Folder
        | `Absent -> `Missing
        | `File -> (
            match local_file rel with
              | Some (Known m) -> `File m
              | _ -> `Missing)
    in
    let hash path cs =
      Fs.with_fd (Fs.openfile path [O_RDONLY]) (fun fd ->
          let size = (Unix.fstat fd).st_size in
          List.init (Chunking.count ~size ~cs) (fun i ->
              let len = Chunking.length ~size ~cs i in
              let buf = Bigstring.create len in
              let n = Fs.pread_full fd buf ~boff:0 ~len ~off:(i * cs) in
              Chunk_key.of_bigstring (Bigstring.sub buf ~off:0 ~len:n)))
    in
    let local_fact path ~(against : Manifest.t option) : Rsync_plan.local =
      match Unix.lstat path with
        | { st_kind = S_LNK; _ } -> Link (Unix.readlink path)
        | { st_kind = S_REG; _ } -> (
            match against with
              | Some m when m.link = None -> Hashed (hash path m.chunk_size)
              | _ -> Unhashed)
        | _ -> Unhashed
    in
    let local_path base rel =
      if rel = "" then base else Filename.concat base rel
    in
    let domain_path base rel = Names.join base rel in
    (* The source's entries, a folder before its content. *)
    let entries =
      match src.side with
        | Local -> (
            let rec walk rel acc =
              let path = local_path src.path rel in
              match Unix.lstat path with
                | { st_kind = S_DIR; _ } ->
                    let names =
                      Array.to_list (Sys.readdir path)
                      |> List.map (fun n ->
                          let dir =
                            try
                              (Unix.lstat (Filename.concat path n)).st_kind
                              = S_DIR
                            with Unix.Unix_error _ -> false
                          in
                          ((if dir then n ^ "/" else n), n))
                      |> List.sort compare
                    in
                    List.fold_left
                      (fun acc (_, n) -> walk (Names.join rel n) acc)
                      ((rel, `Local_dir) :: acc) names
                | _ -> (rel, `Local_file) :: acc
                | exception Unix.Unix_error _ -> (rel, `Missing) :: acc
            in
            match List.rev (walk "" []) with [] -> [("", `Missing)] | l -> l)
        | Domain -> (
            match in_domain src.path with
              | `Missing -> [("", `Missing)]
              | `File m -> [("", `Key m)]
              | `Folder ->
                  let rec walk rel acc =
                    List.fold_left
                      (fun acc (e : entry) ->
                        let p = Names.join rel e.name in
                        if e.is_dir then walk p ((p, `Domain_dir) :: acc)
                        else (
                          match in_domain (Names.join src.path p) with
                            | `File m -> (p, `Key m) :: acc
                            | _ -> acc))
                      acc
                      (list_children (Names.join src.path rel))
                  in
                  ("", `Domain_dir) :: List.rev (walk "" []))
    in
    let target_fact rel ~(against : Manifest.t option) : Rsync_plan.target =
      match dst.side with
        | Local -> (
            let path = local_path dst.path rel in
            match Unix.lstat path with
              | { st_kind = S_DIR; _ } -> Dir_at Local
              | _ -> File_at (local_fact path ~against)
              | exception Unix.Unix_error (ENOENT, _, _) -> Absent Local)
        | Domain -> (
            match in_domain (domain_path dst.path rel) with
              | `Folder -> Dir_at Domain
              | `File m -> Key_at m
              | `Missing -> Absent Domain)
    in
    let total = List.length entries in
    let under dirs rel =
      List.exists (fun dir -> Names.is_under ~dir rel) dirs
    in
    (* 05 §4.5: an edit whose bytes the main has not received is not copied. *)
    let unpublished =
      if src.side <> Domain then []
      else
        List.filter_map
          (fun (p, (e : Tsync_checkout.Staged.edit)) ->
            if e.state = Owed then Some p else None)
          (Tsync_checkout.Staged.edits_under staged src.path)
        |> List.sort_uniq compare
    in
    let skipped_dirs = ref [] in
    let planned =
      List.mapi
        (fun i (rel, s) ->
          Cancel.check cancelled;
          if rel <> "" && under !skipped_dirs rel then
            (rel, Rsync_plan.Skip Under_skipped)
          else if
            List.exists
              (fun u ->
                let p = Names.join src.path rel in
                p = u || Names.is_under ~dir:p u || Names.is_under ~dir:u p)
              unpublished
            && match s with `Local_dir | `Domain_dir -> false | _ -> true
          then (rel, Rsync_plan.Skip Unpublished)
          else (
            Narrate.progress narrate
              ~fraction:(float i /. float (max 1 total))
              "comparing %d of %d: %s" (i + 1) total rel;
            let source : Rsync_plan.source =
              match s with
                | `Missing -> Missing
                | `Local_dir | `Domain_dir -> Dir
                | `Key m -> Key m
                | `Local_file -> File Unhashed
            in
            let target =
              target_fact rel
                ~against:(match source with Key m -> Some m | _ -> None)
            in
            let source : Rsync_plan.source =
              match (source, target) with
                | File _, Key_at d ->
                    File
                      (local_fact (local_path src.path rel) ~against:(Some d))
                | File _, _ ->
                    File (local_fact (local_path src.path rel) ~against:None)
                | s, _ -> s
            in
            let d = Rsync_plan.decide ~move source target in
            (match (source, d) with
              | Dir, Skip _ -> skipped_dirs := rel :: !skipped_dirs
              | _ -> ());
            (rel, d)))
        entries
    in
    List.iter
      (fun p ->
        Narrate.say narrate
          "  %s has edits of this client not yet published: not copied" p)
      unpublished;
    let copied = ref 0 and identical = ref 0 and dirs = ref 0 in
    let skipped = ref [] and failed = ref [] and bytes = ref 0 in
    let done_ = Hashtbl.create 64 in
    let succeed rel n =
      incr copied;
      bytes := !bytes + n;
      Hashtbl.replace done_ rel ()
    in
    let fail rel reason =
      Narrate.say narrate "  %s failed: %s" rel reason;
      failed := (rel, reason) :: !failed
    in
    let blocked = ref [] in
    (* Whether [f] ran to its end. *)
    let attempt rel f =
      if rel <> "" && under !blocked rel then (
        fail rel "its folder could not be created";
        false)
      else if cancelled () then false
      else (
        try
          f ();
          true
        with
          | (Stop.Stopping | Rt.Cancelled) as e -> raise e
          | e ->
              fail rel (Printexc.to_string e);
              false)
    in
    let with_decision pred = List.filter (fun (_, d) -> pred d) planned in
    if not dry_run then (
      List.iter
        (fun (rel, (d : Rsync_plan.decision)) ->
          match d with
            | Skip s -> skipped := (rel, Rsync_plan.skip_name s) :: !skipped
            | Identical ->
                incr identical;
                Hashtbl.replace done_ rel ()
            | _ -> ())
        planned;
      (* Folders first, so nothing lands under a folder that is not there. *)
      List.iter
        (fun (rel, _) ->
          ignore @@ attempt rel
          @@ fun () ->
          match dst.side with
            | Local ->
                Fs.mkdir_p (local_path dst.path rel);
                incr dirs
            | Domain -> (
                match Bulk.folder run (domain_path dst.path rel) with
                  | Ok _ -> incr dirs
                  | Error reason ->
                      blocked := rel :: !blocked;
                      fail rel reason))
        (with_decision (function Make_dir _ -> true | _ -> false));
      let upload rel tp path =
        let sent = ref 0 in
        ignore (Bulk.upload_file ~sent:(fun n -> sent := !sent + n) run tp path);
        succeed rel !sent
      in
      List.iter
        (fun (rel, d) ->
          let tp = domain_path dst.path rel in
          Narrate.progress narrate "copying into the domain: %s" tp;
          ignore
          @@ attempt rel (fun () ->
              match d with
                | Rsync_plan.Copy_manifest m ->
                    Bulk.install run tp m;
                    succeed rel 0
                | _ -> (
                    let path = local_path src.path rel in
                    match (Unix.lstat path, C.symlinks) with
                      | { st_kind = S_LNK; _ }, `Skip ->
                          skipped := (rel, "symlinks are skipped") :: !skipped
                      | { st_kind = S_LNK; _ }, `Keep ->
                          Bulk.install_link run tp ~target:(Unix.readlink path)
                            ~mtime:(Unix.lstat path).st_mtime;
                          succeed rel 0
                      | { st_kind = S_LNK; _ }, `Follow -> (
                          match Unix.stat path with
                            | { st_kind = S_REG; _ } -> upload rel tp path
                            | _ | (exception Unix.Unix_error _) ->
                                skipped :=
                                  (rel, "a dangling symlink") :: !skipped)
                      | _ -> upload rel tp path)))
        (with_decision (function
          | Copy_manifest _ | Upload _ -> true
          | _ -> false));
      (* Downloads into local files, whole or the differing chunks only. *)
      List.iter
        (fun (rel, d) ->
          let path = local_path dst.path rel in
          Narrate.progress narrate "copying out of the domain: %s" path;
          ignore
          @@ attempt rel (fun () ->
              match d with
                | Rsync_plan.Assemble ({ link = Some target; _ } : Manifest.t)
                  ->
                    (try Unix.unlink path
                     with Unix.Unix_error (ENOENT, _, _) -> ());
                    Unix.symlink target path;
                    succeed rel 0
                | Assemble m ->
                    let tmp = Fs.temp_in (Filename.dirname path) in
                    Fun.protect
                      ~finally:(fun () -> Fs.unlink_quiet tmp)
                      (fun () ->
                        Fs.with_fd
                          (Fs.openfile ~perm:0o644 tmp
                             [O_WRONLY; O_CREAT; O_TRUNC])
                          (fun fd ->
                            for i = 0 to m.count - 1 do
                              let b = R.get_chunk (Manifest.key m i) in
                              Fs.pwrite_all fd b ~boff:0
                                ~len:(Bigstring.length b) ~off:(i * m.chunk_size)
                            done;
                            Fs.fsync fd);
                        Unix.utimes tmp m.mtime m.mtime;
                        Unix.rename tmp path);
                    succeed rel m.size
                | Patch_local (m, indices) ->
                    let sent = ref 0 in
                    Fs.with_fd (Fs.openfile path [O_WRONLY]) (fun fd ->
                        List.iter
                          (fun i ->
                            let b = R.get_chunk (Manifest.key m i) in
                            sent := !sent + Bigstring.length b;
                            Fs.pwrite_all fd b ~boff:0 ~len:(Bigstring.length b)
                              ~off:(i * m.chunk_size))
                          indices;
                        Unix.ftruncate fd m.size;
                        Fs.fsync fd);
                    Unix.utimes path m.mtime m.mtime;
                    succeed rel !sent
                | _ -> ()))
        (with_decision (function
          | Assemble _ | Patch_local _ -> true
          | _ -> false));
      List.iter
        (fun (rel, d) ->
          let sp = domain_path src.path rel and tp = domain_path dst.path rel in
          ignore
            (attempt rel (fun () ->
                 match d with
                   | Rsync_plan.Rename_in_domain _ ->
                       rename ~src:sp ~dst:tp ~exclusive:false;
                       Bulk.note_file run sp;
                       Bulk.note_file run tp;
                       succeed rel 0
                   | _ -> ())))
        (with_decision (function Rename_in_domain _ -> true | _ -> false));
      (* A move drops each source whose action ran. *)
      let drops =
        List.filter
          (fun (rel, d) -> Rsync_plan.disposes ~move d && Hashtbl.mem done_ rel)
          planned
      in
      match src.side with
        | Local ->
            List.iter
              (fun (rel, _) ->
                ignore
                  (attempt rel (fun () -> Unix.unlink (local_path src.path rel))))
              drops
        | Domain ->
            List.iter
              (fun (rel, _) ->
                let sp = domain_path src.path rel in
                ignore
                  (attempt rel (fun () ->
                       delete sp;
                       Bulk.note_file run sp)))
              drops);
    let uncommitted = if dry_run then 0 else Bulk.await ~cancelled run in
    {
      Rsync_plan.copied = !copied;
      identical = !identical;
      skipped = List.rev !skipped;
      dirs = !dirs;
      failed = List.rev !failed;
      bytes_moved = !bytes;
      planned;
      unpublished;
      uncommitted;
      cancelled = cancelled ();
    }
end
