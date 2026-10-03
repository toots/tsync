open Tsync_core
open Tsync_remote

module Make (C : Engine_ctx.S) = struct
  include Import.Make (C)

  (* 05 §4.5: every domain fact read from the store, every local one from the
     filesystem; each action runs on the facts its decision was made on. *)
  let rsync ?(narrate = Narrate.none) ?(cancelled = Fun.const false)
      ?(move = false) ?(dry_run = false) ~(src : Rsync_plan.endpoint)
      ~(dst : Rsync_plan.endpoint) () : Rsync_plan.report =
    let segs p = if p = "" then [] else String.split_on_char '/' p in
    let in_domain rel = T.find Folder_id.root (segs rel) in
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
              | `Folder id ->
                  ("", `Domain_dir)
                  :: List.rev
                       (T.fold_tree id ~root_path:""
                          (fun acc dir (e : Tree.entry) ->
                            match e.body with
                              | Dir d ->
                                  (Names.join dir d.name, `Domain_dir) :: acc
                              | File f -> (Names.join dir f.name, `Key f) :: acc)
                          []))
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
              | `Folder _ -> Dir_at Domain
              | `File m -> Key_at m
              | `Missing -> Absent Domain)
    in
    let total = List.length entries in
    let under dirs rel =
      List.exists (fun dir -> Names.is_under ~dir rel) dirs
    in
    (* 05 rsync: a file whose local bytes the store has not received yet (a
       staged edit) is not copied; a pending record over bytes the store holds
       (an earlier copy) does not stop it. *)
    let unpublished =
      if src.side <> Domain then []
      else
        List.map fst
          (Tsync_checkout.Staged.edits_under
             (Tsync_checkout.Staged.create ~cache_root:C.cache_root C.domain)
             src.path)
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
    let attempt rel f =
      if rel <> "" && under !blocked rel then
        fail rel "its folder could not be created"
      else if not (cancelled ()) then (
        try f () with
          | (Stop.Stopping | Rt.Cancelled) as e -> raise e
          | e -> fail rel (Printexc.to_string e))
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
          attempt rel (fun () ->
              match dst.side with
                | Local ->
                    Fs.mkdir_p (local_path dst.path rel);
                    incr dirs
                | Domain -> (
                    match Bulk.folder (domain_path dst.path rel) with
                      | Ok _ -> incr dirs
                      | Error reason ->
                          blocked := rel :: !blocked;
                          fail rel reason)))
        (with_decision (function Make_dir _ -> true | _ -> false));
      let upload rel tp path =
        let sent = ref 0 in
        ignore (Bulk.upload_file ~sent:(fun n -> sent := !sent + n) tp path);
        succeed rel !sent
      in
      (* Uploads and copies into the domain, announced as Puts. *)
      let size_of = function
        | Rsync_plan.Copy_manifest (m : Manifest.t) -> m.size
        | _ -> 0
      in
      Bulk.batches ~narrate ~noun:"file" ~cancelled ~queue:uploads
        ~op:(fun (rel, d) ->
          Op.Put
            { path = domain_path dst.path rel; size = size_of d; base = None })
        ~admit:(fun _ -> true)
        ~run:(fun (rel, d) ->
          let tp = domain_path dst.path rel in
          Narrate.progress narrate "copying into the domain: %s" tp;
          attempt rel (fun () ->
              match d with
                | Rsync_plan.Copy_manifest m ->
                    Bulk.publish tp m;
                    succeed rel 0
                | _ -> (
                    let path = local_path src.path rel in
                    match (Unix.lstat path, C.symlinks) with
                      | { st_kind = S_LNK; _ }, `Skip ->
                          skipped := (rel, "symlinks are skipped") :: !skipped
                      | { st_kind = S_LNK; _ }, `Keep ->
                          Bulk.publish_link tp ~target:(Unix.readlink path)
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
          attempt rel (fun () ->
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
      let slot rel =
        match T.find Folder_id.root (segs (Names.parent_of rel)) with
          | `Folder pid -> Some (pid, Names.leaf_of rel)
          | _ -> None
      in
      (* Moves within the domain: the manifest at the destination, the source
         slot deleted, one Rename announced. *)
      Bulk.batches ~narrate ~noun:"move" ~cancelled ~queue:metadata
        ~op:(fun (rel, d) ->
          let size =
            match d with
              | Rsync_plan.Rename_in_domain (m : Manifest.t) -> Some m.size
              | _ -> None
          in
          Op.Rename
            {
              dst = domain_path dst.path rel;
              src = domain_path src.path rel;
              is_dir = false;
              size;
              id = None;
            })
        ~admit:(fun _ -> true)
        ~run:(fun (rel, d) ->
          let sp = domain_path src.path rel and tp = domain_path dst.path rel in
          attempt rel (fun () ->
              match d with
                | Rsync_plan.Rename_in_domain m ->
                    Bulk.publish tp m;
                    Option.iter
                      (fun (pid, leaf) -> ignore (R.delete_slot pid leaf))
                      (slot sp);
                    with_meta (fun () ->
                        with_key sp (fun () -> remove_local_file sp));
                    succeed rel 0
                | _ -> ()))
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
                attempt rel (fun () -> Unix.unlink (local_path src.path rel)))
              drops
        | Domain ->
            Bulk.batches ~narrate ~noun:"removal" ~cancelled ~queue:metadata
              ~op:(fun (rel, _) -> Op.Delete (domain_path src.path rel))
              ~admit:(fun _ -> true)
              ~run:(fun (rel, _) ->
                let sp = domain_path src.path rel in
                attempt rel (fun () ->
                    Option.iter
                      (fun (pid, leaf) -> ignore (R.delete_slot pid leaf))
                      (slot sp);
                    with_meta (fun () ->
                        with_key sp (fun () -> remove_local_file sp))))
              drops);
    {
      Rsync_plan.copied = !copied;
      identical = !identical;
      skipped = List.rev !skipped;
      dirs = !dirs;
      failed = List.rev !failed;
      bytes_moved = !bytes;
      planned;
      unpublished;
      cancelled = cancelled ();
    }
end
