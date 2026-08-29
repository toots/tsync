(** The local index of which directory carries which id, and the cache tree
    beside it — both rebuilt from what the walk finds. *)
module type FOLDER_IDS = sig
  type 'a io

  val write :
    cache_root:string ->
    domain_name:string ->
    Logical_key.t ->
    Folder.marker ->
    unit io
end

module type CACHE = sig
  type 'a io

  val clear : cache_root:string -> domain_name:string -> unit io
end

(** The bound on what runs at once. *)
module type POOLS = sig
  type 'a io
  type t

  val create : ?max_waiting:int -> ?name:string -> max:int -> unit -> t
  val use : t -> (unit -> 'a io) -> 'a io
  val map_with : t -> ('a -> 'b io) -> 'a list -> 'b list io
end

type outcome =
  | Full of { manifests : int; failed : int; reason : string }
  | Incremental of { applied : int }

type progress = {
  on_phase : string -> unit;
  on_current : string option -> unit;
}

let no_progress = { on_phase = (fun _ -> ()); on_current = (fun _ -> ()) }

(** Walking the backend's folder tree, which is how a whole domain is reached
    from its root. *)
module type TREE = sig
  type 'a io
  type pool

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val children :
      ?on_unusable:Inode_tree.on_unusable ->
      ?refresh_index:bool ->
      ?on_index:(Stored_key.t -> unit) ->
      ?slots:pool ->
      folder_id:string ->
      unit ->
      Inode_tree.entry list io

    val fold_tree :
      ?on_unusable:Inode_tree.on_unusable ->
      ?refresh_index:bool ->
      ?on_index:(Stored_key.t -> unit) ->
      ?slots:pool ->
      folder_id:string ->
      key:Logical_key.t ->
      ('a -> Logical_key.t -> Inode_tree.entry -> 'a io) ->
      'a ->
      'a io
  end
end

(** The local mark on the shared journal, and the entries behind it. *)
module type CURSOR = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val read_last_sync_key : unit -> Journal.Entry_key.t option
    val write_last_sync_key : Journal.Entry_key.t -> unit

    val list_journal_keys :
      ?start_after:Journal.Entry_key.t -> unit -> Journal.Entry_key.t list io

    val flush_cursor : unit -> unit io
  end
end

(** Writing a manifest into the local mirror, which is what a resync rebuilds,
    and the record half a queue drains. *)
module type CHECKOUT = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    include File.Owing with type 'a io := 'a io
    include File_ops.S with type 'a io := 'a io

    val write_manifest : Logical_key.t -> Manifest.t -> unit io
  end
end

(** The two directions of the journal: what a peer left to apply, and what this
    client left to finish. *)
module type SYNC = sig
  type 'a io

  module Queue
      (_ : Conf.S with type 'a io = 'a io)
      (_ : File.Owing with type 'a io := 'a io) : sig
    val start : on_upload_done:(key:Logical_key.t -> unit io) -> unit
    val drain : unit -> unit io
  end

  module Replay
      (_ : Conf.S with type 'a io = 'a io)
      (_ : File_ops.S with type 'a io := 'a io) : sig
    val reconcile : unit -> unit io
    val apply_foreign : on_changed:(string -> unit) -> unit -> int io
  end
end

module type FILING = sig
  type 'a io

  module Make (_ : Conf.S with type 'a io = 'a io) : sig
    val record : parent:Logical_key.t -> Inode_tree.entry -> Logical_key.t io
  end
end

module Over
    (Io : Io.S)
    (Folder_ids : FOLDER_IDS with type 'a io := 'a Io.t)
    (Cache : CACHE with type 'a io := 'a Io.t)
    (Pools : POOLS with type 'a io := 'a Io.t)
    (Tree : TREE with type 'a io := 'a Io.t and type pool := Pools.t)
    (Cursor_of : CURSOR with type 'a io := 'a Io.t)
    (Checkout : CHECKOUT with type 'a io := 'a Io.t)
    (Filing : FILING with type 'a io := 'a Io.t)
    (Sync : SYNC with type 'a io := 'a Io.t) =
struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x
  let return_some x = Io.return (Some x)

  let rec iter_s f = function
    | [] -> Io.return ()
    | x :: rest ->
        let* () = f x in
        iter_s f rest

  let rec map_s f = function
    | [] -> Io.return []
    | x :: rest ->
        let* y = f x in
        let+ ys = map_s f rest in
        y :: ys

  let rec filter_map_s f = function
    | [] -> Io.return []
    | x :: rest -> (
        let* y = f x in
        let+ ys = filter_map_s f rest in
        match y with Some y -> y :: ys | None -> ys)

  let rec fold_left_s f acc = function
    | [] -> Io.return acc
    | x :: rest ->
        let* acc = f acc x in
        fold_left_s f acc rest

  let iter_p f xs = Io.iter_p f xs

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Lk = Logical_key.Make (C)
    module J = Journal.Make (C)
    module Cursor = Cursor_of.Make (C)
    module F = Checkout.Make (C)
    module Fl = Filing.Make (C)
    module Sq = Sync.Queue (C) (F)
    module Rp = Sync.Replay (C) (F)
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
        let* filed = Fl.record ~parent:key entry in
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

    let full_resync ~parallelism ~progress ~on_manifest ~notify reason =
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
      if failed = 0 then Cursor.write_last_sync_key (J.entry_key ());
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
            full_resync ~parallelism ~progress ~on_manifest ~notify reason
        | None -> incremental ~progress ()

    let client_uuid = J.client_uuid
  end
end
