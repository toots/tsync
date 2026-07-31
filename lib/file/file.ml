open Lwt.Syntax

type buffer = Local_io.buffer

module type S = sig
  type t = string

  val manifest_path : t -> string
  val rel_key : t -> string
  val read_manifest : t -> Manifest.t option Lwt.t
  val resolved_manifest : t -> Manifest.t option Lwt.t
  val write_manifest : t -> Manifest.t -> unit Lwt.t
  val upload : ?cancel:bool ref -> t -> unit Lwt.t

  (** Fetch every chunk [t] needs, so later reads are served locally. *)
  val ensure_cached : t -> unit Lwt.t

  (** Write [t]'s whole content to [dst_path], fetching what it needs. For a
      caller that must hand over a real file and can only accept it in a
      particular place. *)
  val assemble_to : t -> dst_path:string -> unit Lwt.t

  val stat : t -> Unix.LargeFile.stats option Lwt.t
  val readlink : t -> string option Lwt.t

  val list_children :
    prefix:string ->
    (Backend.file_entry list * (string * float option) list) Lwt.t

  val list_tree : prefix:string -> Backend.file_entry list Lwt.t

  (** Handle closed: queue the file for upload if it has staged edits. *)
  val close : t -> unit Lwt.t

  (** Finish every upload the staged tree still owes — the crash-recovery entry
      point, run once at startup. *)
  val recover_staged : unit -> unit Lwt.t

  (** Keep the chunk store under [C.max_cache]; never touches staged data. *)
  val enforce_chunk_cap : unit -> unit Lwt.t

  (** [(chunks, bytes)] held in the chunk store. *)
  val chunk_stats : unit -> (int * int) Lwt.t

  (** [t]'s content: staged edits if any, else what was published. *)
  val resolve :
    t ->
    [ `Staged of Manifest.staged * Manifest.t option | `Published of Manifest.t ]
    option
    Lwt.t

  (** [(chunks present locally, chunks total)] for [t]. *)
  val chunk_residency : t -> (int * int) Lwt.t

  (** Chunk downloads currently in flight. *)
  val downloads_in_flight : unit -> int

  (** How many files owe an upload. *)
  val staged_count : unit -> int Lwt.t

  val downloads_completed_count : unit -> int

  (* Whether the metadata lock is held, and whether callers are queued behind it:
     what a wedged mount looks like from outside. *)
  val meta_locked : unit -> bool
  val meta_waiters : unit -> bool
  val download_progress : t -> (int * int) option

  (** Drop [t]'s cached chunks, keeping its manifest. *)
  val evict : t -> unit Lwt.t

  val create : t -> unit Lwt.t

  (** Stage a whole file handed over by a frontend as [t]'s new content. *)
  val write_whole : t -> src_path:string -> unit Lwt.t

  val read : t -> buffer -> offset:int64 -> int Lwt.t
  val write : t -> buffer -> offset:int64 -> int Lwt.t
  val cancel_upload : t -> bool
  val truncate : t -> int64 -> unit Lwt.t
  val apply_delete : t -> unit Lwt.t
  val queue_put : t -> unit Lwt.t
  val delete : t -> unit Lwt.t
  val mkdir : t -> unit Lwt.t
  val rmdir : t -> unit Lwt.t
  val rename : src:t -> dst:t -> unit Lwt.t

  (** Restore a saved version of [key] to the live location. With [version] the
      given timestamp is restored, otherwise the most recent one. Only the small
      manifest is copied back; content stays evicted (dataless) and is fetched
      lazily on next open. *)
  val revert : ?version:string -> t -> unit Lwt.t

  val symlink : target:string -> t -> unit Lwt.t
  val apply_foreign_ops : Journal.op list -> unit Lwt.t
end

module Make_with_layout (C : Conf.S) (Sq : Sync_queue.S) (L : Layout.S) : S =
struct
  module J = Journal.Make (C)
  module Fs = File_store.Make (C)
  module R = Remote.Make_with_layout (C) (L)

  type t = string

  (* All File operations run on the single Lwt event-loop thread, so plain
     hashtables need no locking. Metadata mutations (delete/mkdir/rmdir/rename/
     revert and foreign-op application) are serialized through [meta_mutex] to
     preserve the ordering the old single-threaded FUSE loop provided; reads,
     downloads and uploads stay concurrent.
     ponytail: one global metadata lock; switch to per-key locks only if
     unrelated metadata ops measurably contend. *)
  let meta_mutex = Lwt_mutex.create ()
  let with_meta f = Lwt_mutex.with_lock meta_mutex f
  let meta_locked () = Lwt_mutex.is_locked meta_mutex
  let meta_waiters () = not (Lwt_mutex.is_empty meta_mutex)

  (* ── Path helpers ──────────────────────────────────────────────────────── *)

  let rel_key = Key.strip_prefix ~domain_prefix:C.domain_prefix

  (* Manifest backend I/O goes through [St], keyed by logical (real-path) keys;
     the layout scheme maps them to backend keys. [Mf] is the local mirror. *)
  module St = Store.Make (C) (L)
  module Mf = Manifest.Make (C)
  module D = Data.Make (C) (R)

  let manifest_path key = Mf.path key

  (* A directory's id is what names it from outside, and the id survives a move —
     but where it now lives has to be recorded, or the folder cannot be found by
     it any more. Every path that moves a directory locally owes this call. *)
  let reparent_dir key =
    Folder_ids.reparent ~cache_root:C.cache_root ~domain_name:C.domain_name
      (Key.chop_slash (rel_key key))

  (* ── Manifest ──────────────────────────────────────────────────────────── *)

  let read_manifest key : Manifest.t option Lwt.t = Mf.read key
  let resolved_manifest = D.resolved_manifest
  let write_manifest key (state : Manifest.t) = Mf.write key state
  let delete_manifest key = Mf.delete key

  (* ── Upload / download ─────────────────────────────────────────────────── *)

  (* Everything a file owes the backend is in its staged manifest: upload the
     chunks it staged, keep the ones it still inherits, then promote. *)
  let upload ?cancel key = D.sync key ?cancel ()

  (* Make every chunk local, so later reads are served without the network: what
     a restore asks for. Produces no file — a caller that wants one asks for it
     by name with [assemble_to], which fetches on its own. *)
  let ensure_cached = D.ensure_local

  (* Write the whole file to a path the caller names. *)
  let assemble_to = D.assemble_to

  (* ── Stat ──────────────────────────────────────────────────────────────── *)

  (* Nothing in the domain has a real inode, owner or link count: the manifest
     carries a size and an mtime and everything else is synthesized, the same way
     for all three kinds. *)
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

  (* A symlink's size is its target's byte length, POSIX-style. *)
  let symlink_stat target mtime =
    stat_of ~kind:Unix.S_LNK ~perm:0o777 ~nlink:1
      ~size:(Int64.of_int (String.length target))
      ~mtime

  let dir_stat () =
    stat_of ~kind:Unix.S_DIR ~perm:0o755 ~nlink:2 ~size:0L
      ~mtime:(Unix.gettimeofday ())

  (* Directories exist only in the manifest mirror; files answer from whatever
     describes them — a staged manifest for one created locally and not yet
     uploaded, else the published sidecar. *)
  let stat key =
    let* mst = Fs_util.stat_opt_large (manifest_path key) in
    match mst with
      | Some { Unix.LargeFile.st_kind = Unix.S_DIR; _ } ->
          Lwt.return_some (dir_stat ())
      | Some _ | None -> (
          let* m = Mf.resolve key in
          match m with
            (* A file with unsynced edits: its staged manifest is authoritative
               for size and mtime, in every state. *)
            | Some (`Staged (st, _)) ->
                Lwt.return_some
                  (file_stat st.Manifest.s_size st.Manifest.s_mtime)
            | Some (`Published { Manifest.symlink = Some target; mtime; _ }) ->
                Lwt.return_some (symlink_stat target mtime)
            | Some (`Published m) ->
                Lwt.return_some (file_stat m.Manifest.size m.Manifest.mtime)
            | None -> Lwt.return_none)

  let stat key =
    let* st = stat key in
    match st with
      | Some _ -> Lwt.return st
      | None -> (
          (* No local sidecar (never cached, or after a full resync): the file's
             manifest still lives on the backend. Resolve it so getattr/stat
             report the real logical size instead of ENOENT. *)
          let+ m = resolved_manifest key in
          match m with
            | Some { Manifest.symlink = Some target; mtime; _ } ->
                Some (symlink_stat target mtime)
            | Some m -> Some (file_stat m.Manifest.size m.Manifest.mtime)
            | None -> None)

  let readlink key =
    let+ m = resolved_manifest key in
    match m with
      | Some { Manifest.symlink = Some _ as target; _ } -> target
      | _ -> None

  (* readdir is served from the local manifest mirror (the source of truth for
     names and structure); the backend holds only hashed keys. Directory mtimes
     are not tracked locally, so they are reported absent. *)
  let list_children ~prefix =
    let+ files, dirs = Mf.list_children ~prefix () in
    (files, List.map (fun d -> (d, (None : float option))) dirs)

  let list_tree ~prefix = Mf.list_tree ~prefix ()
  let enforce_chunk_cap = D.enforce_chunk_cap
  let chunk_stats = D.chunk_stats
  let resolve = Mf.resolve
  let chunk_residency = D.chunk_residency

  (* ── Metrics ───────────────────────────────────────────────────────────── *)

  let downloads_in_flight = D.downloads_in_flight

  let staged_count () =
    let+ keys = Mf.list_staged () in
    List.length keys

  let downloads_completed_count = D.downloads_completed_count
  let download_progress = D.download_progress

  (* ── Local eviction ────────────────────────────────────────────────────── *)

  (* Dropping local content is dropping this file's chunks; the sidecar stays, so
     the file keeps its size, mtime and identity and re-fetches on demand. *)
  let evict key = D.forget_chunks key

  (* Everything local about a key, for a file that is gone: its chunks, its
     sidecar and any staged edits (there is nothing left to upload them to). *)
  let clear_local key =
    let* () = evict key in
    let* () = Mf.delete_staged key in
    delete_manifest key

  let create key = D.create key
  let write_whole key ~src_path = D.stage_whole key ~src_path
  let read key (buf : buffer) ~offset = D.pread_key key buf ~offset
  let cancel_upload key = Sq.cancel_put key

  let write key (buf : buffer) ~offset =
    (* An in-flight upload is reading the very bodies we are about to mutate:
       cancel it or it publishes a manifest for torn content. The writer's
       release re-queues it. *)
    ignore (cancel_upload key);
    D.write key buf ~offset

  let truncate key size =
    ignore (cancel_upload key);
    D.truncate key size

  let rename_local ~src ~dst =
    let* () = Mf.rename_staged ~src_key:src ~dst_key:dst in
    Mf.rename ~src_key:src ~dst_key:dst

  (* ── Synchronous backend operations ────────────────────────────────────── *)

  let with_journal key ops s3_op =
    let ek = J.entry_key () in
    let* () = J.write_local_pending ~entry_key:ek ops in
    (* The pending entry is for crash recovery. A synchronous failure is
       reported to the caller instead; keeping the entry would make
       recover_pending_ops replay a known-failed op at every startup. *)
    let* () =
      Lwt.catch s3_op (fun exn ->
          let* () = J.delete_local_pending ~entry_key:ek in
          Lwt.fail exn)
    in
    let* (_ : string) = Fs.write_journal_entry ~entry_key:ek ops in
    let* () = Fs.bump_cursor ek in
    J.delete_local_pending ~entry_key:ek

  let save_version key =
    if C.versioning then St.save_version ~key else Lwt.return_unit

  let apply_delete key =
    let* () = save_version key in
    let* () = St.delete_manifest ~key in
    clear_local key

  (* ── Async upload queue ────────────────────────────────────────────────── *)

  let queue_put key =
    let* staged = Mf.read_staged key in
    match staged with
      | None ->
          (* Nothing staged means nothing to send: the file is already published
             (or was deleted before its close reached us). *)
          Log.debug "queue_put %s: nothing staged, skipping" key;
          Lwt.return_unit
      | Some st ->
          let ek = J.entry_key () in
          let ops = [`Put (rel_key key, st.Manifest.s_size)] in
          let+ () = J.write_local_pending ~entry_key:ek ops in
          Sq.post ~key ~entry_key:ek ~ops

  (* ── Staged edits ─────────────────────────────────────────────────────────
     A staged manifest on disk means an upload is owed: nothing else records that
     across a restart. Replaying at startup covers both a crash mid-write (the
     upload never ran) and a crash mid-promotion (it ran and only the local moves
     are left, which {!Data.sync} finishes without re-sending anything). *)

  let recover_staged () =
    let* keys = Mf.list_staged () in
    Lwt_list.iter_s
      (fun key ->
        Log.info "resuming staged upload for %s" key;
        Lwt.catch
          (* Through the queue, not straight to [D.sync]: the upload also owes a
             journal entry and a cursor bump, or peers never learn the file
             changed. A staged manifest that already carries its published record
             promotes without re-sending anything. *)
          (fun () -> queue_put key)
          (fun exn ->
            Log.err "staged upload %s failed: %s" key (Printexc.to_string exn);
            Lwt.return_unit))
      keys

  (* ── Close ────────────────────────────────────────────────────────────── *)

  (* A handle closed: the only thing a close still decides is whether an upload
     is owed, and the staged manifest answers that on its own — across a restart
     too, so there is nothing to count. *)
  let close key =
    let* staged = Mf.staged_exists key in
    if staged then queue_put key else Lwt.return_unit

  let delete key =
    with_meta (fun () ->
        ignore (cancel_upload key);
        with_journal key [`Delete (rel_key key)] (fun () -> apply_delete key))

  (* Backend key of a directory's folder marker (under its parent's namespace).
     Used to move or remove a marker whose local dir has already moved or is
     gone, so the marker body [L] would build alongside it is not wanted. *)
  (* [None] where there is no marker to name: the domain root, or a parent this
     client never recorded. Callers skip rather than substitute a key — the old
     default was the domain prefix, which is a real object name to delete. *)
  let folder_marker_bkey = L.folder_marker_key

  let mkdir key =
    with_meta (fun () ->
        let* () = Mf.create_dir key in
        (* Minted here rather than left to [put_folder_marker], so the same id
           goes into the journal entry a peer will read. *)
        let* fid = L.ensure_folder_id key in
        with_journal key
          [`Mkdir (rel_key key, Some fid)]
          (fun () -> St.put_folder_marker ~key))

  (* O(1) delete: detach the folder by moving its parent marker into the trash
     namespace. The subtree stays intact on the backend (untouched) for undo and
     is reclaimed by [expire]; the local mirror copy is dropped immediately. *)
  let rmdir key =
    with_meta (fun () ->
        let rel = Key.chop_slash (rel_key key) in
        let* old_marker = folder_marker_bkey key in
        let* fid = L.ensure_folder_id key in
        let delete_old_marker () =
          match old_marker with
            | None -> Lwt.return_unit
            | Some bkey -> St.delete_raw ~bkey
        in
        let trash_key =
          C.domain_prefix ^ Folder.trash_id ^ "/" ^ Folder.new_id ()
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
        Mf.delete_dir key)

  (* Publish an already-chunked file under [key]: its chunks are on the
     backend, only the manifest key and a journal entry are missing. *)
  let publish_manifest key (m : Manifest.t) =
    Log.info "publish_manifest %s: size=%Ld" key m.Manifest.size;
    let* () = St.put_manifest ~key ~data:(Manifest.to_string m) in
    let* ek = Fs.write_journal_entry [`Put (rel_key key, m.Manifest.size)] in
    Fs.bump_cursor ek

  let conflict_name rel =
    let base = Filename.basename rel in
    let dir = Key.parent rel in
    let name, ext =
      match String.rindex_opt base '.' with
        | None -> (base, "")
        | Some i ->
            (String.sub base 0 i, String.sub base i (String.length base - i))
    in
    let base =
      Printf.sprintf "%s (conflicted copy from %s)%s" name C.client_name ext
    in
    Key.join dir base

  (* A file rename moves its manifest object but not its body, so the leaf [name]
     it records goes stale. Rewrite it (local sidecar + backend) to match the new
     key. A directory rename leaves every descendant's leaf name unchanged, so
     nothing else needs fixing. *)
  let resync_manifest_name key =
    let name = Filename.basename key in
    let* m = read_manifest key in
    match m with
      | Some man when man.Manifest.name <> name ->
          let renamed = { man with Manifest.name } in
          let* () = write_manifest key renamed in
          St.put_manifest ~key ~data:(Manifest.to_string renamed)
      | _ -> Lwt.return_unit

  let rename_body ~src ~dst =
    let mp = manifest_path src in
    let* mst = Fs_util.stat_opt_large mp in
    let is_dir =
      match mst with
        | Some { Unix.LargeFile.st_kind = Unix.S_DIR; _ } -> true
        | _ -> false
    in
    let src = if is_dir then src ^ "/" else src in
    let dst = if is_dir then dst ^ "/" else dst in
    let src_was_uploading = cancel_upload src in
    ignore (cancel_upload dst);
    (* The journal records the renamed file's size, taken from its metadata —
       staged edits first, since they are what a peer will fetch next. *)
    let* size =
      if is_dir then Lwt.return_none
      else
        let+ resolved = Mf.resolve src in
        match resolved with
          | Some (`Staged (st, _)) -> Some st.Manifest.s_size
          | Some (`Published m) -> Some m.Manifest.size
          | None -> None
    in
    let* () = rename_local ~src ~dst in
    let* () = if is_dir then reparent_dir dst else Lwt.return_unit in
    (* Read after the move, where the folder now is; the id itself is what a
       rename does not change, which is the whole reason to carry it. *)
    let* dir_id =
      if is_dir then
        let+ id = L.ensure_folder_id dst in
        Some id
      else Lwt.return_none
    in
    let* dst_staged = Mf.staged_exists dst in
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
                (* A directory's backend keys live under its stable folder id,
                   which travelled with the local [.tsync-dir] marker during
                   [rename_local] — so the subtree needs no backend work; only
                   the parent's folder marker moves. A file's key encodes its
                   leaf, so it is moved and renamed. *)
                if is_dir then
                  let* old_marker = folder_marker_bkey src in
                  let* () =
                    match old_marker with
                      | None -> Lwt.return_unit
                      | Some bkey -> St.delete_raw ~bkey
                  in
                  let* () = Mf.refresh_dir_marker dst in
                  St.put_folder_marker ~key:dst
                else Fs.rename_file ~src_key:src ~dst_key:dst)
          in
          if is_dir then Lwt.return_unit else resync_manifest_name dst)
        (fun exn ->
          (* src is gone from the backend: another client renamed or deleted it
             concurrently. The file already moved locally; publish it as a new,
             conflict-marked file instead, its chunks are still on the backend. *)
          let* src_head =
            if is_dir then Lwt.return_some ()
            else
              let+ h = Fs.head_opt ~key:src in
              Option.map (fun _ -> ()) h
          in
          if is_dir || Option.is_some src_head then Lwt.fail exn
          else
            let* m = Mf.resolve dst in
            match m with
              | Some (`Staged _) ->
                  (* src never made it to the backend (upload still pending or
                     failed): this is just a rename before first upload, not a
                     conflict. Upload the file under its new name — renaming it
                     to a conflict name here breaks the writer's own follow-up
                     accesses (e.g. rclone stat'ing its renamed .partial). *)
                  queue_put dst
              | Some (`Published m) ->
                  (* src was fully uploaded but has since vanished remotely:
                     another client moved or deleted it. Keep both versions by
                     publishing ours under a conflict-marked name. *)
                  let conflict =
                    C.domain_prefix ^ conflict_name (rel_key dst)
                  in
                  let* () = rename_local ~src:dst ~dst:conflict in
                  publish_manifest conflict m
              | None -> Lwt.fail exn)

  let rename ~src ~dst = with_meta (fun () -> rename_body ~src ~dst)

  (* ── Versioning restore ────────────────────────────────────────────────── *)

  (* Newest version among [entries] (each a [versions/…/<ts>] object), by the
     trailing timestamp component. *)
  let latest_version entries =
    List.fold_left
      (fun acc (e : Backend.file_entry) ->
        match Versioning.parse ~versions_prefix:C.versions_prefix e.key with
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
            let* dir = St.version_dir ~key in
            match dir with
              | Some dir -> Lwt.return (dir ^ ts)
              | None -> failwith ("no versions for " ^ rel_key key))
        | None -> (
            let* entries = St.list_versions ~key in
            match latest_version entries with
              | Some (k, _) -> Lwt.return k
              | None -> failwith ("no versions for " ^ rel_key key))
    in
    let* data = St.get_version ~vkey:src_key in
    match Manifest.of_string data with
      | m ->
          ignore (cancel_upload key);
          let* () = St.put_manifest ~key ~data in
          let* () = write_manifest key m in
          (* The reverted manifest names the old version's chunks; whatever is in
             the chunk store stays (a shared chunk may still be wanted) and the
             missing ones fetch on demand. Staged edits go: reverting is
             discarding them. *)
          let* () = Mf.delete_staged key in
          let* ek =
            Fs.write_journal_entry [`Put (rel_key key, m.Manifest.size)]
          in
          Fs.bump_cursor ek

  let revert ?version key = with_meta (fun () -> revert_body ?version key)

  (* Live symlink creation is only meaningful under the [`Keep] policy: a
     [`Follow]/[`Skip] domain must never contain symlink objects, and there is
     no sensible way to "follow" at creation time (the target may be relative,
     dangling, or outside the mount). *)
  let symlink ~target key =
    (match C.symlink_policy with
      | `Keep -> ()
      | `Follow | `Skip -> raise (Unix.Unix_error (Unix.EPERM, "symlink", key)));
    with_meta (fun () ->
        let state =
          Manifest.make_symlink ~name:(Filename.basename key) ~target
            ~mtime:(Unix.gettimeofday ())
        in
        let data = Manifest.to_string state in
        let* () = St.put_manifest ~key ~data in
        let* () = write_manifest key state in
        let* ek =
          Fs.write_journal_entry [`Put (rel_key key, state.Manifest.size)]
        in
        Fs.bump_cursor ek)

  (* ── Foreign op application (sync) ────────────────────────────────────── *)

  (* A folder created on another client already has a backend marker carrying its
     id; adopt that id locally so both machines share one namespace for it.
     Without this, resolving the folder here would mint a *different* id and this
     client's writes (and reads) would land in a separate namespace. *)
  let adopt_folder_id rel =
    let rel = Key.chop_slash rel in
    if rel = "" then Lwt.return_unit
    else
      let* marker_key = folder_marker_bkey (C.domain_prefix ^ rel) in
      match marker_key with
        | None -> Lwt.return_unit
        | Some marker_key ->
            Lwt.catch
              (fun () ->
                let* data = St.get_object ~bkey:marker_key in
                match Folder.marker_of_string data with
                  | Some m ->
                      Folder_ids.write ~cache_root:C.cache_root
                        ~domain_name:C.domain_name rel
                        {
                          Folder.name = Filename.basename rel;
                          id = m.Folder.id;
                        }
                  | None -> Lwt.return_unit)
              (fun _ -> Lwt.return_unit)

  (* A foreign op must never clobber unsynced local edits. The staged manifest is
     that flag, and unlike the open count it stood in for it survives a restart:
     a file written before a crash is still protected afterwards. *)
  let unless_staged key f =
    let* staged = Mf.staged_exists key in
    if staged then Lwt.return_unit else f ()

  (* Failures propagate to the caller: the sync poller must not advance its
     high-water mark past an entry it could not apply, or the op is lost
     until a full resync. *)
  let apply_one op =
    match op with
      | `Put (rel, _) ->
          let key = C.domain_prefix ^ rel in
          unless_staged key (fun () ->
              ignore (cancel_upload key);
              let* m = R.fetch_manifest ~key () in
              match m with
                | None -> Lwt.return_unit
                (* No eviction: the new manifest simply names different chunks.
                   The ones it shares with the old are already local; the rest
                   fetch on demand. *)
                | Some state -> write_manifest key state)
      | `Delete rel ->
          let key = C.domain_prefix ^ rel in
          unless_staged key (fun () ->
              ignore (cancel_upload key);
              clear_local key)
      (* The id the op carries is deliberately not used here. Two clients can
         create the same folder at once with different ids, and the backend
         marker is what settles which one wins — adopting the id from whichever
         entry happened to be read would leave the two disagreeing. The op
         carries it for readers that must name a folder the mirror no longer
         has, which is a different question. *)
      | `Mkdir (rel, _) ->
          let* () = Mf.create_dir (C.domain_prefix ^ rel) in
          adopt_folder_id rel
      | `Rmdir (rel, _) -> Mf.delete_dir (C.domain_prefix ^ rel)
      | `Rename { Journal.src; dst; is_dir = true; _ } ->
          let src_key = C.domain_prefix ^ src in
          let dst_key = C.domain_prefix ^ dst in
          let* exists = Lwt_unix_retry.file_exists (manifest_path src_key) in
          if exists then
            unless_staged src_key (fun () ->
                (* Does not go through [rename], so it owes the same bookkeeping
                   that one does. *)
                let* () = rename_local ~src:src_key ~dst:dst_key in
                reparent_dir dst_key)
          else Lwt.return_unit
      | `Rename { Journal.src; dst; is_dir = false; _ } ->
          let src_key = C.domain_prefix ^ src in
          let dst_key = C.domain_prefix ^ dst in
          let* exists = Lwt_unix_retry.file_exists (manifest_path src_key) in
          if exists then
            unless_staged src_key (fun () ->
                rename_local ~src:src_key ~dst:dst_key)
          else
            unless_staged dst_key (fun () ->
                (* No local copy of src (e.g. we renamed it ourselves and
                   published the result): adopt the remote state of dst. *)
                let* m = R.fetch_manifest ~key:dst_key () in
                match m with
                  | Some state -> write_manifest dst_key state
                  | _ -> Lwt.return_unit)

  let apply_foreign_ops ops =
    with_meta (fun () -> Lwt_list.iter_s apply_one ops)
end

(* The inode layout is what every path-keyed caller wants. *)
module Make (C : Conf.S) (Sq : Sync_queue.S) =
  Make_with_layout (C) (Sq) (Layout.Inode.Make (C))
