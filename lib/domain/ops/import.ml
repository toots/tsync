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

module Over
    (Io : Io.S)
    (Files : Fs.S with type 'a io := 'a Io.t)
    (Syscalls : Syscalls.S with type 'a io := 'a Io.t)
    (Spool : Listing.SPOOL with type 'a io := 'a Io.t)
    (Folder_ids : Folder_ids.S with type 'a io := 'a Io.t)
    (Objects : Remote.OVER with type 'a io := 'a Io.t)
    (Store : Store.INODE with type 'a io := 'a Io.t)
    (Cursor_of : File_store.OVER with type 'a io := 'a Io.t)
    (Mirror : Manifests.OVER with type 'a io := 'a Io.t)
    (Checkout : Checkout.OVER with type 'a io := 'a Io.t) =
struct
  module Listing = struct
    include Listing
    include Listing.Make (Io) (Spool)
  end

  module Pub =
    Publish.Over (Io) (Syscalls) (Spool) (Folder_ids) (Objects) (Store)
      (Cursor_of)
      (Mirror)
      (Checkout)

  open Io_syntax.Make (Io)

  let iter_p f xs = Io.iter_p f xs

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Lk = Logical_key.Make (C)
    module Cursor = Cursor_of.Make (C)
    module Mf = Mirror.Make (C)
    module P = Pub.Make (C)

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
        | `Skip -> Io.return 0L
        | `Keep -> Io.return (Int64.of_int (String.length target))
        | `Follow -> (
            (* [stat], not [lstat]: a link to a link is followed by the upload
               too, and a broken chain is imported as nothing. *)
            let+ st = Files.stat_opt_large (target_path ~src rel target) in
            match st with Some st -> st.Unix.LargeFile.st_size | None -> 0L)

    (* The tree an import will walk, spilled to disk and read back mapped rather
       than held: a listing is the tree's length, and a million paths is a hundred
       megabytes standing for the whole run before a byte is uploaded. *)
    let spool_dir = Filename.concat C.cache_root "import"

    type plan = {
      dirs : string Listing.t;
      files : (string * int64) Listing.t;
      symlinks : (string * string * int64) Listing.t;
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
        iter_s
          (fun rel -> Listing.add plan.dirs [(fun b -> Listing.str b rel)])
          held
      in
      let rec walk rel ~selected =
        let dir = if rel = "" then src else Filename.concat src rel in
        let* names =
          Io.catch
            (fun () -> Files.readdir_list dir)
            (fun exn ->
              Log.warn "import: cannot read directory %s: %s" dir
                (Printexc.to_string exn);
              Io.return [])
        in
        let* entries =
          filter_map_s
            (fun name ->
              let r =
                Logical_key.path (Logical_key.file_in (Lk.dir rel) name)
              in
              if excluded ex r then Io.return None
              else
                let+ kind = Files.lstat_kind (Filename.concat src r) in
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
        iter_s
          (fun (_, r, kind) ->
            let kept = only = [] || selected || excluded on r in
            match kind with
              | `Dir ->
                  let realp =
                    try Unix.realpath (Filename.concat src r) with _ -> r
                  in
                  if Hashtbl.mem seen realp then Io.return ()
                  else (
                    Hashtbl.replace seen realp ();
                    pending := r :: !pending;
                    let* () = if only = [] then flush () else Io.return () in
                    let* () = walk r ~selected:kept in
                    (match !pending with
                      | held :: rest when held = r -> pending := rest
                      | _ -> ());
                    Io.return ())
              | `File size when kept ->
                  let* () = flush () in
                  bytes := Int64.add !bytes size;
                  Listing.add plan.files
                    [
                      (fun b -> Listing.str b r); (fun b -> Listing.int64 b size);
                    ]
              | `Symlink target when kept ->
                  let* () = flush () in
                  let* n = symlink_bytes ~src r target in
                  bytes := Int64.add !bytes n;
                  Listing.add plan.symlinks
                    [
                      (fun b -> Listing.str b r);
                      (fun b -> Listing.str b target);
                      (fun b -> Listing.int64 b n);
                    ]
              | `File _ | `Symlink _ -> Io.return ())
          entries
      in
      let+ () = walk "" ~selected:false in
      { plan with bytes = !bytes }

    let plan_source ~only ~exclude ~src =
      let* dirs =
        Listing.create ~dir:spool_dir ~name:"dirs" ~decode:Listing.read_string
      in
      let* files =
        Listing.create ~dir:spool_dir ~name:"files" ~decode:(fun body pos ->
            let rel = Listing.read_string body pos in
            (rel, Listing.read_int64 body pos))
      in
      let* symlinks =
        Listing.create ~dir:spool_dir ~name:"symlinks" ~decode:(fun body pos ->
            let rel = Listing.read_string body pos in
            let target = Listing.read_string body pos in
            (rel, target, Listing.read_int64 body pos))
      in
      walk_source ~only ~exclude ~src { dirs; files; symlinks; bytes = 0L }

    (* A key already in the domain (local sidecar or remote manifest) is never
       overwritten by an import. *)
    let exists key =
      let* sidecar = Mf.published key in
      match sidecar with
        | Some _ -> Io.return true
        | None ->
            let+ head = Cursor.head_manifest_opt ~key in
            Option.is_some head

    let import_file ~force_rehash ~on_progress ~src_root rel =
      let key = Lk.file rel in
      let* skip = if force_rehash then Io.return false else exists key in
      if skip then Io.return Skipped_exists
      else
        let+ state =
          P.file
            ~on_progress:(fun ~bytes ~sent ->
              on_progress ~bytes:(Int64.of_int bytes) ~sent)
            ~src_path:(Filename.concat src_root rel)
            key
        in
        Imported (Manifest.size state)

    let import_symlink ~force_rehash ~src_root rel target =
      let key = Lk.file rel in
      let* skip = if force_rehash then Io.return false else exists key in
      if skip then Io.return Skipped_exists
      else
        let* st = Syscalls.lstat (Filename.concat src_root rel) in
        let+ state = P.symlink ~target ~mtime:st.Unix.st_mtime key in
        Imported (Manifest.size state)

    let tally summary = function
      | Imported _ -> { summary with imported = summary.imported + 1 }
      | Skipped_exists -> { summary with skipped = summary.skipped + 1 }
      | Skipped_symlink ->
          { summary with skipped_symlinks = summary.skipped_symlinks + 1 }
      | Failed _ -> { summary with failed = summary.failed + 1 }

    let run ?(only = []) ?(exclude = []) ?(force_rehash = false)
        ?(entry_ops = Publish.entry_ops) ?(entry_age = Publish.entry_age)
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
      let* () = Listing.reap ~dir:spool_dir in
      let* plan = plan_source ~only ~exclude ~src in
      on_plan
        ~files:(Listing.count plan.files + Listing.count plan.symlinks)
        ~bytes:plan.bytes;
      (* Around every per-entry unit of work in both loops, which is what makes it
         the one place that knows what the import is on right now: [on_file] fires
         once an entry is done, and a large file spends its whole life between the
         two. *)
      let guard rel ~size f =
        on_start ~rel ~size;
        Io.catch f (fun exn ->
            let msg = Printexc.to_string exn in
            Log.err "import %s: %s" rel msg;
            Io.return (Failed msg))
      in
      let counts =
        ref { imported = 0; skipped = 0; skipped_symlinks = 0; failed = 0 }
      in
      let* batch =
        P.Batch.create ~ops:entry_ops ~age:entry_age ~dir:spool_dir ()
      in
      let add = P.Batch.add batch in
      let publish () = P.Batch.publish batch in
      Io.finalize
        (fun () ->
          let record ~rel status =
            on_file ~rel status;
            counts := tally !counts status;
            match status with
              | Imported size -> add [`Put (rel, size)]
              | Skipped_exists | Skipped_symlink | Failed _ -> Io.return ()
          in
          (* Every folder needs its own marker under the inode layout, files not
             encoding their path. The walk emits a parent before its children, so
             id resolution finds them. *)
          let* () =
            Listing.iter plan.dirs (fun rel ->
                let* id = P.dir (Lk.dir rel) in
                on_dir ~rel;
                add [`Mkdir (rel, Some id)])
          in
          (* A peer resolves a file's folder by the id its marker carries, so
             every mkdir is published before a put can name the folder. *)
          let* () = publish () in
          let* () =
            Listing.iter plan.files (fun (rel, size) ->
                let* status =
                  guard rel ~size (fun () ->
                      import_file ~force_rehash ~on_progress ~src_root:src rel)
                in
                record ~rel status)
          in
          let* () =
            Listing.iter plan.symlinks (fun (rel, target, bytes) ->
                let* status =
                  guard rel ~size:bytes (fun () ->
                      match C.symlink_policy with
                        | `Keep ->
                            import_symlink ~force_rehash ~src_root:src rel
                              target
                        | `Follow -> (
                            let* kind =
                              Files.lstat_kind (target_path ~src rel target)
                            in
                            match kind with
                              | `Missing -> Io.return Skipped_symlink
                              | _ ->
                                  import_file ~force_rehash ~on_progress
                                    ~src_root:src rel)
                        | `Skip -> Io.return Skipped_symlink)
                in
                record ~rel status)
          in
          let* () = publish () in
          (* No queue settles behind an import and [Backend.drain] does not
             reach the cursor, so a bump still held back when this returns is one
             no peer goes looking for. *)
          let+ () = Cursor.flush_cursor () in
          !counts)
        (fun () ->
          let* () = Listing.drop plan.dirs in
          let* () = Listing.drop plan.files in
          let* () = Listing.drop plan.symlinks in
          P.Batch.drop batch)
  end
end
