module type Owing = sig
  type 'a io

  val record_key : Wal.record -> Logical_key.t option
  val record_size : Wal.record -> int64
  val upload : ?cancel:bool ref -> Logical_key.t -> unit io
  val set_in_flight : (unit -> Logical_key.t list) -> unit
  val set_canceller : (Logical_key.t -> bool) -> unit
end

(* What the metadata queue needs of the file operations: the backend half of an
   op whose local half the caller has already applied. *)
module type Publishing = sig
  type 'a io

  val backend_ops : Journal.op list -> Journal.op list io
end

module type OVER = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    include File_ops.S with type 'a io := 'a io
    include Owing with type 'a io := 'a io
    include Publishing with type 'a io := 'a io
  end
end

module Over
    (Io : Io.S)
    (Fs : Fs.S with type 'a io := 'a Io.t)
    (Syscalls : Syscalls.S with type 'a io := 'a Io.t)
    (Lock : Lock.S with type 'a io := 'a Io.t)
    (W : Wal.OVER with type 'a io := 'a Io.t)
    (Mf : Manifests.OVER with type 'a io := 'a Io.t)
    (Ck : Checkout.OVER with type 'a io := 'a Io.t)
    (Mfs : Staged_manifest.OVER with type 'a io := 'a Io.t)
    (D : Data.OVER with type 'a io := 'a Io.t)
    (Folders : Folder_ids.S with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  (* Bound before [Make_with_layout] shadows [W] with its per-domain result. *)
  module Owed = W.Owed

  module Make_with_layout
      (C : Conf.S with type 'a io = 'a Io.t)
      (L : Layout.S with type 'a io := 'a Io.t)
      (Js : File_store.S with type 'a io := 'a Io.t)
      (St : Store.S with type 'a io := 'a Io.t)
      (Hs : History.S with type 'a io := 'a Io.t)
      (R : Remote.S with type 'a io := 'a Io.t) =
  struct
    module Lk = Logical_key.Make (C)
    module J = Journal.Make (C)
    module W = W.Make (C)

    type t = Logical_key.t

    let rel_key = Logical_key.path

    (* [Mf] is the local mirror; [St] the store's own copy, which takes logical
       keys and maps them to backend keys through the layout scheme. *)
    module Mf = Mf.Make (C)
    module Ck = Ck.Make (C)
    module Mfs = Mfs.Make (C)
    module D = D.Make (C) (R)

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

    (* Everything that changes this client's own state, and the one lock it
       changes under. The lock does not leave this module, so nothing outside can
       hold it across a request, and the store's modules are shadowed inside it,
       so nothing here can make one: a slow, failing or absent link cannot freeze
       the mount from under the metadata lock, by construction.

       ponytail: shadowing, not a functor boundary; [C.store] is still in reach
       of anyone set on it. Make this a functor of its own if that ever happens. *)
    module Local : sig
      val meta_locked : unit -> bool
      val meta_waiters : unit -> bool
      val local_id : t -> string option Io.t
      val key_of_id : string -> t option Io.t

      val whereabouts :
        t ->
        [ `Live of string
        | `Moved of string * t
        | `Removed of string
        | `Unknown ]
        Io.t

      val manifest_path : t -> string
      val published : t -> Manifest.t option Io.t
      val write_manifest : t -> Manifest.t -> unit Io.t
      val delete_manifest : t -> unit Io.t
      val symlink_manifest : t -> Manifest.t option Io.t
      val kind : t -> [ `Dir | `File | `Absent ] Io.t
      val evict : t -> unit Io.t
      val clear_local : t -> unit Io.t
      val queue_put : t -> unit Io.t

      val resume_put :
        t -> entry_key:Journal.Entry_key.t -> record:Wal.record -> bool Io.t

      val resume_meta :
        entry_key:Journal.Entry_key.t -> record:Wal.record -> unit Io.t

      val close : t -> unit Io.t
      val delete : t -> unit Io.t
      val mkdir : t -> unit Io.t
      val rmdir : t -> unit Io.t
      val rename : src:t -> dst:t -> unit Io.t
      val redo_local : Journal.op -> unit Io.t
      val symlink : target:string -> t -> unit Io.t

      (** A version fetched from the store takes the file's place here. *)
      val install_version : t -> Manifest.t -> unit Io.t

      (** A folder takes the id the store files it under. *)
      val adopt_id : t -> string -> unit Io.t

      val folder_marker_bkey : t -> Stored_key.t option Io.t
      val old_marker_or_fail : t -> Stored_key.t Io.t

      (** Where a folder whose creation is owed is now: a local rename may have
          moved it meanwhile, and it goes by its id. *)
      val current_place : string -> string -> t option Io.t

      (** Ours takes a conflicted name here, if it still holds [id]. *)
      val ours_aside : id:string option -> t -> unit Io.t

      val ours_aside_as_rename : filed_at:t -> id:string -> t -> unit Io.t

      (** What a peer's entry does to this client's tree. *)
      module Peer_entry : sig
        type store_reads = {
          markers : (Logical_key.t, string option) Hashtbl.t;
          manifests : (Logical_key.t, Manifest.t option) Hashtbl.t;
        }

        exception
          Unread of [ `Marker of Logical_key.t | `Manifest of Logical_key.t ]

        type place = {
          at : Logical_key.t;
          from : Logical_key.t option;
          ours : string option;
        }

        val manifest_of : store_reads -> t -> Manifest.t option Io.t
        val local_file : store_reads -> t -> t Io.t

        val gather :
          reads:store_reads ->
          owed:(Journal.Entry_key.t * Wal.record) list ->
          Journal.op ->
          (Resolve.Arrival.facts * place) Io.t

        (** Under the lock, from [reads] alone. *)
        val apply : reads:store_reads -> Journal.op list -> unit Io.t
      end
    end = struct
      module St = struct end [@@warning "-60"]
      module Js = struct end [@@warning "-60"]
      module Hs = struct end [@@warning "-60"]
      module R = struct end [@@warning "-60"]

      module D = struct
        let forget_chunks = D.forget_chunks
        let discard_staged = D.discard_staged
        let published = D.published
      end

      (* Metadata mutations (delete/mkdir/rmdir/rename/revert, foreign-op
         application) are serialized; reads, downloads and uploads stay concurrent.
         ponytail: one global metadata lock; switch to per-key locks only if
         unrelated metadata ops measurably contend. *)
      let meta_mutex = Lock.mutex ()
      let with_meta f = Lock.with_lock meta_mutex f
      let meta_locked () = Lock.is_locked meta_mutex
      let meta_waiters () = Lock.has_waiters meta_mutex

      let local_id key =
        Folders.lookup_id ~cache_root:C.cache_root ~domain_name:C.domain_name
          key

      let key_of_id id =
        Folders.key_of_id ~cache_root:C.cache_root ~domain_name:C.domain_name
          ~root:Lk.root id

      let folder_of_id = function
        | None -> Io.return None
        | Some id -> key_of_id id

      let whereabouts key =
        Folders.whereabouts ~cache_root:C.cache_root ~domain_name:C.domain_name
          ~root:Lk.root key

      let manifest_path key = Mf.path key
      let published = D.published
      let write_manifest key (state : Manifest.t) = Mf.write key state
      let delete_manifest key = Mf.delete key

      (* A symlink has no bytes to stage: what its upload owes is the manifest the
         mirror already holds. *)
      let symlink_manifest key =
        let+ m = published key in
        Option.bind m (fun m -> Option.map (fun _ -> m) (Manifest.symlink m))

      (* Directories exist only in the manifest mirror. *)
      let kind key =
        let+ mst = Fs.stat_opt_large (manifest_path key) in
        match mst with
          | Some { Unix.LargeFile.st_kind = Unix.S_DIR; _ } -> `Dir
          | Some _ -> `File
          | None -> `Absent

      (* The sidecar stays, so the file keeps its size, mtime and identity and
         re-fetches on demand. *)
      let evict key = D.forget_chunks key

      (* For a key that is gone: staged edits go too, there is nothing left to
         upload them to. *)
      let clear_local key =
        let* () = evict key in
        let* () = D.discard_staged key in
        delete_manifest key

      (* Recorded before this returns, which is what makes a crash here leave
         something saying the work is owed; handing it over only says who should
         get to it first.

         [Prepared]: the record names work whose local half is done, so a
         reconcile owes its backend half and must not repeat the local one. *)
      let hand_over queue entry_key ops =
        let record =
          { Wal.ops; state = Wal.Prepared; attempts = 0; last_error = None }
        in
        let* () = W.write entry_key record in
        Owed.signal queue (entry_key, record)

      let owe queue ops = hand_over queue (J.entry_key ()) ops

      (* A metadata op: the intent is recorded, then the local half happens, then
         the backend half is the metadata queue's, which runs it whenever the
         store can be reached. A crash inside the local half leaves the intent,
         and {!redo_local} finishes it; [local_half] answers [`Nothing] when it
         found the store is owed no word of it. *)
      let owing ops local_half =
        let entry_key = J.entry_key () in
        let* () = W.record entry_key ops in
        let* owed =
          Io.catch local_half (fun exn ->
              let* () = W.complete entry_key in
              Io.fail exn)
        in
        match owed with
          | `Nothing -> W.complete entry_key
          | `Backend_half -> hand_over W.meta_owed entry_key ops

      let write_folder_id key id =
        Io.map ignore
          (Folders.write ~cache_root:C.cache_root ~domain_name:C.domain_name key
             { Folder.name = Logical_key.leaf key; id })

      let owe_put key size = owe W.owed [`Put (rel_key key, size)]

      let queue_put key =
        let* staged = Mfs.read_edits key in
        match staged with
          | None ->
              Log.debug "queue_put %s: nothing staged, skipping"
                (Logical_key.to_string key);
              return_unit
          | Some st -> owe_put key st.Staged_manifest.s_size

      (* A staged file that moves keeps the upload it was owed. The queued record
         names the old path, which the upload gives up on once the bytes have gone
         from there, so that one is cancelled and the new path queued.

         Only what was owed is queued again: a file still open is queued when it
         is closed. Answers the keys queued, whose entries follow that of a move
         recorded before this was called, so a peer replays the move first. *)
      let rename_local ~src ~dst =
        let from = Logical_key.path src and onto = Logical_key.path dst in
        let rebase key =
          let rel = Logical_key.path key in
          Lk.file
            (onto
            ^ String.sub rel (String.length from)
                (String.length rel - String.length from))
        in
        let* moved =
          match Logical_key.kind src with
            | `File -> Io.return [(src, dst)]
            | `Dir ->
                let+ staged = Mfs.entries ~rel_dir:from ~deep:true in
                List.map (fun (key, _) -> (key, rebase key)) staged
        in
        let owed =
          List.filter_map
            (fun (old, key) -> if cancel_upload old then Some key else None)
            moved
        in
        let* () = Mfs.rename ~src_key:src ~dst_key:dst in
        let* () = Ck.rename ~src_key:src ~dst_key:dst in
        let+ () = iter_s queue_put owed in
        owed

      (* Either resume finds a record that already names the work, and writes it
         under its own key: one unit of work keeps one key across a restart. *)
      let resume_put key ~entry_key ~record =
        let* staged = Mfs.exists key in
        let* link = symlink_manifest key in
        if (not staged) && link = None then return_false
        else
          let* () = W.write entry_key record in
          let+ () = Owed.signal W.owed (entry_key, record) in
          true

      let resume_meta ~entry_key ~record =
        let* () = W.write entry_key record in
        Owed.signal W.meta_owed (entry_key, record)

      let close key =
        let* staged = Mfs.exists key in
        if staged then queue_put key else return_unit

      let delete key =
        with_meta (fun () ->
            ignore (cancel_upload key);
            owing
              [`Delete (rel_key key)]
              (fun () ->
                let+ () = clear_local key in
                `Backend_half))

      (* Backend key of a directory's folder marker, under its parent's namespace.
         [None] at the domain root, or for a parent this client never recorded;
         callers must skip rather than substitute a key, since the domain prefix is
         itself a real object. *)
      let folder_marker_bkey key = L.folder_marker_key key

      (* The marker a folder is filed under, or a failure: a caller about to move
         or retire a folder without removing its marker would leave the folder's
         id at two places, which is what a client resolving by id cannot tell
         apart. A parent this client holds no id for is refused, and the repair
         is a sync. *)
      let old_marker_or_fail key =
        let* old_marker = folder_marker_bkey key in
        match old_marker with
          | Some bkey -> Io.return bkey
          | None ->
              Io.fail
                (Backend.Backend_error
                   (Printf.sprintf
                      "%s: this client holds no id for the folder it is in; \
                       run 'tsync sync' first"
                      (Logical_key.to_string key)))

      (* The id is this client's to mint, siloed so no other client's can equal
         it, and final: the store is told of the folder by the metadata queue,
         which gives it a conflicted name rather than another id if the name is
         taken by then. *)
      let mkdir key =
        with_meta (fun () ->
            let* (_ : Stored_key.t) = old_marker_or_fail key in
            let* held = local_id key in
            let fid =
              match held with Some id -> id | None -> J.folder_id ()
            in
            owing
              [`Mkdir (rel_key key, Some fid)]
              (fun () ->
                let* () = Ck.create_dir key in
                let+ () = write_folder_id key fid in
                `Backend_half))

      (* O(1) delete: move the parent marker into the trash namespace. The subtree
         stays on the backend for undo, dropped later by [expire] and its chunks
         reclaimed by [gc]. *)
      let rmdir key =
        with_meta (fun () ->
            (* Read while the folder is still here: [Ck.delete_dir] takes the
               marker the id comes from, and the entry is the only place it goes
               on existing. *)
            let* fid = local_id key in
            (* Refused before anything is removed rather than parked after. *)
            let* (_ : Stored_key.t) = old_marker_or_fail key in
            owing
              [`Rmdir (rel_key key, fid)]
              (fun () ->
                let+ () = Ck.delete_dir key in
                `Backend_half))

      (* A conflict is settled by giving the loser a name of its own, which is the
         only settlement a directory admits: its subtree cannot be replaced the way
         a file's bytes can.

         A folder keeps its whole leaf, having no extension to preserve, and stays
         a folder: splitting [v1.2] would file the subtree under
         [v1 (conflicted copy from x).2]. *)
      let conflict_key ?(n = 1) key =
        let base = Logical_key.leaf key in
        let is_dir = Logical_key.kind key = `Dir in
        let name, ext =
          match String.rindex_opt base '.' with
            | Some i when not is_dir ->
                (String.sub base 0 i, String.sub base i (String.length base - i))
            | Some _ | None -> (base, "")
        in
        let copy =
          if n = 1 then "conflicted copy"
          else Printf.sprintf "conflicted copy %d" n
        in
        let base =
          Printf.sprintf "%s (%s from %s)%s" name copy C.client_name ext
        in
        let parent = Logical_key.parent key in
        if is_dir then Logical_key.dir_in parent base
        else Logical_key.file_in parent base

      (* Free locally, staged files included, which the mirror does not show: a
         second conflict on one name must not move onto the first one's copy. *)
      let aside_name key =
        let rec free n =
          let candidate = conflict_key ~n key in
          let* k = kind candidate in
          let* staged = Mfs.exists candidate in
          if k = `Absent && not staged then Io.return candidate else free (n + 1)
        in
        free 1

      (* Gives the loser of a conflict a name of its own and moves it there. The
         caller holds the metadata lock and says what the move is published as. *)

      let move_aside key =
        let* conflict = aside_name key in
        let+ (_ : Logical_key.t list) = rename_local ~src:key ~dst:conflict in
        conflict

      (* A folder sent aside, published as a rename from where the store files
         it. *)
      let publish_aside ~filed_at ~id key =
        let* conflict = aside_name key in
        owing
          [
            `Rename
              Journal.
                {
                  src = rel_key filed_at;
                  dst = rel_key conflict;
                  size = None;
                  is_dir = true;
                  id = Some id;
                };
          ]
          (fun () ->
            let+ (_ : Logical_key.t list) =
              rename_local ~src:key ~dst:conflict
            in
            `Backend_half)

      let rename_body ~src ~dst =
        let* k = kind src in
        let is_dir = k = `Dir in
        (* What it is is discovered here, from the tree, so the keys are renamed
           into folders once it is known. *)
        let as_dir k = if is_dir then Lk.dir (Logical_key.path k) else k in
        let src = as_dir src in
        let dst = as_dir dst in
        ignore (cancel_upload dst);
        (* Staged size wins: it is what a peer will fetch next. *)
        let* size =
          if is_dir then Io.return None
          else
            let+ resolved = Mf.current src in
            match resolved with
              | Some (`Staged (st, _)) -> Some st.Staged_manifest.s_size
              | Some (`Published m) -> Some (Manifest.size m)
              | None -> None
        in
        (* Refused before anything moves: a folder whose marker cannot be named is
           not renamed at all, rather than moved locally and left at two places on
           the store. *)
        let* () =
          if is_dir then
            let+ (_ : Stored_key.t) = old_marker_or_fail src in
            ()
          else return_unit
        in
        (* A folder's id travels with it, so it is read where the folder still
           is. *)
        let* dir_id = if is_dir then local_id src else Io.return None in
        owing
          [
            `Rename
              Journal.
                {
                  dst = rel_key dst;
                  src = rel_key src;
                  size;
                  is_dir;
                  id = dir_id;
                };
          ]
          (fun () ->
            let* requeued = rename_local ~src ~dst in
            let+ dst_staged = Mfs.exists dst in
            (* Never published under its old name: its upload, now under the new
               one, is all it owes. *)
            if List.mem dst requeued && dst_staged then `Nothing
            else `Backend_half)

      let rename ~src ~dst = with_meta (fun () -> rename_body ~src ~dst)

      (* The local half of an op whose intent a crash left behind, every step of
         which can be taken twice. A removal goes by the id it named, so a folder
         made at that path since is left alone. *)
      let redo_local op =
        with_meta (fun () ->
            match op with
              | `Put _ -> return_unit
              | `Delete rel -> clear_local (Lk.file rel)
              | `Mkdir (rel, id) -> (
                  let key = Lk.dir rel in
                  let* () = Ck.create_dir key in
                  match id with
                    | Some id -> write_folder_id key id
                    | None -> return_unit)
              | `Rmdir (rel, id) ->
                  let key = Lk.dir rel in
                  let* held = local_id key in
                  if held <> None && held = id then Ck.delete_dir key
                  else return_unit
              | `Rename { Journal.src; dst; is_dir; _ } ->
                  let key rel = if is_dir then Lk.dir rel else Lk.file rel in
                  let* from = kind (key src) in
                  let* onto = kind (key dst) in
                  if from <> `Absent && onto = `Absent then
                    Io.map ignore (rename_local ~src:(key src) ~dst:(key dst))
                  else return_unit)

      (* Only [`Keep] can create symlinks: the other policies must not put symlink
         objects in the domain, and "follow" is undefined at creation time (the
         target may be relative, dangling, or outside the mount). *)
      let symlink ~target key =
        (match C.symlink_policy with
          | `Keep -> ()
          | `Follow | `Skip ->
              raise
                (Unix.Unix_error
                   (Unix.EPERM, "symlink", Logical_key.to_string key)));
        with_meta (fun () ->
            let name = Logical_key.leaf key in
            let state =
              Manifest.make_symlink ~name ~target ~mtime:(Unix.gettimeofday ())
            in
            (* Local first, like any other change: the upload queue publishes the
               manifest the mirror holds once the store can be reached. *)
            ignore (cancel_upload key);
            let* () = write_manifest key state in
            owe_put key (Manifest.size state))

      (* Where a folder whose creation is owed is now: a local rename may have
         moved it meanwhile, and it goes by its id. *)
      let current_place rel id =
        with_meta (fun () ->
            let* found = key_of_id id in
            match found with
              | Some key -> return_some key
              | None ->
                  let key = Lk.dir rel in
                  let+ held = local_id key in
                  if held = Some id then Some key else None)

      let ours_aside ~id key =
        with_meta (fun () ->
            let* still = local_id key in
            if still = id then Io.map ignore (move_aside key) else return_unit)

      let ours_aside_as_rename ~filed_at ~id key =
        with_meta (fun () -> publish_aside ~filed_at ~id key)

      let install_version key m =
        with_meta (fun () ->
            let* () = write_manifest key m in
            (* Cached chunks are left alone: shared ones may still be wanted,
               missing ones fetch on demand. Staged edits, manifest and bodies
               both, are what a revert discards. *)
            D.discard_staged key)

      let adopt_id key id = with_meta (fun () -> write_folder_id key id)

      module Peer_entry = struct
        (* What a peer's folder rename finds at its destination in this mirror. A
         folder with no id, or an entry naming none, leaves nothing to compare and
         reads as free. *)
        let at_destination ~dst ~id =
          let* present = Syscalls.file_exists (manifest_path dst) in
          if not present then Io.return `Free
          else
            let+ held = local_id dst in
            match (held, id) with
              | Some held, Some moving when held = moving -> `Same_folder
              | Some held, Some _ -> `Another_folder held
              | _ -> `Free

        (* The destination already holds the folder being moved: the rename was
         applied here once and its source came back. The source takes a conflicted
         name and gives up the id it shares, keeping what it holds without two
         paths claiming one folder; the store is not told, already filing the
         folder where it now is. *)
        let retire_stale_copy ~src ~dst =
          let* conflict = move_aside src in
          let* () =
            Folders.forget ~cache_root:C.cache_root ~domain_name:C.domain_name
              conflict
          in
          (* [rename_local] pointed the shared id at the copy; this points it back. *)
          Folders.reparent ~cache_root:C.cache_root ~domain_name:C.domain_name
            dst

        (* A peer's folder op names its folder by id, and a local folder holding
         another id at that path is a different folder the op must leave alone. *)
        let another_folder_at key id =
          match id with
            | None -> Io.return None
            | Some id -> (
                let+ held = local_id key in
                match held with
                  | Some held when held <> id -> Some held
                  | _ -> None)

        (* The folder a peer created already lives here under another path: a
         rename moved it before this entry arrived, and creating it again would
         put its id at two places. *)
        let lives_elsewhere key id =
          match id with
            | None -> return_false
            | Some id ->
                let+ found = key_of_id id in
                Option.fold ~none:false
                  ~some:(fun found -> not (Logical_key.equal found key))
                  found

        (* What applying a peer's entry asks of the store, as answers rather than
           as a way to ask: nothing handed to the metadata lock can reach the
           store from inside it, so a slow link holds up that entry and not every
           local operation waiting behind it. *)
        type store_reads = {
          markers : (Logical_key.t, string option) Hashtbl.t;
              (** The id the store files under a folder's name. *)
          manifests : (Logical_key.t, Manifest.t option) Hashtbl.t;
        }

        exception
          Unread of [ `Marker of Logical_key.t | `Manifest of Logical_key.t ]

        let recall table missing key =
          match Hashtbl.find_opt table key with
            | Some known -> Io.return known
            | None -> Io.fail (Unread (missing key))

        let marker_at reads = recall reads.markers (fun key -> `Marker key)

        let manifest_of reads =
          recall reads.manifests (fun key -> `Manifest key)

        (* Where a folder a peer names by path is here: one this client moved since
         keeps its id and is found by it, and so is anything under it. The same
         folder only if the store still files it under the name: a peer's own
         folder there is another one. *)
        let rec local_folder reads key =
          if Logical_key.is_root key then Io.return key
          else
            let* place = whereabouts key in
            let* moved =
              match place with
                | `Moved (id, at) ->
                    let+ filed = marker_at reads key in
                    if filed = Some id then Some at else None
                | `Live _ | `Removed _ | `Unknown -> Io.return None
            in
            match (place, moved) with
              | `Live _, _ -> Io.return key
              | _, Some at -> Io.return at
              | _, None ->
                  let+ parent = local_folder reads (Logical_key.parent key) in
                  Logical_key.dir_in parent (Logical_key.leaf key)

        (* A file, or a folder a peer creates or moves to: its parent is found the
         same way, and its own name is the peer's. *)
        let local_child in_parent reads key =
          let+ parent = local_folder reads (Logical_key.parent key) in
          in_parent parent (Logical_key.leaf key)

        let local_file = local_child Logical_key.file_in
        let local_child_folder = local_child Logical_key.dir_in

        (* This client's file renames not published yet, oldest first, each with
         the record that owes it. *)
        let owed_file_renames records =
          List.concat_map
            (fun (entry_key, (r : Wal.record)) ->
              List.filter_map
                (function
                  | `Rename { Journal.src; dst; is_dir = false; _ } ->
                      Some (entry_key, (src, dst))
                  | _ -> None)
                r.Wal.ops)
            records

        (* Where a file a peer names now is here, after this client's own renames
         of it: a peer's edit follows the file it was made to. *)
        let renamed_since renames rel =
          let renames = List.map snd renames in
          let rec follow rel hops =
            match List.assoc_opt rel renames with
              | Some dst when hops > 0 -> follow dst (hops - 1)
              | _ -> rel
          in
          follow rel (List.length renames)

        (* This client's unpublished renames that brought a file of its own to
           [rel]. *)
        let renamed_onto renames rel =
          if List.exists (fun (_, (src, _)) -> src = rel) renames then []
          else
            List.filter (fun (_, (src, dst)) -> dst = rel && src <> rel) renames

        (* Without the local copy moved aside, both ends keep different bytes under
           one name, each with nothing left to apply. *)
        let retarget_our_rename renames rel =
          let* conflict = move_aside (Lk.file rel) in
          let retarget = function
            | `Rename ({ Journal.dst; is_dir = false; _ } as r) when dst = rel
              ->
                `Rename { r with Journal.dst = rel_key conflict }
            | op -> op
          in
          iter_s
            (fun (entry_key, _) -> W.update_ops entry_key (List.map retarget))
            (renamed_onto renames rel)

        (* Folders this client has an operation on that is not published yet. *)
        let owed_folder_ids records =
          List.concat_map
            (fun (_, (r : Wal.record)) ->
              List.filter_map
                (function
                  | `Mkdir (_, id)
                  | `Rmdir (_, id)
                  | `Rename { Journal.is_dir = true; id; _ } ->
                      id
                  | `Put _ | `Delete _ | `Rename _ -> None)
                r.Wal.ops)
            records

        (* What this client wrote under a folder a peer removed and has not
         published yet survives beside the folder under conflicted names, its
         uploads going with it; the folder itself goes. *)
        let rescue_staged folder =
          let* staged =
            Mfs.entries ~rel_dir:(Logical_key.path folder) ~deep:true
          in
          iter_s
            (fun (key, _) ->
              let* conflict =
                aside_name
                  (Logical_key.file_in
                     (Logical_key.parent folder)
                     (Logical_key.leaf key))
              in
              Io.map ignore (rename_local ~src:key ~dst:conflict))
            staged

        (* Where the op lands here, which the decision does not turn on. *)
        type place = {
          at : Logical_key.t;
          from : Logical_key.t option;
          ours : string option;
              (** The id of this client's folder in the way. *)
        }

        let gather ~reads ~owed op =
          match op with
            | `Put (rel, _) ->
                let renames = owed_file_renames owed in
                let* at =
                  local_file reads (Lk.file (renamed_since renames rel))
                in
                let folder = Lk.dir (Logical_key.path at) in
                let* there = kind folder in
                let* ours =
                  if there = `Dir then local_id folder else Io.return None
                in
                let+ staged = Mfs.exists at in
                ( Resolve.Arrival.Put
                    {
                      renamed_onto = renamed_onto renames rel <> [];
                      folder =
                        (match (there, ours) with
                          | `Dir, Some _ -> `Holds_id
                          | `Dir, None -> `Holds_no_id
                          | (`File | `Absent), _ -> `Absent);
                      staged;
                    },
                  { at; from = None; ours } )
            | `Delete rel ->
                let* at = local_file reads (Lk.file rel) in
                let+ staged = Mfs.exists at in
                ( Resolve.Arrival.Delete { staged },
                  { at; from = None; ours = None } )
            | `Mkdir (rel, id) ->
                let* at = local_child_folder reads (Lk.dir rel) in
                let* lives_elsewhere = lives_elsewhere at id in
                let* staged_file = Mfs.exists (Lk.file (Logical_key.path at)) in
                let+ ours = another_folder_at at id in
                ( Resolve.Arrival.Mkdir
                    {
                      lives_elsewhere;
                      staged_file;
                      another_folder = ours <> None;
                    },
                  { at; from = None; ours } )
            | `Rmdir (rel, id) -> (
                let* found = folder_of_id id in
                match found with
                  | Some at ->
                      Io.return
                        ( Resolve.Arrival.Rmdir { target = `By_id },
                          { at; from = None; ours = None } )
                  | None ->
                      let at = Lk.dir rel in
                      let+ ours = another_folder_at at id in
                      ( Resolve.Arrival.Rmdir
                          {
                            target =
                              (if ours = None then `At_path
                               else `Held_by_another);
                          },
                        { at; from = None; ours } ))
            | `Rename { Journal.src; dst; is_dir = true; id; _ } ->
                let* at = local_child_folder reads (Lk.dir dst) in
                let path = Lk.dir src in
                let* here = kind path in
                let* taken = another_folder_at path id in
                (* The path first: a copy under the new name may already hold the
                   id, and the one to move is still where the peer's op says. *)
                let* source, from =
                  if here = `Dir && taken = None then
                    Io.return (`At_path, Some path)
                  else
                    let+ found = folder_of_id id in
                    ((if found = None then `Gone else `By_id), found)
                in
                let+ destination = at_destination ~dst:at ~id in
                ( Resolve.Arrival.Rename_folder
                    {
                      ours_owed =
                        Option.fold ~none:false
                          ~some:(fun id -> List.mem id (owed_folder_ids owed))
                          id;
                      source;
                      already_there =
                        Option.fold ~none:false ~some:(Logical_key.equal at)
                          from;
                      destination =
                        (match destination with
                          | `Free -> `Free
                          | `Same_folder -> `Same_folder
                          | `Another_folder _ -> `Another_folder);
                    },
                  {
                    at;
                    from;
                    ours =
                      (match destination with
                        | `Another_folder ours -> Some ours
                        | `Free | `Same_folder -> None);
                  } )
            | `Rename { Journal.src; dst; is_dir = false; _ } ->
                let* from = local_file reads (Lk.file src) in
                let* at = local_file reads (Lk.file dst) in
                let* source_here = Syscalls.file_exists (manifest_path from) in
                let+ staged_destination = Mfs.exists at in
                ( Resolve.Arrival.Rename_file { source_here; staged_destination },
                  { at; from = Some from; ours = None } )

        (* A decision names a source or a folder in the way only when {!gather}
           found one. *)
        let found what = function
          | Some found -> found
          | None -> invalid_arg ("File.Foreign: no " ^ what)

        let write_theirs ~reads ~theirs at =
          ignore (cancel_upload at);
          let* m = manifest_of reads theirs in
          match m with
            | None -> return_unit
            | Some state -> write_manifest at state

        let enact ~reads ~owed op place (action : Resolve.Arrival.action) =
          let folder = Lk.dir (Logical_key.path place.at) in
          let file = Lk.file (Logical_key.path place.at) in
          match (action, op) with
            | Resolve.Arrival.Retarget_our_rename, `Put (rel, _) ->
                retarget_our_rename (owed_file_renames owed) rel
            | Our_folder_aside `Published_as_rename, _ ->
                publish_aside ~filed_at:folder
                  ~id:(found "folder" place.ours)
                  folder
            | Our_folder_aside `Here_only, _ ->
                Io.map ignore (move_aside folder)
            | Our_staged_file_aside, _ ->
                let* conflict = move_aside file in
                queue_put conflict
            | Rescue_staged_under, _ -> rescue_staged place.at
            | Write_theirs, `Put (rel, _) ->
                write_theirs ~reads ~theirs:(Lk.file rel) place.at
            | Adopt_theirs_at_destination, `Rename { Journal.dst; _ } ->
                write_theirs ~reads ~theirs:(Lk.file dst) place.at
            | Remove_file, _ ->
                ignore (cancel_upload place.at);
                clear_local place.at
            | Make_folder, `Mkdir (_, id) -> (
                let* () = Ck.create_dir place.at in
                (* A folder's id is final from its mkdir, so the op's is taken as
                   is; the store may still file another folder under this name
                   until that one's rename lands. *)
                  match id with
                  | Some id -> write_folder_id place.at id
                  (* One recorded with no id was adopted from the store's marker
                     ahead of the lock, or holds none. *)
                  | None -> return_unit)
            | Remove_folder, _ -> Ck.delete_dir place.at
            | (Move_folder | Move_file), _ ->
                Io.map ignore
                  (rename_local ~src:(found "source" place.from) ~dst:place.at)
            | Retire_stale_source, _ ->
                retire_stale_copy ~src:(found "source" place.from) ~dst:place.at
            | ( ( Retarget_our_rename | Write_theirs
                | Adopt_theirs_at_destination | Make_folder ),
                _ ) ->
                invalid_arg "File.Foreign: an action its op cannot take"

        (* Failures propagate: the sync poller must not advance its high-water mark
           past an entry it could not apply, or the op is lost until a full resync. *)
        let apply_one ~reads ~owed op =
          let* facts, place = gather ~reads ~owed op in
          let decision = Resolve.Arrival.decide facts in
          if Resolve.Arrival.clashed decision then
            Log.info "peer %s: %s: %s"
              (String.concat ", " (Journal.keys_of_op op))
              (Resolve.Arrival.facts_to_string facts)
              (Resolve.Arrival.decision_to_string decision);
          match decision with
            | Resolve.Arrival.Skip _ -> return_unit
            | Apply actions -> iter_s (enact ~reads ~owed op place) actions

        (* A read nothing made ahead is one this client's own change since made
           necessary, and the entry is read again rather than the store asked
           with the lock held. *)
        let apply ~reads ops =
          Io.catch
            (fun () ->
              with_meta (fun () ->
                  let* owed = W.owed_metadata () in
                  iter_s (apply_one ~reads ~owed) ops))
            (function
              | Unread (`Marker key | `Manifest key) ->
                  Io.fail
                    (Retry.failed ~kind:Retry.Transient ~op:"apply"
                       (Logical_key.to_string key
                      ^ ": changed here while the entry was being read"))
              | exn -> Io.fail exn)
      end
    end

    include Local

    (* Nothing staged is ENOENT, which the sending pool takes to mean the upload
       is no longer owed: [D.sync] answers it with nothing done, and the pool
       would then publish an entry for a file that was never sent. *)
    let upload ?cancel key =
      let* staged = Mfs.read key in
      match staged with
        | Some _ -> D.sync key ?cancel ()
        | None -> (
            let* link = symlink_manifest key in
            match link with
              | Some m ->
                  let name = Logical_key.leaf key in
                  St.put_manifest ~key ~data:(Manifest.body ~name m)
              | None ->
                  Io.fail
                    (Unix.Unix_error
                       (Unix.ENOENT, "upload", Logical_key.to_string key)))

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

    let stat key =
      let* mst = Fs.stat_opt_large (manifest_path key) in
      match mst with
        | Some { Unix.LargeFile.st_kind = Unix.S_DIR; _ } ->
            return_some (dir_stat ())
        | Some _ | None -> (
            let* m = Mf.current key in
            match m with
              | Some (`Staged (st, _)) ->
                  return_some
                    (file_stat st.Staged_manifest.s_size
                       st.Staged_manifest.s_mtime)
              | Some (`Published m) -> (
                  match Manifest.symlink m with
                    | Some target ->
                        return_some (symlink_stat target (Manifest.mtime m))
                    | None ->
                        return_some
                          (file_stat (Manifest.size m) (Manifest.mtime m)))
              | None -> Io.return None)

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
    let read_ahead_in_flight = D.read_ahead_in_flight

    let staged_count () =
      let+ keys = Mfs.list () in
      List.length keys

    let downloads_completed_count = D.downloads_completed_count
    let download_progress = D.download_progress
    let create key = D.create key
    let write_whole key ~src_path = D.stage_whole key ~src_path

    let read ?stream key (buf : File_ops.buffer) ~offset =
      D.pread_key ?stream key buf ~offset

    (* What to call a row, and where the file sits under the domain root. The
       queue and the pull tracker hold rendered keys, so this takes one back
       apart; a key from either is this domain's by construction. *)
    let describe key =
      match Option.map Lk.file (Lk.rel_of_string key) with
        | Some k -> (Logical_key.leaf k, rel_key k)
        | None -> (Filename.basename key, key)

    let uploads_in_flight () =
      filter_map_s
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

    let save_version key =
      if C.versioning then Hs.save_version ~key else return_unit

    (* The backend half alone, which is what the queue owes; [apply_delete] is
       the whole op, owed by a replay of an intent that never started. *)
    let delete_remote key =
      let* () = save_version key in
      St.delete_manifest ~key

    let apply_delete key =
      let* () = delete_remote key in
      clear_local key

    (* For a file whose chunks are already on the backend: only the manifest key
       and journal entry are missing. *)
    let publish_manifest key (m : Manifest.t) =
      Log.info "publish_manifest %s: size=%Ld"
        (Logical_key.to_string key)
        (Manifest.size m);
      let name = Logical_key.leaf key in
      let* () = St.put_manifest ~key ~data:(Manifest.body ~name m) in
      let* ek = Js.write_journal_entry [`Put (rel_key key, Manifest.size m)] in
      Js.bump_cursor ek

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

    let revert ?version key =
      let* src_key =
        match version with
          | Some ts -> (
              let* dir = Hs.version_dir ~key in
              match dir with
                | Some dir -> Io.return (Stored_key.under dir ts)
                | None -> failwith ("no versions for " ^ rel_key key))
          | None -> (
              let* entries = Hs.list_versions ~key in
              match latest_version entries with
                | Some (k, _) -> Io.return k
                | None -> failwith ("no versions for " ^ rel_key key))
      in
      let* data = Hs.get_version ~vkey:src_key in
      let m = Manifest.of_string data in
      ignore (cancel_upload key);
      (* Restored under the name the snapshot recorded, which is the one its
         body already carries. *)
      let* () =
        St.put_manifest ~key
          ~data:(Manifest.body ~name:(Manifest.recorded_name m) m)
      in
      let* () = install_version key m in
      let* ek = Js.write_journal_entry [`Put (rel_key key, Manifest.size m)] in
      Js.bump_cursor ek

    (* What the metadata queue owes the store for ops already applied here. *)
    module Backend_half = struct
      (* The folder already lives at its new place by the time this runs, its
       anchor and marker written, so a delete that found nothing costs no
       correctness: whatever sits at the old key is disowned by the anchor and
       skipped by every reader until a repair removes it. Said out loud all the
       same, being a store that did not do what it was asked. *)
      let remove_old_marker key bkey ~id =
        let* there = St.marker_id_at ~bkey in
        match there with
          | Some other when other <> id ->
              (* Another folder has taken the name since, and its marker is not
               this one's to remove. *)
              Log.info
                "%s: the marker at %s now names %s, not %s; left in place"
                (Logical_key.to_string key)
                (Stored_key.to_string bkey)
                other id;
              return_unit
          | Some _ ->
              let+ (_ : bool) = St.delete_raw ~bkey in
              ()
          | None ->
              Log.err
                "%s: the store held no marker at %s; nothing was left behind"
                (Logical_key.to_string key)
                (Stored_key.to_string bkey);
              return_unit

      (* Moving an object on the backend does not rewrite its body, so the copy at
       the new key still records the old leaf. Unconditional: the mirror is
       already stamped by the time this runs, so its body cannot be used to detect
       whether the backend's needs it. *)
      let resync_manifest_name key =
        let name = Logical_key.leaf key in
        let* m = published key in
        match m with
          | Some man -> St.put_manifest ~key ~data:(Manifest.body ~name man)
          | None -> return_unit

      (* Whether the store was ever told of a folder: an anchor anywhere, or, for
       one written before anchors were, its marker where the op found it. *)
      let ever_published ~bkey id =
        let* anchor = St.get_anchor ~folder_id:id in
        match anchor with
          | Some _ -> return_true
          | None ->
              let+ there = St.marker_id_at ~bkey in
              there = Some id

      (* The entry before the anchor, so a folder anchored to the trash always
         has one; the anchor before the live marker goes, so the marker is stale
         from here whether or not its delete lands. *)
      let retire_to_trash ~rel ~id ~old_marker =
        let name = Filename.basename rel in
        let trash_key =
          Stored_key.under
            (Stored_key.trash_namespace ~prefix:C.domain_prefix)
            (Id.short ())
        in
        let marker = Folder.trash_marker_to_string ~name ~id ~path:rel in
        let* () = St.put_raw ~bkey:trash_key ~data:marker in
        let* () =
          St.put_anchor ~folder_id:id ~parent:Stored_key.trash_id ~name
        in
        remove_old_marker (Lk.dir rel) old_marker ~id

      (* Whether the store already files a different folder under [dst]'s name. *)
      let taken_by_another ~dst ~id =
        let* bkey = folder_marker_bkey dst in
        match bkey with
          | None -> return_false
          | Some bkey -> (
              let+ there = St.holder_at ~bkey in
              match there with Some other -> other <> id | None -> false)

      (* Where the store files a folder against where it is here. *)
      let placement key id =
        let* parent = local_id (Logical_key.parent key) in
        match parent with
          | None -> Io.return `Unanchored
          | Some parent ->
              St.placed ~folder_id:id
                ~at:{ Folder.parent; name = Logical_key.leaf key }

      (* What the decision does not turn on and the enactment needs. *)
      type place = {
        here : Logical_key.t option;  (** Where a folder is here now. *)
        id : string option;
        old_marker : Stored_key.t option;
        failure : exn option;  (** What the attempted move raised. *)
      }

      let nowhere =
        { here = None; id = None; old_marker = None; failure = None }

      let gather_mkdir rel id =
        let* here = current_place rel id in
        match here with
          | None -> Io.return (Resolve.Publish.Mkdir `Gone_here, nowhere)
          | Some key -> (
              let place = { nowhere with here; id = Some id } in
              let* placed = placement key id in
              match placed with
                | `Elsewhere _ ->
                    Io.return (Resolve.Publish.Mkdir `Filed_elsewhere, place)
                | `Here | `Unanchored ->
                    let+ claimed = St.claim_folder ~id key in
                    ( Resolve.Publish.Mkdir
                        (match claimed with
                          | `Held -> `Claimed
                          | `Taken _ -> `Name_taken),
                      place ))

      let gather_rmdir rel id =
        let* old_marker = old_marker_or_fail (Lk.dir rel) in
        let place =
          { nowhere with id = Some id; old_marker = Some old_marker }
        in
        let* anchor = St.get_anchor ~folder_id:id in
        match anchor with
          | Some a when Folder.in_trash a ->
              Io.return (Resolve.Publish.Rmdir `Already_trashed, place)
          | _ ->
              let+ published = ever_published ~bkey:old_marker id in
              ( Resolve.Publish.Rmdir
                  (if published then `Published else `Never_published),
                place )

      (* A directory's backend keys hang off its folder id, which travelled with
         the local [.tsync-dir] marker: only the parent's marker moves, to where
         the folder is here now, which a later local move or a conflict may have
         changed since this was recorded. *)
      let gather_rename_folder (r : Journal.rename_op) =
        let* id =
          match r.Journal.id with
            | Some id -> Io.return id
            | None -> St.ensure_folder_id (Lk.dir r.Journal.dst)
        in
        let* here = current_place r.Journal.dst id in
        match here with
          | None -> Io.return (Resolve.Publish.Rename_folder `Gone_here, nowhere)
          | Some dst ->
              let place = { nowhere with here; id = Some id } in
              let* placed = placement dst id in
              if placed = `Here then
                Io.return
                  (Resolve.Publish.Rename_folder `Filed_here_already, place)
              else
                let* old_marker = old_marker_or_fail (Lk.dir r.Journal.src) in
                let place = { place with old_marker = Some old_marker } in
                let* published = ever_published ~bkey:old_marker id in
                if not published then
                  Io.return
                    (Resolve.Publish.Rename_folder `Never_published, place)
                else
                  let+ taken = taken_by_another ~dst ~id in
                  ( Resolve.Publish.Rename_folder
                      (if taken then `Name_taken else `Free),
                    place )

      (* A file's key encodes its leaf, so the object itself moves, and the move
         is attempted before anything is asked: only one that failed costs the
         reads that say why. *)
      let gather_rename_file (r : Journal.rename_op) =
        let src = Lk.file r.Journal.src and dst = Lk.file r.Journal.dst in
        Io.catch
          (fun () ->
            let* () = save_version src in
            let* () = Js.rename_file ~src_key:src ~dst_key:dst in
            let+ () = resync_manifest_name dst in
            (Resolve.Publish.Rename_file `Moved, nowhere))
          (fun exn ->
            let place = { nowhere with failure = Some exn } in
            let* src_head = Js.head_manifest_opt ~key:src in
            if Option.is_some src_head then
              Io.return (Resolve.Publish.Rename_file `Source_still_there, place)
            else
              let* dst_head = Js.head_manifest_opt ~key:dst in
              if Option.is_some dst_head then
                Io.return (Resolve.Publish.Rename_file `Landed, place)
              else
                let+ ours = Mf.current dst in
                ( Resolve.Publish.Rename_file
                    (`Source_gone
                       (match ours with
                         | Some (`Staged _) -> `Staged
                         | Some (`Published _) -> `Published
                         | None -> `Absent)),
                  place ))

      let gather op =
        match op with
          | `Put _ -> Io.return (Resolve.Publish.Put, nowhere)
          | `Delete rel ->
              let+ now = kind (Lk.file rel) in
              ( Resolve.Publish.Delete
                  (if now = `File then `A_file_here_again else `Gone_here),
                nowhere )
          | `Mkdir (_, None) -> Io.return (Resolve.Publish.Mkdir `No_id, nowhere)
          | `Mkdir (rel, Some id) -> gather_mkdir rel id
          | `Rmdir (rel, None) ->
              Log.err "rmdir %s: the entry carries no folder id" rel;
              Io.return (Resolve.Publish.Rmdir `No_id, nowhere)
          | `Rmdir (rel, Some id) -> gather_rmdir rel id
          | `Rename ({ Journal.is_dir = true; _ } as r) ->
              gather_rename_folder r
          | `Rename r -> gather_rename_file r

      (* A decision names an id, a place or a marker only when {!gather} found
         one. *)
      let found what = function
        | Some found -> found
        | None -> invalid_arg ("File.Backend_half: no " ^ what)

      let enact op place (action : Resolve.Publish.action) =
        match (action, op) with
          | Resolve.Publish.Remove_from_store, `Delete rel ->
              delete_remote (Lk.file rel)
          | Put_marker, `Mkdir (rel, _) ->
              St.put_folder_marker ~key:(Lk.dir rel)
          | Retire_to_trash, `Rmdir (rel, _) ->
              retire_to_trash ~rel ~id:(found "id" place.id)
                ~old_marker:(found "marker" place.old_marker)
          (* The new place first, anchor and marker, then the old marker: a crash
             between the two leaves a stale marker readers skip, not a folder
             nobody lists. *)
          | Move_marker, `Rename { Journal.src; _ } ->
              let* () = St.put_folder_marker ~key:(found "place" place.here) in
              remove_old_marker (Lk.dir src)
                (found "marker" place.old_marker)
                ~id:(found "id" place.id)
          | Ours_aside, _ -> ours_aside ~id:place.id (found "place" place.here)
          (* Rather than having its marker written over the other's. *)
          | Ours_aside_as_rename, `Rename { Journal.src; _ } ->
              ours_aside_as_rename ~filed_at:(Lk.dir src)
                ~id:(found "id" place.id) (found "place" place.here)
          | Queue_upload, `Rename { Journal.dst; _ } -> queue_put (Lk.file dst)
          | Republish_here, `Rename { Journal.dst; _ } -> (
              let dst = Lk.file dst in
              let* m = published dst in
              match m with
                | Some m -> publish_manifest dst m
                | None -> return_unit)
          | ( ( Remove_from_store | Put_marker | Retire_to_trash | Move_marker
              | Ours_aside_as_rename | Queue_upload | Republish_here ),
              _ ) ->
              invalid_arg "File.Backend_half: an action its op cannot take"

      (* A folder is published where it is here, which is not always where the
         op recorded it. *)
      let as_published op place =
        match (op, place.here) with
          | `Mkdir (_, id), Some key -> `Mkdir (rel_key key, id)
          | `Rename ({ Journal.is_dir = true; _ } as r), Some key ->
              `Rename { r with Journal.dst = rel_key key }
          | op, _ -> op

      (* The backend half of an op whose local half the caller has already
         applied, which is all the metadata queue owes, answering what to publish
         in its place. *)
      let rec backend_op op =
        let* facts, place = gather op in
        let decision = Resolve.Publish.decide facts in
        if Resolve.Publish.clashed decision then
          Log.info "publish %s: %s: %s"
            (String.concat ", " (Journal.keys_of_op op))
            (Resolve.Publish.facts_to_string facts)
            (Resolve.Publish.decision_to_string decision);
        let* () = iter_s (enact op place) decision.actions in
        match decision.ending with
          | Publish -> Io.return [as_published op place]
          | Nothing_owed -> Io.return []
          | Again -> backend_op op
          | Superseded -> Io.fail Retry.Cancelled
          | Retry -> Io.fail (found "failure" place.failure)

      let backend_ops ops =
        let+ published = map_s backend_op ops in
        List.concat published
    end

    let backend_ops = Backend_half.backend_ops

    (* What a peer's entry does to this client's tree. *)
    module Foreign = struct
      open Peer_entry

      (* Adopt the id from the backend marker, for a folder no op named: resolving
       it locally would mint a different one and split the namespace in two. A
       folder the store no longer files under this name stays id-less until a
       full sync, and nothing under it can be named. *)
      let adopt_folder_id rel =
        if rel = "" then return_unit
        else (
          let key = Lk.dir rel in
          let* marker_key = folder_marker_bkey key in
          match marker_key with
            | None -> return_unit
            | Some bkey -> (
                (* A store that cannot answer fails the entry, which is read
                 again, rather than passing for a name nobody holds. *)
                let* holder = St.holder_at ~bkey in
                match holder with
                  | None -> return_unit
                  | Some id -> (
                      let* place = whereabouts key in
                      let* here = kind key in
                      match place with
                        (* A folder this client moved or removed since is not
                         brought back where it was. *)
                        | (`Moved (held, _) | `Removed held)
                          when held = id && here <> `Dir ->
                            return_unit
                        | _ -> adopt_id key id)))

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
        iter_s
          (fun dir ->
            let* known = local_id dir in
            match known with
              | Some _ -> return_unit
              | None -> adopt_folder_id (Logical_key.path dir))
          (ancestors [] (Lk.dir rel))

      let marker_at_store key =
        let* bkey = folder_marker_bkey key in
        match bkey with
          | None -> Io.return None
          | Some bkey -> St.holder_at ~bkey

      (* A peer's object is in the namespace of the folder it names, which is the
       one found here: never a folder this client only remembers at the path,
       whose namespace holds this client's own files. *)
      let fetch_peer reads key =
        let* local = local_file reads key in
        let* parent = local_id (Logical_key.parent local) in
        match parent with
          | None -> Io.return None
          | Some _ -> R.fetch_manifest ~key:local ()

      let rec fill reads = function
        | `Marker key ->
            let+ id = marker_at_store key in
            Hashtbl.replace reads.markers key id
        | `Manifest key ->
            Io.catch
              (fun () ->
                let+ m = fetch_peer reads key in
                Hashtbl.replace reads.manifests key m)
              (function
                | Unread missing ->
                    let* () = fill reads missing in
                    fill reads (`Manifest key)
                | exn -> Io.fail exn)

      (* Ancestor ids first, since a manifest's key is built from its folder's
         id, so a missing one does not fail loudly: it resolves to no key and
         the put is skipped. *)
      let adopt_for = function
        | `Put (rel, _) | `Mkdir (rel, _) | `Rename { Journal.dst = rel; _ } ->
            adopt_ancestor_ids rel
        | `Delete _ | `Rmdir _ -> return_unit

      (* Makes the decision {!apply_one} will, ahead of the lock, and asks the
         store for each answer that takes: a pass stops at the first one it
         lacks, which is fetched before the next. *)
      let read_ahead ~owed ops =
        let reads =
          { markers = Hashtbl.create 8; manifests = Hashtbl.create 8 }
        in
        let theirs = function
          | `Put (rel, _) | `Rename { Journal.dst = rel; is_dir = false; _ } ->
              Io.map ignore (manifest_of reads (Lk.file rel))
          | `Delete _ | `Mkdir _ | `Rmdir _ | `Rename _ -> return_unit
        in
        let survey op =
          let* facts, place = gather ~reads ~owed op in
          match (Resolve.Arrival.decide facts, op) with
            | Resolve.Arrival.Skip _, _ -> return_unit
            | Apply actions, `Mkdir (_, None)
              when List.mem Resolve.Arrival.Make_folder actions ->
                adopt_folder_id (Logical_key.path place.at)
            | Apply actions, _
              when List.exists
                     (function
                       | Resolve.Arrival.Write_theirs
                       | Adopt_theirs_at_destination ->
                           true
                       | _ -> false)
                     actions ->
                theirs op
            | Apply _, _ -> return_unit
        in
        let rec pass () =
          Io.catch
            (fun () -> iter_s survey ops)
            (function
              | Unread missing ->
                  let* () = fill reads missing in
                  pass ()
              | exn -> Io.fail exn)
        in
        let* () = iter_s adopt_for ops in
        let+ () = pass () in
        reads

      (* The log is read here for the reads ahead, and again under the lock. *)
      let apply_foreign_ops ops =
        let* owed = W.owed_metadata () in
        let* reads = read_ahead ~owed ops in
        apply ~reads ops
    end

    let apply_foreign_ops = Foreign.apply_foreign_ops
  end
end
