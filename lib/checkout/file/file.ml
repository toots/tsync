open Lwt.Syntax

module type JOURNAL = sig
  val write_journal_entry :
    ?entry_key:Journal.Entry_key.t ->
    Journal.op list ->
    Journal.Entry_key.t Lwt.t

  val bump_cursor : Journal.Entry_key.t -> unit Lwt.t
  val rename_file : src_key:Logical_key.t -> dst_key:Logical_key.t -> unit Lwt.t
  val head_manifest_opt : key:Logical_key.t -> Backend.file_entry option Lwt.t
end

module type OBJECTS = sig
  val put_manifest : key:Logical_key.t -> data:Bigstring.t -> unit Lwt.t
  val delete_manifest : key:Logical_key.t -> unit Lwt.t
  val put_folder_marker : key:Logical_key.t -> unit Lwt.t
  val get_object : bkey:Stored_key.t -> string Lwt.t
  val put_raw : bkey:Stored_key.t -> data:string -> unit Lwt.t
  val delete_raw : bkey:Stored_key.t -> unit Lwt.t
end

module type VERSIONS = sig
  val version_dir : key:Logical_key.t -> Stored_key.t option Lwt.t
  val save_version : key:Logical_key.t -> unit Lwt.t
  val list_versions : key:Logical_key.t -> Backend.file_entry list Lwt.t
  val get_version : vkey:Stored_key.t -> string Lwt.t
end

(* What the sending pool needs of the file operations, and what it tells them
   in return. *)
module type Owing = sig
  val record_key : Wal.record -> Logical_key.t option
  val record_size : Wal.record -> int64
  val upload : ?cancel:bool ref -> Logical_key.t -> unit Lwt.t
  val set_in_flight : (unit -> Logical_key.t list) -> unit
  val set_canceller : (Logical_key.t -> bool) -> unit
end

module Make_with_layout
    (C : Conf.S)
    (L : Layout.S)
    (Fs : JOURNAL)
    (St : OBJECTS)
    (Hs : VERSIONS)
    (R : Remote.S) =
struct
  module Lk = Logical_key.Make (C)
  module J = Journal.Make (C)
  module W = Wal_lwt.Make (C)

  type t = Logical_key.t

  (* Metadata mutations (delete/mkdir/rmdir/rename/revert, foreign-op
     application) are serialized; reads, downloads and uploads stay concurrent.
     ponytail: one global metadata lock; switch to per-key locks only if
     unrelated metadata ops measurably contend. *)
  let meta_mutex = Io_lwt.Lock.mutex ()
  let with_meta f = Io_lwt.Lock.with_lock meta_mutex f
  let meta_locked () = Io_lwt.Lock.is_locked meta_mutex
  let meta_waiters () = Io_lwt.Lock.has_waiters meta_mutex
  let rel_key = Logical_key.path

  (* [Mf] is the local mirror; [St] the store's own copy, which takes logical
     keys and maps them to backend keys through the layout scheme. *)
  module Mf = Manifests.Make (C)
  module Ck = Checkout.Make (C)
  module Mfs = Staged_manifest.Make (C)
  module D = Data.Make (C) (R)

  (* The file a record is about, and what it will cost to send. Both derived
     from the ops rather than carried alongside them, so the two cannot disagree
     about which file a record names.

     The op says whether it names a folder, so the key it yields does too: a
     directory rename read back as a file publishes an entry a peer replays as
     one. *)
  let op_key = function
    | `Put (k, _) | `Delete k -> Lk.file k
    | `Mkdir (k, _) | `Rmdir (k, _) -> Lk.dir k
    | `Rename { Journal.dst; is_dir; _ } ->
        if is_dir then Lk.dir dst else Lk.file dst

  let record_key (r : Wal.record) =
    match r.Wal.ops with op :: _ -> Some (op_key op) | [] -> None

  (* Only a [`Put] carries bytes; the other ops are metadata the backend answers
     in one round trip. *)
  let record_size (r : Wal.record) =
    List.fold_left
      (fun total op ->
        match op with `Put (_, size) -> Int64.add total size | _ -> total)
      0L r.Wal.ops

  (* Which files are being sent right now, and how to stop one, are the sending
     pool's to know; this is where it says so. Cancelling is not only reported:
     a write to a file being sent must stop the send, or it publishes a manifest
     for content torn out from under it. *)
  let in_flight_keys : (unit -> Logical_key.t list) ref = ref (fun () -> [])
  let cancel_send : (Logical_key.t -> bool) ref = ref (fun _ -> false)
  let set_in_flight f = in_flight_keys := f
  let set_canceller f = cancel_send := f
  let cancel_upload key = !cancel_send key
  let manifest_path key = Mf.path key
  let published_here key : Manifest.t option Lwt.t = Mf.published key
  let published = D.published
  let write_manifest key (state : Manifest.t) = Mf.write key state
  let delete_manifest key = Mf.delete key
  let upload ?cancel key = D.sync key ?cancel ()

  (* Populates the chunk store only; produces no file. *)
  let ensure_cached = D.ensure_local
  let assemble_to = D.assemble_to
  let fetch_range = D.fetch_range

  (* The manifest carries only size and mtime; inode, owner and link count are
     synthesized. *)
  let stat_of ~kind ~perm ~nlink ~size ~mtime =
    Unix.LargeFile.
      {
        st_dev = 0;
        st_ino = 0;
        st_kind = kind;
        st_perm = perm;
        st_nlink = nlink;
        st_uid = Unix.getuid ();
        st_gid = Unix.getgid ();
        st_rdev = 0;
        st_size = size;
        st_atime = Unix.gettimeofday ();
        st_mtime = mtime;
        st_ctime = mtime;
      }

  let file_stat size mtime =
    stat_of ~kind:Unix.S_REG ~perm:0o644 ~nlink:1 ~size ~mtime

  (* POSIX: a symlink's size is its target's byte length. *)
  let symlink_stat target mtime =
    stat_of ~kind:Unix.S_LNK ~perm:0o777 ~nlink:1
      ~size:(Int64.of_int (String.length target))
      ~mtime

  let dir_stat () =
    stat_of ~kind:Unix.S_DIR ~perm:0o755 ~nlink:2 ~size:0L
      ~mtime:(Unix.gettimeofday ())

  (* Directories exist only in the manifest mirror. *)
  let stat key =
    let* mst = Io_lwt.Fs.stat_opt_large (manifest_path key) in
    match mst with
      | Some { Unix.LargeFile.st_kind = Unix.S_DIR; _ } ->
          Lwt.return_some (dir_stat ())
      | Some _ | None -> (
          let* m = Mf.current key in
          match m with
            | Some (`Staged (st, _)) ->
                Lwt.return_some
                  (file_stat st.Staged_manifest.s_size
                     st.Staged_manifest.s_mtime)
            | Some (`Published m) -> (
                match Manifest.symlink m with
                  | Some target ->
                      Lwt.return_some (symlink_stat target (Manifest.mtime m))
                  | None ->
                      Lwt.return_some
                        (file_stat (Manifest.size m) (Manifest.mtime m)))
            | None -> Lwt.return_none)

  let stat key =
    let* st = stat key in
    match st with
      | Some _ -> Lwt.return st
      | None -> (
          (* No local sidecar (never cached, or after a full resync): resolve
             from the backend so stat reports the logical size, not ENOENT. *)
          let+ m = published key in
          match m with
            | Some m -> (
                match Manifest.symlink m with
                  | Some target -> Some (symlink_stat target (Manifest.mtime m))
                  | None ->
                      Some (file_stat (Manifest.size m) (Manifest.mtime m)))
            | None -> None)

  let readlink key =
    let+ m = published key in
    match m with Some m -> Manifest.symlink m | None -> None

  (* The local mirror is the source of truth for names and structure; the
     backend holds only hashed keys. Directory mtimes are not tracked. *)
  let list_children ~prefix =
    let+ files, dirs = Ck.list_children ~prefix () in
    (files, List.map (fun d -> (d, (None : float option))) dirs)

  let list_tree ~prefix = Ck.list_tree ~prefix ()
  let enforce_chunk_cap = D.enforce_chunk_cap
  let chunk_stats = D.chunk_stats
  let resolve = Mf.current
  let chunk_residency = D.chunk_residency
  let downloads_in_flight = D.downloads_in_flight

  let staged_count () =
    let+ keys = Mfs.list () in
    List.length keys

  let downloads_completed_count = D.downloads_completed_count
  let download_progress = D.download_progress

  (* The sidecar stays, so the file keeps its size, mtime and identity and
     re-fetches on demand. *)
  let evict key = D.forget_chunks key

  (* For a key that is gone: staged edits go too, there is nothing left to
     upload them to. *)
  let clear_local key =
    let* () = evict key in
    let* () = D.discard_staged key in
    delete_manifest key

  let create key = D.create key
  let write_whole key ~src_path = D.stage_whole key ~src_path
  let read key (buf : File_ops.buffer) ~offset = D.pread_key key buf ~offset

  (* What to call a row, and where the file sits under the domain root. *)
  (* The queue and the pull tracker hold rendered keys, so this takes one back
     apart; a key from either is this domain's by construction. *)
  let describe key =
    match Option.map Lk.file (Lk.rel_of_string key) with
      | Some k -> (Logical_key.leaf k, rel_key k)
      | None -> (Filename.basename key, key)

  let uploads_in_flight () =
    Lwt_list.filter_map_s
      (fun key ->
        let* body = D.staged_body_path key in
        (* How much there is to send. What has gone already is not tracked per
           file -- the chunk upload counts bytes process-wide -- so a row can say
           how big a file is but not how far along it is. *)
        let+ resolved = Mf.current key in
        let name, rel = (Logical_key.leaf key, rel_key key) in
        let size =
          match resolved with
            | Some (`Staged (st, _)) -> Some st.Staged_manifest.s_size
            | Some (`Published m) -> Some (Manifest.size m)
            | None -> None
        in
        Some { File_ops.name; rel; body; size })
      (!in_flight_keys ())

  let downloading_now () =
    List.map
      (fun (p : D.pulling) ->
        let name, rel = describe p.D.key in
        {
          File_ops.d_name = name;
          d_rel = rel;
          d_bytes = p.D.bytes;
          d_size = p.D.size;
          d_seconds = p.D.seconds;
          d_rate = p.D.rate;
        })
      (D.pulling_now ())

  let write key (buf : File_ops.buffer) ~offset =
    (* An in-flight upload is reading the bodies we are about to mutate: cancel
       it or it publishes a manifest for torn content. Release re-queues it. *)
    ignore (cancel_upload key);
    D.write key buf ~offset

  let truncate key size =
    ignore (cancel_upload key);
    D.truncate key size

  let rename_local ~src ~dst =
    let* () = Mfs.rename ~src_key:src ~dst_key:dst in
    Ck.rename ~src_key:src ~dst_key:dst

  let with_journal key ops s3_op =
    let ek = J.entry_key () in
    let* () = W.record ek ops in
    (* Dropped on a synchronous failure, or reconcile replays a known-failed op
       at every startup. *)
    let* () =
      Lwt.catch s3_op (fun exn ->
          let* () = W.complete ek in
          Lwt.fail exn)
    in
    W.discharge
      ~publish:(fun ek ops -> Fs.write_journal_entry ~entry_key:ek ops)
      ~cursor:Fs.bump_cursor ek ops

  let save_version key =
    if C.versioning then Hs.save_version ~key else Lwt.return_unit

  let apply_delete key =
    let* () = save_version key in
    let* () = St.delete_manifest ~key in
    clear_local key

  let queue_put key =
    let* staged = Mfs.read_edits key in
    match staged with
      | None ->
          Log.debug "queue_put %s: nothing staged, skipping"
            (Logical_key.to_string key);
          Lwt.return_unit
      | Some st ->
          (* Recorded before this returns, which is what makes a crash here
             leave something saying the upload is owed; handing it over only
             says who should get to it first. *)
          let entry_key = J.entry_key () in
          let record =
            {
              Wal.ops = [`Put (rel_key key, st.Staged_manifest.s_size)];
              state = Wal.Prepared;
              attempts = 0;
              last_error = None;
            }
          in
          let* () = W.write entry_key record in
          Wal_lwt.Owed.signal W.owed (entry_key, record)

  (* The record already exists and already names this work; writing it under
     its own key is what keeps one unit of work to one key across a restart. *)
  let resume_put key ~entry_key ~record =
    let* staged = Mfs.exists key in
    if not staged then Lwt.return_false
    else
      let* () = W.write entry_key record in
      let+ () = Wal_lwt.Owed.signal W.owed (entry_key, record) in
      true

  let reclaim_staged_orphans = D.reclaim_staged_orphans

  let close key =
    let* staged = Mfs.exists key in
    if staged then queue_put key else Lwt.return_unit

  let delete key =
    with_meta (fun () ->
        ignore (cancel_upload key);
        with_journal key [`Delete (rel_key key)] (fun () -> apply_delete key))

  (* Backend key of a directory's folder marker, under its parent's namespace.
     [None] at the domain root, or for a parent this client never recorded;
     callers must skip rather than substitute a key, since the domain prefix is
     itself a real object. *)
  let folder_marker_bkey key = L.folder_marker_key key

  let mkdir key =
    with_meta (fun () ->
        let* () = Ck.create_dir key in
        (* Minted here, not in [put_folder_marker], so the same id reaches the
           journal entry a peer will read. *)
        let* fid = L.ensure_folder_id key in
        with_journal key
          [`Mkdir (rel_key key, Some fid)]
          (fun () -> St.put_folder_marker ~key))

  (* O(1) delete: move the parent marker into the trash namespace. The subtree
     stays on the backend for undo, dropped later by [expire] and its chunks
     reclaimed by [gc]. *)
  let rmdir key =
    with_meta (fun () ->
        let rel = rel_key key in
        let* old_marker = folder_marker_bkey key in
        let* fid = L.ensure_folder_id key in
        let delete_old_marker () =
          match old_marker with
            | None -> Lwt.return_unit
            | Some bkey -> St.delete_raw ~bkey
        in
        let trash_key =
          Stored_key.under
            (Stored_key.trash_namespace ~prefix:C.domain_prefix)
            (Stored_key.new_id ())
        in
        let marker =
          Folder.trash_marker_to_string ~name:(Filename.basename rel) ~id:fid
            ~path:rel
        in
        let* () =
          with_journal key
            [`Rmdir (rel_key key, Some fid)]
            (fun () ->
              let* () = St.put_raw ~bkey:trash_key ~data:marker in
              delete_old_marker ())
        in
        Ck.delete_dir key)

  (* For a file whose chunks are already on the backend: only the manifest key
     and journal entry are missing. *)
  let publish_manifest key (m : Manifest.t) =
    Log.info "publish_manifest %s: size=%Ld"
      (Logical_key.to_string key)
      (Manifest.size m);
    let name = Logical_key.leaf key in
    let* () = St.put_manifest ~key ~data:(Manifest.body ~name m) in
    let* ek = Fs.write_journal_entry [`Put (rel_key key, Manifest.size m)] in
    Fs.bump_cursor ek

  let conflict_key key =
    let base = Logical_key.leaf key in
    let name, ext =
      match String.rindex_opt base '.' with
        | None -> (base, "")
        | Some i ->
            (String.sub base 0 i, String.sub base i (String.length base - i))
    in
    let base =
      Printf.sprintf "%s (conflicted copy from %s)%s" name C.client_name ext
    in
    Logical_key.file_in (Logical_key.parent key) base

  (* Moving an object on the backend does not rewrite its body, so the copy at
     the new key still records the old leaf. Unconditional: the mirror is
     already stamped by the time this runs, so its body cannot be used to detect
     whether the backend's needs it. *)
  let resync_manifest_name key =
    let name = Logical_key.leaf key in
    let* m = published_here key in
    match m with
      | Some man -> St.put_manifest ~key ~data:(Manifest.body ~name man)
      | None -> Lwt.return_unit

  let rename_body ~src ~dst =
    let mp = manifest_path src in
    let* mst = Io_lwt.Fs.stat_opt_large mp in
    let is_dir =
      match mst with
        | Some { Unix.LargeFile.st_kind = Unix.S_DIR; _ } -> true
        | _ -> false
    in
    (* What it is is discovered here, from the tree, so the keys are renamed
       into folders once it is known. *)
    let as_dir k = if is_dir then Lk.dir (Logical_key.path k) else k in
    let src = as_dir src in
    let dst = as_dir dst in
    let src_was_uploading = cancel_upload src in
    ignore (cancel_upload dst);
    (* Staged size wins: it is what a peer will fetch next. *)
    let* size =
      if is_dir then Lwt.return_none
      else
        let+ resolved = Mf.current src in
        match resolved with
          | Some (`Staged (st, _)) -> Some st.Staged_manifest.s_size
          | Some (`Published m) -> Some (Manifest.size m)
          | None -> None
    in
    let* () = rename_local ~src ~dst in
    (* Read after the move, where the folder now is. *)
    let* dir_id =
      if is_dir then
        let+ id = L.ensure_folder_id dst in
        Some id
      else Lwt.return_none
    in
    let* dst_staged = Mfs.exists dst in
    if src_was_uploading && dst_staged then queue_put dst
    else
      let* () = if not is_dir then save_version src else Lwt.return_unit in
      let rename_op =
        `Rename
          Journal.
            { dst = rel_key dst; src = rel_key src; size; is_dir; id = dir_id }
      in
      Lwt.catch
        (fun () ->
          let* () =
            with_journal dst [rename_op] (fun () ->
                (* A directory's backend keys hang off its folder id, which
                   travelled with the local [.tsync-dir] marker in
                   [rename_local]: only the parent's marker moves. A file's key
                   encodes its leaf, so the object itself moves. *)
                if is_dir then
                  let* old_marker = folder_marker_bkey src in
                  let* () =
                    match old_marker with
                      | None -> Lwt.return_unit
                      | Some bkey -> St.delete_raw ~bkey
                  in
                  St.put_folder_marker ~key:dst
                else Fs.rename_file ~src_key:src ~dst_key:dst)
          in
          if is_dir then Lwt.return_unit else resync_manifest_name dst)
        (fun exn ->
          (* src gone from the backend: a concurrent rename or delete by another
             client. The file already moved locally, so republish it under a
             conflict name; its chunks are still there. *)
          let* src_head =
            if is_dir then Lwt.return_some ()
            else
              let+ h = Fs.head_manifest_opt ~key:src in
              Option.map (fun _ -> ()) h
          in
          if is_dir || Option.is_some src_head then Lwt.fail exn
          else
            let* m = Mf.current dst in
            match m with
              | Some (`Staged _) ->
                  (* src never reached the backend: a rename before first
                     upload, not a conflict. A conflict name here would break
                     the writer's own follow-up accesses (rclone stat'ing its
                     renamed .partial). *)
                  queue_put dst
              | Some (`Published m) ->
                  (* src was uploaded and has since vanished remotely: keep both
                     sides under a conflict-marked name. *)
                  let conflict = conflict_key dst in
                  let* () = rename_local ~src:dst ~dst:conflict in
                  publish_manifest conflict m
              | None -> Lwt.fail exn)

  let rename ~src ~dst = with_meta (fun () -> rename_body ~src ~dst)

  (* Newest of [entries] (each a [versions/…/<ts>] object), by trailing
     timestamp. *)
  let latest_version entries =
    List.fold_left
      (fun acc (e : Backend.file_entry) ->
        match History.parse ~versions_prefix:C.versions_prefix e.key with
          | None -> acc
          | Some (_, ts) -> (
              let n = Int64.of_string ts in
              match acc with
                | Some (_, best) when Int64.compare best n >= 0 -> acc
                | _ -> Some (e.key, n)))
      None entries

  let revert_body ?version key =
    let* src_key =
      match version with
        | Some ts -> (
            let* dir = Hs.version_dir ~key in
            match dir with
              | Some dir -> Lwt.return (Stored_key.under dir ts)
              | None -> failwith ("no versions for " ^ rel_key key))
        | None -> (
            let* entries = Hs.list_versions ~key in
            match latest_version entries with
              | Some (k, _) -> Lwt.return k
              | None -> failwith ("no versions for " ^ rel_key key))
    in
    let* data = Hs.get_version ~vkey:src_key in
    match Manifest.of_string data with
      | m ->
          ignore (cancel_upload key);
          (* Restored under the name the snapshot recorded, which is the one
             its body already carries. *)
          let* () =
            St.put_manifest ~key
              ~data:(Manifest.body ~name:(Manifest.recorded_name m) m)
          in
          let* () = write_manifest key m in
          (* Cached chunks are left alone: shared ones may still be wanted,
             missing ones fetch on demand. Staged edits, manifest and bodies
             both, are what revert discards. *)
          let* () = D.discard_staged key in
          let* ek =
            Fs.write_journal_entry [`Put (rel_key key, Manifest.size m)]
          in
          Fs.bump_cursor ek

  let revert ?version key = with_meta (fun () -> revert_body ?version key)

  (* Only [`Keep] can create symlinks: the other policies must not put symlink
     objects in the domain, and "follow" is undefined at creation time (the
     target may be relative, dangling, or outside the mount). *)
  let symlink ~target key =
    (match C.symlink_policy with
      | `Keep -> ()
      | `Follow | `Skip ->
          raise
            (Unix.Unix_error (Unix.EPERM, "symlink", Logical_key.to_string key)));
    with_meta (fun () ->
        let name = Logical_key.leaf key in
        let state =
          Manifest.make_symlink ~name ~target ~mtime:(Unix.gettimeofday ())
        in
        let* () = St.put_manifest ~key ~data:(Manifest.body ~name state) in
        let* () = write_manifest key state in
        let* ek =
          Fs.write_journal_entry [`Put (rel_key key, Manifest.size state)]
        in
        Fs.bump_cursor ek)

  (* Adopt the id from the backend marker: resolving the folder locally would
     mint a different one and split the namespace in two. *)
  let adopt_folder_id rel =
    if rel = "" then Lwt.return_unit
    else
      let* marker_key = folder_marker_bkey (Lk.dir rel) in
      match marker_key with
        | None -> Lwt.return_unit
        | Some marker_key ->
            Lwt.catch
              (fun () ->
                let* data = St.get_object ~bkey:marker_key in
                match Folder.marker_of_string data with
                  | Some m ->
                      Folder_ids_lwt.write ~cache_root:C.cache_root
                        ~domain_name:C.domain_name (Lk.dir rel)
                        {
                          Folder.name = Filename.basename rel;
                          id = m.Folder.id;
                        }
                  | None -> Lwt.return_unit)
              (fun _ -> Lwt.return_unit)

  (* A [Put] materialises the directories above it as a side effect of writing
     the manifest, and those carry no id: only a [Mkdir] op adopts one, and the
     mkdir for a folder created before this client's cursor is not in the
     journal it replays. Left alone, the directory exists in the mirror and can
     be named to nobody.

     Top-down, because a marker's key is built from the id of the folder above
     it, and adoption only — the marker is the store's, and minting one here
     would fork the namespace the other clients already agree on. *)
  let adopt_ancestor_ids rel =
    let rec ancestors acc key =
      let parent = Logical_key.parent key in
      if Logical_key.is_root parent then acc
      else ancestors (parent :: acc) parent
    in
    Lwt_list.iter_s
      (fun dir ->
        let* known =
          Folder_ids_lwt.lookup_id ~cache_root:C.cache_root
            ~domain_name:C.domain_name dir
        in
        match known with
          | Some _ -> Lwt.return_unit
          | None -> adopt_folder_id (Logical_key.path dir))
      (ancestors [] (Lk.dir rel))

  (* A foreign op must never clobber unsynced local edits. The staged manifest
     is that flag and survives a restart. *)
  let unless_staged key f =
    let* staged = Mfs.exists key in
    if staged then Lwt.return_unit else f ()

  (* Failures propagate: the sync poller must not advance its high-water mark
     past an entry it could not apply, or the op is lost until a full resync. *)
  let apply_one op =
    match op with
      | `Put (rel, _) ->
          let key = Lk.file rel in
          unless_staged key (fun () ->
              ignore (cancel_upload key);
              (* Before the fetch, not after: the manifest's own key is built
                 from the parent folder's id, so a missing one does not fail
                 loudly here — it resolves to no key and the put is skipped. *)
              let* () = adopt_ancestor_ids rel in
              let* m = R.fetch_manifest ~key () in
              match m with
                | None -> Lwt.return_unit
                | Some state -> write_manifest key state)
      | `Delete rel ->
          let key = Lk.file rel in
          unless_staged key (fun () ->
              ignore (cancel_upload key);
              clear_local key)
      (* The op's id is ignored: on a concurrent create the backend marker
         settles which id wins. The op carries it for readers naming a folder
         the mirror no longer has. *)
      | `Mkdir (rel, _) ->
          let* () = Ck.create_dir (Lk.dir rel) in
          let* () = adopt_ancestor_ids rel in
          adopt_folder_id rel
      | `Rmdir (rel, _) -> Ck.delete_dir (Lk.dir rel)
      | `Rename { Journal.src; dst; is_dir = true; _ } ->
          let src_key = Lk.dir src in
          let dst_key = Lk.dir dst in
          let* exists = Io_lwt.Retry.file_exists (manifest_path src_key) in
          if exists then
            unless_staged src_key (fun () ->
                let* () = adopt_ancestor_ids dst in
                rename_local ~src:src_key ~dst:dst_key)
          else Lwt.return_unit
      | `Rename { Journal.src; dst; is_dir = false; _ } ->
          let src_key = Lk.file src in
          let dst_key = Lk.file dst in
          let* exists = Io_lwt.Retry.file_exists (manifest_path src_key) in
          if exists then
            unless_staged src_key (fun () ->
                let* () = adopt_ancestor_ids dst in
                rename_local ~src:src_key ~dst:dst_key)
          else
            unless_staged dst_key (fun () ->
                (* No local src (e.g. we renamed it ourselves and published the
                   result): adopt dst's remote state. *)
                let* m = R.fetch_manifest ~key:dst_key () in
                match m with
                  | Some state -> write_manifest dst_key state
                  | _ -> Lwt.return_unit)

  let apply_foreign_ops ops =
    with_meta (fun () -> Lwt_list.iter_s apply_one ops)
end

(* The one place the store modules are built, so everything above takes them
   rather than knowing which they are. *)
module Make (C : Conf.S) = struct
  module L = Layout.Inode.Make (C)

  include
    Make_with_layout (C) (L) (File_store.Make (C)) (Store.Make (C) (L))
      (History.Make (C) (L))
      (Remote.Make_with_layout (C) (L))
end
