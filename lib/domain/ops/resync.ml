type outcome =
  | Full of { manifests : int; failed : int; reason : string }
  | Incremental of { applied : int }

type progress = {
  on_phase : string -> unit;
  on_current : string option -> unit;
}

let no_progress = { on_phase = (fun _ -> ()); on_current = (fun _ -> ()) }

module type SYNC = sig
  type 'a io

  module Queue : Sync_queue.OVER with type 'a io := 'a io
  module Replay : Replay.OVER with type 'a io := 'a io
end

module Over
    (Io : Io.S)
    (Folder_ids : Folder_ids.S with type 'a io := 'a Io.t)
    (Cache : Cache_layout.S with type 'a io := 'a Io.t)
    (Pools : Bounded.S with type 'a io := 'a Io.t)
    (Tree : Inode_tree.OVER with type 'a io := 'a Io.t and type pool := Pools.t)
    (Cursor_of : File_store.OVER with type 'a io := 'a Io.t)
    (Files : File.OVER with type 'a io := 'a Io.t)
    (Checkout : Checkout.OVER with type 'a io := 'a Io.t)
    (Sync : SYNC with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  let iter_p f xs = Io.iter_p f xs

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Lk = Logical_key.Make (C)
    module J = Journal.Make (C)
    module Cursor = Cursor_of.Make (C)
    module F = Files.Make (C)
    module Ck = Checkout.Make (C)
    module Sq = Sync.Queue.Make (C) (F)
    module Rp = Sync.Replay.Make (C) (F)
    module Tree = Tree.Make (C)

    (* Walks the inode tree through the module that owns the walk, so a resync and
       [tsync mirror] classify a child the same way. *)
    let rebuild_mirror ~parallelism ~progress ~on_manifest () =
      let slots = Pools.create ~name:"resync" ~max:(max 1 parallelism) () in
      let count = ref 0 and failed = ref 0 in
      (* Counted, so a store whose manifests all fail to parse cannot resync
         "successfully" writing nothing. *)
      let unusable bkey reason =
        incr failed;
        Log.warn "resync %s: %s"
          (Stored_key.to_string bkey)
          (match reason with
            | `Unreadable exn -> Printexc.to_string exn
            | `Unclassifiable (Manifest.Malformed m) ->
                "unreadable manifest: " ^ m
            | `Unclassifiable exn ->
                "unreadable manifest: " ^ Printexc.to_string exn)
      in
      let apply key (entry : Inode_tree.entry) =
        let* filed = Ck.record ~parent:key entry in
        match entry.Inode_tree.body with
          | Inode_tree.Dir _ -> Io.return ()
          | Inode_tree.File _ ->
              incr count;
              on_manifest (Logical_key.path filed);
              Io.return ()
      in
      let visit () key entry =
        let rel = Logical_key.path key in
        progress.on_current (Some (if rel = "" then "/" else rel));
        Io.catch
          (fun () -> apply key entry)
          (fun exn ->
            incr failed;
            Log.warn "resync %s: %s"
              (Stored_key.to_string entry.Inode_tree.bkey)
              (Printexc.to_string exn);
            Io.return ())
      in
      let+ () =
        (* The one walk that reads every folder whole and may write, so it is the
           one that leaves each folder's index behind. *)
        Tree.fold_tree ~on_unusable:(`Skip unusable)
          ~refresh_index:(not C.read_only) ~slots ~folder_id:Stored_key.root_id
          ~key:Lk.root visit ()
      in
      (!count, !failed)

    let full_resync ~parallelism ~progress ~on_manifest ~notify ~handled reason
        =
      progress.on_phase "clearing the cache";
      (* Unsynced edits are kept: nothing else holds those bytes. *)
      let* () =
        Cache.clear ~cache_root:C.cache_root ~domain_name:C.domain_name
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
      let* () =
        if failed = 0 then begin
          Cursor.write_last_sync_key (J.entry_key ());
          (* The rebuild read what these describe, so they are not applied on
             top of it. *)
          Rp.mark_handled handled
        end
        else Io.return ()
      in
      (* After the rebuild, or the daemon re-reads an empty mirror mid-rebuild. *)
      notify ();
      Io.return (Full { manifests; failed; reason })

    (* One pass of the same engine the daemon polls with, so the two cannot drift
       apart. *)
    let incremental ~progress () =
      progress.on_phase "applying other clients' entries";
      (* A one-shot command: no mount of ours is running to refresh. *)
      let+ applied = Rp.apply_foreign ~on_changed:(fun _ -> ()) () in
      Incremental { applied }

    let bookmark () = Cursor.read_last_sync_key ()

    let run ?(full = false) ?(progress = no_progress)
        ?(on_manifest = fun _ -> ()) ?(on_decision = fun _ _ _ -> ())
        ~parallelism ~notify () =
      (* Every process serving this domain runs its own upload queue, so recovery
         has one to go through for the journal entry and cursor bump an upload
         owes — the same start {!Domain_engine} does for a daemon. *)
      Sq.start ~on_upload_done:(fun ~key:_ -> Io.return ());
      progress.on_phase "replaying local records";
      let* () = Rp.reconcile () in
      progress.on_phase "draining uploads";
      let* () = Sq.drain () in
      let* () = Cursor.flush_cursor () in
      progress.on_phase "reading the journal";
      let last_sync_key = Cursor.read_last_sync_key () in
      let* all_keys = Cursor.list_journal_keys () in
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
            full_resync ~parallelism ~progress ~on_manifest ~notify
              ~handled:all_keys reason
        | None -> incremental ~progress ()

    let client_uuid = J.client_uuid
  end
end
