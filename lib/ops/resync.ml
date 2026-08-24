open Lwt.Syntax

type outcome =
  | Full of { manifests : int; failed : int; reason : string }
  | Incremental of { applied : int }

type progress = {
  on_phase : string -> unit;
  on_current : string option -> unit;
}

let no_progress = { on_phase = (fun _ -> ()); on_current = (fun _ -> ()) }

module Make (C : Conf.S) = struct
  module Lk = Logical_key.Make (C)
  module J = Journal.Make (C)
  module Fs = File_store.Make (C)
  module Sq = Sync_queue.Make (C)
  module F = File.Make (C) (Sq)
  module Rp = Replay.Make (C) (F)
  module Tree = Inode_tree.Make (C)

  (* Walks the inode tree through the module that owns the walk, so a resync and
     [tsync mirror] classify a child the same way. *)
  let rebuild_mirror ~parallelism ~progress ~on_manifest () =
    let slots = Lwt_bounded.create ~name:"resync" ~max:(max 1 parallelism) () in
    let count = ref 0 and failed = ref 0 in
    (* Counted, so a store whose manifests all fail to parse cannot resync
       "successfully" writing nothing. *)
    let unusable bkey reason =
      incr failed;
      Log.warn "resync %s: %s" bkey
        (match reason with
          | `Unreadable exn -> Printexc.to_string exn
          | `Unclassifiable (Manifest.Malformed m) ->
              "unreadable manifest: " ^ m
          | `Unclassifiable exn ->
              "unreadable manifest: " ^ Printexc.to_string exn)
    in
    let apply key (entry : Inode_tree.entry) =
      match entry.Inode_tree.body with
        | Inode_tree.Dir m ->
            Folder_ids.write ~cache_root:C.cache_root ~domain_name:C.domain_name
              (Logical_key.path (Logical_key.dir_in key m.Folder.name))
              m
        | Inode_tree.File man ->
            incr count;
            (* Read by backend key, which is hashed: the body is what names
               it. *)
            let file = Logical_key.file_in key (Manifest.recorded_name man) in
            on_manifest (Logical_key.path file);
            F.write_manifest file man
    in
    let visit () key entry =
      let rel = Logical_key.path key in
      progress.on_current (Some (if rel = "" then "/" else rel));
      Lwt.catch
        (fun () -> apply key entry)
        (fun exn ->
          incr failed;
          Log.warn "resync %s: %s" entry.Inode_tree.bkey
            (Printexc.to_string exn);
          Lwt.return_unit)
    in
    let+ () =
      (* The one walk that reads every folder whole and may write, so it is the
         one that leaves each folder's index behind. *)
      Tree.fold_tree ~on_unusable:(`Skip unusable)
        ~refresh_index:(not C.read_only) ~slots ~folder_id:Stored_key.root_id
        ~key:Lk.root visit ()
    in
    (!count, !failed)

  let full_resync ~parallelism ~progress ~on_manifest ~notify reason =
    progress.on_phase "clearing the cache";
    (* Unsynced edits are kept: nothing else holds those bytes. *)
    let* () =
      Cache_layout.clear ~cache_root:C.cache_root ~domain_name:C.domain_name
    in
    progress.on_phase "rebuilding";
    let* manifests, failed =
      rebuild_mirror ~parallelism ~progress ~on_manifest ()
    in
    progress.on_current None;
    progress.on_phase "notifying the daemon";
    (* Only a rebuild that reached everything may say so. Recording the mark
       after a partial walk moves the cursor past folders that were never
       fetched, and nothing revisits them: their files arrive later as journal
       puts, into directories no id names. *)
    if failed = 0 then Fs.write_last_sync_key (J.entry_key ());
    (* After the rebuild, or the daemon re-reads an empty mirror mid-rebuild. *)
    notify ();
    Lwt.return (Full { manifests; failed; reason })

  (* One pass of the same engine the daemon polls with, so the two cannot drift
     apart. *)
  let incremental ~progress () =
    progress.on_phase "applying other clients' entries";
    (* A one-shot command: no mount of ours is running to refresh. *)
    let+ applied = Rp.apply_foreign ~on_changed:(fun _ -> ()) () in
    Incremental { applied }

  let bookmark () = Fs.read_last_sync_key ()

  let run ?(full = false) ?(progress = no_progress) ?(on_manifest = fun _ -> ())
      ?(on_decision = fun _ _ _ -> ()) ~parallelism ~notify () =
    (* Every process serving this domain runs its own upload queue, so recovery
       has one to go through for the journal entry and cursor bump an upload
       owes — the same start {!Domain_engine} does for a daemon. *)
    Sq.start
      ~upload:(fun ~key ~cancel -> F.upload ~cancel key)
      ~on_upload_done:(fun ~key:_ -> Lwt.return_unit);
    progress.on_phase "replaying local records";
    let* () = Rp.reconcile () in
    progress.on_phase "draining uploads";
    let* () = Sq.drain () in
    let* () = Fs.flush_cursor () in
    progress.on_phase "reading the journal";
    let last_sync_key = Fs.read_last_sync_key () in
    let* all_keys = Fs.list_journal_keys () in
    let reason =
      match last_sync_key with
        | _ when full -> Some "--full flag"
        | None -> Some "no bookmark (first run)"
        | Some last ->
            if Journal.Entry_key.cannot_bridge last all_keys then
              Some "bookmark older than oldest journal entry"
            else None
    in
    on_decision last_sync_key all_keys reason;
    match reason with
      | Some reason ->
          full_resync ~parallelism ~progress ~on_manifest ~notify reason
      | None -> incremental ~progress ()

  let client_uuid = J.client_uuid
end
