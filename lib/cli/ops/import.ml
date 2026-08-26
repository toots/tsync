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

module Make (C : Conf_lwt.S) = struct
  module Lk = Logical_key.Make (C)
  module R = Remote.Make (C)
  module Fs = File_store.Make (C)
  module St = Store.Make (C) (Layout_lwt.Inode.Make (C))
  module Mf = Manifests_lwt.Make (C)
  module Ck = Checkout_lwt.Make (C)
  module Mfs = Staged_lwt.Manifest.Make (C)

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
          let+ st = Io_lwt.Fs.stat_opt_large (target_path ~src rel target) in
          match st with Some st -> st.Unix.LargeFile.st_size | None -> 0L)

  (* The tree an import will walk, spilled to disk and read back mapped rather
     than held: a listing is the tree's length, and a million paths is a hundred
     megabytes standing for the whole run before a byte is uploaded. *)
  let spool_dir = Filename.concat C.cache_root "import"

  type plan = {
    dirs : string Listing_lwt.t;
    files : (string * int64) Listing_lwt.t;
    symlinks : (string * string * int64) Listing_lwt.t;
    bytes : int64;
  }

  (* An excluded directory is not descended into, and neither is a dir-symlink
     whatever the policy: the caller handles those. [seen] guards against cycles
     and is the one thing here that grows with the tree, at an entry per
     directory rather than per file.

     Names are sorted with a directory's key carrying its separator, so entries
     come out in the order a sort of every path would give: what orders two
     paths is their first differing component, and ["a-b"] precedes ["a/x"] on
     either reading. *)
  let walk_source ~only ~exclude ~src plan =
    let ex = List.map Glob.of_pattern exclude in
    let on = List.map Glob.of_pattern only in
    let seen = Hashtbl.create 16 in
    let bytes = ref 0L in
    (* Under [only] a folder marker belongs to an ancestor of a kept entry and
       to nothing else, so the directories walked into are held here until one
       turns up beneath them. *)
    let pending = ref [] in
    let flush () =
      let held = List.rev !pending in
      pending := [];
      Lwt_list.iter_s
        (fun rel ->
          Listing_lwt.add plan.dirs [(fun b -> Listing_lwt.str b rel)])
        held
    in
    let rec walk rel ~selected =
      let dir = if rel = "" then src else Filename.concat src rel in
      let* names =
        Lwt.catch
          (fun () -> Io_lwt.Fs.readdir_list dir)
          (fun exn ->
            Log.warn "import: cannot read directory %s: %s" dir
              (Printexc.to_string exn);
            Lwt.return [])
      in
      let* entries =
        Lwt_list.filter_map_s
          (fun name ->
            let r = Logical_key.path (Logical_key.file_in (Lk.dir rel) name) in
            if excluded ex r then Lwt.return_none
            else
              let+ kind = Io_lwt.Fs.lstat_kind (Filename.concat src r) in
              match kind with
                | `Missing -> None
                | (`Dir | `File _ | `Symlink _) as kind ->
                    let key = match kind with `Dir -> r ^ "/" | _ -> r in
                    Some (key, r, kind))
          names
      in
      let entries =
        List.sort (fun (a, _, _) (b, _, _) -> compare a b) entries
      in
      Lwt_list.iter_s
        (fun (_, r, kind) ->
          let kept = only = [] || selected || excluded on r in
          match kind with
            | `Dir ->
                let realp =
                  try Unix.realpath (Filename.concat src r) with _ -> r
                in
                if Hashtbl.mem seen realp then Lwt.return_unit
                else (
                  Hashtbl.replace seen realp ();
                  pending := r :: !pending;
                  let* () = if only = [] then flush () else Lwt.return_unit in
                  let* () = walk r ~selected:kept in
                  (match !pending with
                    | held :: rest when held = r -> pending := rest
                    | _ -> ());
                  Lwt.return_unit)
            | `File size when kept ->
                let* () = flush () in
                bytes := Int64.add !bytes size;
                Listing_lwt.add plan.files
                  [
                    (fun b -> Listing_lwt.str b r);
                    (fun b -> Listing_lwt.int64 b size);
                  ]
            | `Symlink target when kept ->
                let* () = flush () in
                let* n = symlink_bytes ~src r target in
                bytes := Int64.add !bytes n;
                Listing_lwt.add plan.symlinks
                  [
                    (fun b -> Listing_lwt.str b r);
                    (fun b -> Listing_lwt.str b target);
                    (fun b -> Listing_lwt.int64 b n);
                  ]
            | `File _ | `Symlink _ -> Lwt.return_unit)
        entries
    in
    let+ () = walk "" ~selected:false in
    { plan with bytes = !bytes }

  let plan_source ~only ~exclude ~src =
    let* dirs =
      Listing_lwt.create ~dir:spool_dir ~name:"dirs"
        ~decode:Listing_lwt.read_string
    in
    let* files =
      Listing_lwt.create ~dir:spool_dir ~name:"files" ~decode:(fun body pos ->
          let rel = Listing_lwt.read_string body pos in
          (rel, Listing_lwt.read_int64 body pos))
    in
    let* symlinks =
      Listing_lwt.create ~dir:spool_dir ~name:"symlinks"
        ~decode:(fun body pos ->
          let rel = Listing_lwt.read_string body pos in
          let target = Listing_lwt.read_string body pos in
          (rel, target, Listing_lwt.read_int64 body pos))
    in
    walk_source ~only ~exclude ~src { dirs; files; symlinks; bytes = 0L }

  (* A key already in the domain (local sidecar or remote manifest) is never
     overwritten by an import. *)
  let exists key =
    let* sidecar = Mf.published key in
    match sidecar with
      | Some _ -> Lwt.return_true
      | None ->
          let+ head = Fs.head_manifest_opt ~key in
          Option.is_some head

  let import_file ~force_rehash ~on_progress ~src_root rel =
    let key = Lk.file rel in
    let* skip = if force_rehash then Lwt.return_false else exists key in
    if skip then Lwt.return Skipped_exists
    else (
      let src_path = Filename.concat src_root rel in
      let* st = Io_lwt.Retry.stat src_path in
      let* chunk_size = R.chunk_size () in
      let* state =
        R.upload ~key ~src_path ~mtime:st.Unix.st_mtime ~chunk_size
          ~on_progress:(fun ~bytes ~sent ->
            on_progress ~bytes:(Int64.of_int bytes) ~sent)
          ()
      in
      let+ () = Mf.write key state in
      Imported (Manifest.size state))

  (* No cache entry: a symlink has no file data. *)
  let import_symlink ~force_rehash ~src_root rel target =
    let key = Lk.file rel in
    let* skip = if force_rehash then Lwt.return_false else exists key in
    if skip then Lwt.return Skipped_exists
    else (
      let src_path = Filename.concat src_root rel in
      let* st = Io_lwt.Retry.lstat src_path in
      let name = Filename.basename rel in
      let state = Manifest.make_symlink ~name ~target ~mtime:st.Unix.st_mtime in
      let* () = St.put_manifest ~key ~data:(Manifest.body ~name state) in
      let* () = Mf.write key state in
      Lwt.return (Imported (Manifest.size state)))

  (* A journal entry is one JSON object per line, so an import records its ops
     where they are already in that form. Spooled to disk rather than held in
     memory, where they and the string they encode grow with the tree rather
     than with what is in flight. *)
  module Spool = struct
    let create () = Spool_lwt.create ~dir:spool_dir ~name:"journal"
    let add t ops = Spool_lwt.append t (Journal.encode ops)
    let remove t = Spool_lwt.drop t
    let body t = Spool_lwt.seal t
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
    let* () = Listing_lwt.reap ~dir:spool_dir in
    let* plan = plan_source ~only ~exclude ~src in
    on_plan
      ~files:(Listing_lwt.count plan.files + Listing_lwt.count plan.symlinks)
      ~bytes:plan.bytes;
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
           encoding their path. The walk emits a parent before its children, so
           id resolution finds them. *)
        let* () =
          Listing_lwt.iter plan.dirs (fun rel ->
              let key = Lk.dir rel in
              let* () = Ck.create_dir key in
              let* () = St.put_folder_marker ~key in
              (* Minted by the marker above; read back so the journal entry
                 carries the id a peer resolves the folder by. *)
              let* id =
                Folder_ids_lwt.ensure_id ~cache_root:C.cache_root
                  ~domain_name:C.domain_name (Lk.dir rel)
              in
              on_dir ~rel;
              add [`Mkdir (rel, Some id)])
        in
        (* A peer resolves a file's folder by the id its marker carries, so
           every mkdir is published before a put can name the folder. *)
        let* () = publish () in
        let* () =
          Listing_lwt.iter plan.files (fun (rel, size) ->
              let* status =
                guard rel ~size (fun () ->
                    import_file ~force_rehash ~on_progress ~src_root:src rel)
              in
              record ~rel status)
        in
        let* () =
          Listing_lwt.iter plan.symlinks (fun (rel, target, bytes) ->
              let* status =
                guard rel ~size:bytes (fun () ->
                    match C.symlink_policy with
                      | `Keep ->
                          import_symlink ~force_rehash ~src_root:src rel target
                      | `Follow -> (
                          let* kind =
                            Io_lwt.Fs.lstat_kind (target_path ~src rel target)
                          in
                          match kind with
                            | `Missing -> Lwt.return Skipped_symlink
                            | _ ->
                                import_file ~force_rehash ~on_progress
                                  ~src_root:src rel)
                      | `Skip -> Lwt.return Skipped_symlink)
              in
              record ~rel status)
        in
        let* () = publish () in
        (* No queue settles behind an import and [Backend_lwt.drain] does not
           reach the cursor, so a bump still held back when this returns is one
           no peer goes looking for. *)
        let+ () = Fs.flush_cursor () in
        !counts)
      (fun () ->
        let* () = Listing_lwt.drop plan.dirs in
        let* () = Listing_lwt.drop plan.files in
        let* () = Listing_lwt.drop plan.symlinks in
        Spool.remove !spool)
end
