open Tsync_core
open Tsync_remote
open Tsync_checkout

let horizon = 30. *. 86400.

(* How long what an entry may still name is kept: a week past the horizon. *)
let nameable = horizon +. (7. *. 86400.)
let list_slack = 86400.
let rekey_age = 86400.
let sweep = 60.
let retry_floor = 2.
let claim_settle = 600.

type bridge = Incremental | Hold of string

module Make (C : Engine_ctx.S) = struct
  include Local_ops.Make (C)

  let bridge_state = Atomic.make Incremental
  let stepped_aside : (string, string) Hashtbl.t = Hashtbl.create 8
  let stepped_m = Mutex.create ()
  let gate = Atomic.make false
  let gate_signal = Rt.Signal.create ()
  let poll_signal = Rt.Signal.create ()
  let paused = Atomic.make false
  let gate_m = Mutex.create ()
  let link_failures = ref 0

  (* A pass passes [since], the {!gate_epoch} it began at: one that began
     before the last link failure leaves the gate closed. *)
  let open_gate ?since () =
    let opened =
      Mutex.protect gate_m (fun () ->
          match since with
            | Some e when e <> !link_failures -> false
            | _ ->
                Atomic.set gate true;
                true)
    in
    if opened then Rt.Signal.broadcast gate_signal

  let gate_epoch () = Mutex.protect gate_m (fun () -> !link_failures)

  let close_gate () =
    Mutex.protect gate_m (fun () ->
        incr link_failures;
        Atomic.set gate false)

  (* wal-and-journal §4.2 rule 9: neither queue publishes before a clean apply
     pass that began after the start or the last link failure. *)
  let wait_gate () =
    let rec loop () =
      let since = Rt.Signal.version gate_signal in
      if
        not
          (Atomic.get gate || C.lazy_tree
          || Atomic.get bridge_state <> Incremental)
      then (
        Rt.first
          [
            (fun () -> Rt.Signal.wait ~since gate_signal);
            (fun () ->
              Stop.wait ();
              raise Stop.Stopping);
          ];
        loop ())
    in
    loop ()

  let note_link_failure = function
    | Fail.E { kind = Link | Unreachable; _ } -> close_gate ()
    | _ -> ()

  let read_record id =
    match Dqueue.Records.read wal id with
      | `Body b -> Wal.decode b
      | `Gone -> None

  let post_put path size base =
    let r =
      {
        Wal.state = Prepared;
        attempts = 0;
        ops = [Op.Put { path; size; base }];
        priors = [];
        local_from = [];
        fids = fids_of [Op.Put { path; size; base }];
        last_error = None;
      }
    in
    ignore (Dqueue.post ~mint uploads r)

  let () = post_put_hook := post_put

  let is_stale id =
    match Entry_key.parse id with
      | Some k ->
          Int64.to_float (Entry_key.ms k) /. 1000.
          < Unix.gettimeofday () -. rekey_age
      | None -> true

  (* EXECUTED records the ops that will be published, with the state, in one
     durable write; a stale key is replaced first so peers see a fresh one. *)
  let mark_executed id ops =
    let id =
      if is_stale id then (
        let id' = mint () in
        Dqueue.Records.rekey wal id id';
        id')
      else id
    in
    Dqueue.Records.update wal id (fun b ->
        match Wal.decode b with
          | Some r ->
              Wal.encode
                { r with state = Executed; ops; fids = Wal.carry_fids r ops }
          | None -> b);
    id

  (* The one publishing operation: note, put the entry, announce, cursor. *)
  let publish_entry id ops =
    let k = Option.get (Entry_key.parse id) in
    let known = match read_record id with Some r -> r.fids | None -> [] in
    Applied.note ~fids:(note_fids ~known ops) applied k ops;
    Journal.write_entry journal k ops;
    changed (List.concat_map Op.paths ops);
    Journal.note journal k

  let discharge id ops =
    if ops <> [] then publish_entry id ops;
    Dqueue.Records.complete wal id

  (* An EXECUTED record's store half is done: only its entry may be owed. *)
  let discharge_executed id (r : Wal.record) =
    if Journal.entry_exists journal (Option.get (Entry_key.parse id)) then
      Dqueue.Records.complete wal id
    else (
      let id = mark_executed id r.ops in
      discharge id r.ops)

  (* A folder we removed is read through while our removal is unpublished
     (A2 rescues what landed in it); once the store has it in the trash, the
     paths beneath it hold nothing (conflict-resolution §3.5 [S(p)]). *)
  let under_trashed_removal path =
    let rec up p =
      if p = "" then false
      else (
        match Mirror.whereabouts mirror p with
          | `Removed id -> (
              match T.anchor id with
                | Some a when Folder.in_trash a -> true
                | _ -> up (Names.parent_of p))
          | _ -> up (Names.parent_of p))
    in
    up path

  (* A move or trash whose answer was lost may leave the old marker behind:
     every retry deletes it again, so no walk keeps meeting it disowned. *)
  let drop_old_marker path id =
    Option.iter
      (fun pid -> T.remove_marker_if ~parent:pid ~name:(Names.leaf_of path) id)
      (Mirror.lookup_id_removed mirror (Names.parent_of path))

  let store_record parent_path leaf =
    match Mirror.lookup_id_removed mirror parent_path with
      | None -> `Unresolved
      | Some _ when under_trashed_removal parent_path -> `Absent
      | Some pid -> (
          match R.get_slot pid leaf with
            | Some b -> (
                match Folder.classify_marker b with
                  | `Marker _ | `Unclassifiable -> `Folder
                  | `Not_marker -> `Record (Manifest.decode b))
            | None -> `Absent)

  (* A folder marker in the slot is a peer's record in place: a file never
     overwrites it. *)
  let slot_moved_on path ~expected =
    match store_record (Names.parent_of path) (Names.leaf_of path) with
      | `Folder -> true
      | `Record (Some m) -> not (expected (Some m))
      | `Record None | `Absent | `Unresolved -> false

  let store_manifest path =
    match store_record (Names.parent_of path) (Names.leaf_of path) with
      | `Record m -> m
      | _ -> None

  (* 02 §4.3: an id held locally costs no round trip; a folder with none claims
     itself and its ancestors, root down.

     [create] is for a bulk import, which makes the folders it names; elsewhere
     a folder missing once the claim answers moved or went away meanwhile. *)
  let rec ensure_folder_id ?(create = false) path =
    match Mirror.folder_id mirror path with
      | Some id -> id
      | None ->
          let pid = ensure_folder_id ~create (Names.parent_of path) in
          let cand = Identity.mint folder_minter in
          let id =
            match T.claim ~parent:pid ~name:(Names.leaf_of path) cand with
              | `Won -> cand
              | `Taken j -> j
          in
          with_meta (fun () ->
              match (Mirror.kind mirror path, Mirror.folder_id mirror path) with
                | _, Some held -> held
                | `Dir, None ->
                    ignore (Mirror.record_folder mirror path id);
                    id
                | `Absent, None when create ->
                    ignore (Mirror.record_folder mirror path id);
                    id
                | _ ->
                    Fail.raise_ Fail.Local "%s moved while its id was claimed"
                      path)

  let claims =
    Dqueue.Records.open_
      (List.fold_left Filename.concat C.data_dir
         ["claims-pending"; Domain_name.to_string d])

  type claim_record = {
    cid : Folder_id.t;
    cparent : Folder_id.t;
    cname : string;
    landed : float;
    cattempts : int;
  }

  let claim_kind =
    {
      Dqueue.decode =
        (fun b ->
          match Yojson.Safe.from_string b with
            | `Assoc f -> (
                let s n =
                  match List.assoc_opt n f with
                    | Some (`String x) -> Some x
                    | _ -> None
                in
                match
                  ( Option.bind (s "id") Folder_id.of_string,
                    Option.bind (s "parent") Folder_id.of_string,
                    s "name",
                    List.assoc_opt "landedAt" f )
                with
                  | ( Some cid,
                      Some cparent,
                      Some cname,
                      Some ((`Float _ | `Int _) as lv) ) ->
                      let landed =
                        match lv with `Int i -> float_of_int i | `Float f -> f
                      in
                      Some
                        {
                          cid;
                          cparent;
                          cname;
                          landed;
                          cattempts =
                            (match List.assoc_opt "attempts" f with
                              | Some (`Int n) -> n
                              | _ -> 0);
                        }
                  | _ -> None)
            | _ -> None
            | exception _ -> None);
      encode =
        (fun c ->
          Yojson.Safe.to_string
            (`Assoc
               [
                 ("id", `String (Folder_id.to_string c.cid));
                 ("parent", `String (Folder_id.to_string c.cparent));
                 ("name", `String c.cname);
                 ("landedAt", `Float c.landed);
                 ("attempts", `Int c.cattempts);
               ]));
      key = (fun _ -> None);
      note = (fun c _ -> { c with cattempts = c.cattempts + 1 });
      accepts = (fun _ -> true);
    }

  let claim_queue = Dqueue.create ~name:"claims" ~ordered:true claim_kind claims

  let record_claim id ~parent ~name =
    ignore
      (Dqueue.post claim_queue
         {
           cid = id;
           cparent = parent;
           cname = name;
           landed = Unix.gettimeofday ();
           cattempts = 0;
         })

  (* A late name loss is resolved like P20: an unpublished folder rename to a
     conflicted name, carrying the folder's id. *)
  let rec set_folder_aside id =
    with_meta (fun () ->
        match Mirror.key_of_id mirror id with
          | None -> ()
          | Some path ->
              let dst = aside_name path ~is_dir:true in
              ignore
                (with_intent
                   [
                     Op.Rename
                       {
                         dst;
                         src = path;
                         is_dir = true;
                         size = None;
                         id = Some id;
                       };
                   ]
                   (fun () ->
                     let moved = rename_local ~src:path ~dst ~is_dir:true in
                     repost_moved moved;
                     `Owed));
              changed [path; dst])

  and run_claim _id c ~cancel:_ =
    let due = c.landed +. claim_settle -. Unix.gettimeofday () in
    if due > 0. then Stop.sleep due;
    match T.confirm ~parent:c.cparent ~name:c.cname c.cid with
      | `Final -> ()
      | `Reclaimed -> record_claim c.cid ~parent:c.cparent ~name:c.cname
      | `Lost _ -> set_folder_aside c.cid

  let expected_matches prior (m : Manifest.t option) =
    match (prior, m) with
      | Wal.Unknown, _ -> true
      | Nothing, None -> true
      | Content h, Some m -> m.h1 = h
      | _ -> false

  let op_kind = function
    | Op.Put _ -> `Put
    | Delete _ -> `Delete
    | Mkdir _ -> `Mkdir
    | Rmdir _ -> `Rmdir
    | Rename { is_dir = true; _ } -> `Rename_dir
    | Rename _ -> `Rename_file

  let local_place id path =
    match Mirror.key_of_id mirror id with
      | Some p -> Some p
      | None ->
          if Mirror.folder_id mirror path = Some id then Some path else None

  let place_of id =
    match T.anchor id with
      | None -> `None
      | Some a when Folder.in_trash a -> `Trash
      | Some a -> `At a

  let claim_place id path =
    let pid = ensure_folder_id (Names.parent_of path) in
    match T.claim ~parent:pid ~name:(Names.leaf_of path) id with
      | `Won ->
          record_claim id ~parent:pid ~name:(Names.leaf_of path);
          Conflict.Claimed
      | `Taken _ -> Name_taken

  (* conflict-resolution §4.4: facts, then the pure decision, then its
     actions; the ops emitted are the ops as they are here now. *)
  let rec publish_op ?(rounds = 0) id (r : Wal.record) i op =
    let fact, emit =
      match op with
        | Op.Delete p ->
            let s = store_manifest p in
            let fact =
              if Mirror.kind mirror p = `File || Staged.edit staged p <> None
              then Conflict.Here_again
              else if s = None then Store_gone
              else if expected_matches (Wal.prior r i) s then Store_as_expected
              else Store_changed
            in
            (fact, [op])
        | Mkdir { path; id = None } ->
            ( Conflict.No_id,
              [Op.Mkdir { path; id = Some (ensure_folder_id path) }] )
        | Mkdir { path; id = Some id } -> (
            match local_place id path with
              | None -> (Gone_here, [])
              | Some here -> (
                  match place_of id with
                    | `Trash -> (Filed_elsewhere, [])
                    | `At (a : Folder.anchor)
                      when not
                             (Mirror.folder_id mirror (Names.parent_of here)
                              = Some a.parent
                             && a.aname = Names.leaf_of here) ->
                        (Filed_elsewhere, [])
                    | _ ->
                        ( claim_place id here,
                          [Op.Mkdir { path = here; id = Some id }] )))
        | Rmdir { id = None; _ } -> (No_id, [op])
        | Rmdir { path; id = Some id } -> (
            match place_of id with
              | `Trash ->
                  drop_old_marker path id;
                  (Already_trashed, [op])
              | `At _ -> (Published, [op])
              | `None ->
                  let old =
                    Option.bind
                      (Mirror.lookup_id_removed mirror (Names.parent_of path))
                      (fun pid -> T.holder_at pid (Names.leaf_of path))
                  in
                  if old = Some id then (Published, [op])
                  else (Never_published, []))
        | Rename { is_dir = true; src; dst = _; id = Some id; _ } -> (
            match local_place id src with
              | None -> (Gone_here, [])
              | Some here -> (
                  let emit =
                    [
                      Op.Rename
                        {
                          dst = here;
                          src;
                          is_dir = true;
                          size = None;
                          id = Some id;
                        };
                    ]
                  in
                  match place_of id with
                    | `Trash -> (Trashed, [])
                    | `At a
                      when Mirror.folder_id mirror (Names.parent_of here)
                           = Some a.parent
                           && a.aname = Names.leaf_of here ->
                        drop_old_marker src id;
                        (Filed_here_already, emit)
                    | place ->
                        let old =
                          Option.bind
                            (Mirror.lookup_id_removed mirror
                               (Names.parent_of src))
                            (fun pid -> T.holder_at pid (Names.leaf_of src))
                        in
                        if place = `None && old <> Some id then
                          (Never_published, [])
                        else (
                          let pid = ensure_folder_id (Names.parent_of here) in
                          match
                            T.place id ~parent:pid ~name:(Names.leaf_of here)
                          with
                            | `Placed ->
                                (match
                                   Mirror.lookup_id_removed mirror
                                     (Names.parent_of src)
                                 with
                                  | Some opid ->
                                      T.remove_marker_if ~parent:opid
                                        ~name:(Names.leaf_of src) id
                                  | None -> ());
                                (Claimed, emit)
                            | `Taken _ | `Taken_by_file -> (Name_taken, emit))))
        | Rename { is_dir = true; id = None; _ } -> (No_id, [op])
        | Rename ({ is_dir = false; src; dst; _ } as rn) ->
            let dst =
              match List.assoc_opt i r.local_from with
                | Some _ -> dst
                | None -> dst
            in
            (* The mirror holds what we moved at [dst]: finding it there is our
               own copy from an attempt whose answer was lost. *)
            let ours (m : Manifest.t option) =
              match (m, Mirror.manifest mirror dst) with
                | Some m, Some here -> m.h1 = here.h1
                | _ -> false
            in
            if
              slot_moved_on dst ~expected:(fun m ->
                  expected_matches (Wal.prior r i) m || ours m)
            then (Destination_taken, [])
            else (
              let emit = [Op.Rename { rn with dst }] in
              match
                ( store_record (Names.parent_of src) (Names.leaf_of src),
                  Mirror.lookup_id_removed mirror (Names.parent_of dst) )
              with
                | `Record (Some _), Some _ -> (
                    let sp =
                      Option.get
                        (Mirror.lookup_id_removed mirror (Names.parent_of src))
                    in
                    let dp = ensure_folder_id (Names.parent_of dst) in
                    match
                      R.rename_file
                        ~src:(sp, Names.leaf_of src)
                        ~dst:(dp, Names.leaf_of dst)
                    with
                      | () -> (Moved, emit)
                      | exception e ->
                          if store_manifest src <> None then raise e
                          else if store_manifest dst <> None then (Landed, emit)
                          else (source_gone dst, []))
                | _ ->
                    if store_manifest dst <> None && store_manifest src = None
                    then (Landed, emit)
                    else (source_gone dst, []))
        | Put _ -> (Base_current, [op])
    in
    let actions, ending = Conflict.publish (op_kind op) fact in
    if Conflict.publish_clashed fact then
      Log.info "publish %s: %s" (Op.to_string op)
        (String.concat "," (List.map (fun _ -> "action") actions));
    List.iter (enact_publish r i op) actions;
    match ending with
      | Publish -> `Emit emit
      | Nothing_owed -> `Emit []
      | Superseded -> raise Rt.Cancelled
      | Retry ->
          Fail.raise_ Fail.Link "publishing %s must be retried"
            (Op.to_string op)
      | Again ->
          if rounds >= Conflict.max_claim_rounds then
            Fail.raise_ Fail.Exists "every name tried for %s is taken"
              (Op.to_string op)
          else (
            let r' = Option.value ~default:r (read_record id) in
            publish_op ~rounds:(rounds + 1) id r' i (List.nth r'.ops i))

  and source_gone dst =
    Conflict.Source_gone
      (if Staged.edit staged dst <> None then `Staged
       else if Mirror.manifest mirror dst <> None then `Published
       else `Absent)

  and enact_publish (_r : Wal.record) _i op = function
    | Conflict.P_remove_from_store -> (
        match op with
          | Op.Delete p -> (
              match Mirror.lookup_id_removed mirror (Names.parent_of p) with
                | Some pid -> ignore (R.delete_slot pid (Names.leaf_of p))
                | None -> ())
          | _ -> ())
    | P_put_marker -> ()
    | P_retire_to_trash -> (
        match op with
          | Op.Rmdir { path; id = Some id } ->
              let pid =
                Option.value ~default:Folder_id.root
                  (Mirror.lookup_id_removed mirror (Names.parent_of path))
              in
              T.trash id ~old:(pid, Names.leaf_of path) ~path
          | _ -> ())
    | P_move_marker -> ()
    | P_ours_aside -> (
        match op with
          | Op.Mkdir { path; id = Some id } ->
              with_meta (fun () ->
                  match local_place id path with
                    | Some here ->
                        let dst = aside_name here ~is_dir:true in
                        let moved = rename_local ~src:here ~dst ~is_dir:true in
                        repost_moved moved;
                        changed [here; dst]
                    | None -> ())
          | _ -> ())
    | P_ours_aside_as_rename -> (
        match op with
          | Op.Rename { id = Some id; _ } -> set_folder_aside id
          | _ -> ())
    | P_retarget_our_rename -> (
        match op with
          | Op.Rename { is_dir = false; dst; _ } ->
              with_meta (fun () ->
                  let dst' = aside_name dst ~is_dir:false in
                  retarget_rename ~old_dst:dst ~new_dst:dst')
          | _ -> ())
    | P_queue_upload -> (
        match op with
          | Op.Rename { dst; _ } -> (
              match Staged.edit staged dst with
                | Some e -> post_put dst e.size (base_hex e)
                | None -> ())
          | _ -> ())
    | P_republish_here -> (
        match op with
          | Op.Rename { dst; _ } -> (
              match Mirror.manifest mirror dst with
                | Some m ->
                    let pid = ensure_folder_id (Names.parent_of dst) in
                    R.publish ~parent:pid ~leaf:(Names.leaf_of dst) m;
                    post_put dst m.size None
                | None -> ())
          | _ -> ())
    | P_ours_aside_file -> ()

  (* retarget-our-rename: one durable update of every unpublished rename of ours
     onto [old_dst], then the local move, then PREPARED. *)
  and retarget_rename ~old_dst ~new_dst =
    List.iter
      (fun id ->
        match read_record id with
          | Some r when r.state <> Executed ->
              let hit = ref false in
              let ops =
                List.mapi
                  (fun i op ->
                    match op with
                      | Op.Rename ({ is_dir = false; dst; _ } as rn)
                        when dst = old_dst ->
                          hit := true;
                          (i, Op.Rename { rn with dst = new_dst })
                      | op -> (i, op))
                  r.ops
              in
              if !hit then (
                let local_from =
                  List.filter_map
                    (fun (i, op) ->
                      match op with
                        | Op.Rename { dst; _ } when dst = new_dst ->
                            Some (i, old_dst)
                        | _ -> None)
                    ops
                in
                let priors =
                  List.map (fun (i, _) -> (i, Wal.Nothing)) local_from
                in
                Dqueue.Records.replace wal id
                  (Wal.encode
                     {
                       r with
                       state = Intent;
                       ops = List.map snd ops;
                       local_from;
                       priors;
                     });
                repost_moved
                  (with_key old_dst (fun () ->
                       rename_local ~src:old_dst ~dst:new_dst ~is_dir:false));
                Dqueue.Records.update wal id (fun b ->
                    match Wal.decode b with
                      | Some r ->
                          Wal.encode
                            { r with state = Prepared; local_from = [] }
                      | None -> b);
                changed [old_dst; new_dst])
          | _ -> ())
      (Dqueue.Records.list wal)

  let run_metadata id (r : Wal.record) ~cancel:_ =
    wait_gate ();
    let r = match read_record id with Some r -> r | None -> r in
    (* wal-and-journal §4.7: an INTENT record's local half may be partly done;
       it is redone under the metadata lock, which its creator holds until it
       prepares, before anything is published. *)
    let r =
      if r.state <> Intent then r
      else
        with_meta (fun () ->
            match read_record id with
              | Some ({ state = Intent; _ } as r) ->
                  redo r;
                  let r = { r with state = Prepared; local_from = [] } in
                  Dqueue.Records.replace wal id (Wal.encode r);
                  r
              | Some r -> r
              | None -> r)
    in
    try
      if r.state = Executed then discharge_executed id r
      else (
        let emitted =
          List.concat
            (List.mapi
               (fun i op -> match publish_op id r i op with `Emit l -> l)
               r.ops)
        in
        if emitted = [] then Dqueue.Records.complete wal id
        else (
          let id = mark_executed id emitted in
          discharge id emitted))
    with e ->
      note_link_failure e;
      raise e

  (* wal-and-journal §4.2 rule 7: an upload waits for the earlier unpublished
     records it depends on. *)
  let depends_on path id =
    let ancestors =
      let rec up p acc =
        if p = "" then acc else up (Names.parent_of p) (p :: acc)
      in
      up (Names.parent_of path) []
    in
    List.exists
      (fun other ->
        other < id
        && (not (List.mem_assoc other (Dqueue.parked metadata)))
        &&
          match read_record other with
          | Some r when r.state <> Executed ->
              List.exists
                (function
                  | Op.Rename { is_dir = false; src; dst; _ } ->
                      src = path || dst = path
                  | Op.Mkdir { path = p; _ } -> List.mem p ancestors
                  | Op.Rename { is_dir = true; src; dst; _ } ->
                      List.mem dst ancestors || src = path
                  | Op.Rmdir { path = p; _ } -> p = path
                  | _ -> false)
                r.ops
          | _ -> false)
      (Dqueue.loaded metadata)

  let wait_dependencies path id =
    while depends_on path id do
      Stop.sleep 0.2
    done

  (* durable-queue §7.3: a bulk publisher's batch, released once its uploads
     ran; an op whose manifest never landed is dropped. *)
  let publish_landed id (r : Wal.record) =
    let landed =
      List.filter
        (function
          | Op.Put { path; _ } -> (
              wait_dependencies path id;
              match store_manifest path with
                | Some m ->
                    if Mirror.manifest mirror path = None then
                      with_meta (fun () ->
                          with_key path (fun () ->
                              Mirror.write_file mirror path m));
                    true
                | None -> false)
          | _ -> false)
        r.ops
    in
    if landed = [] then Dqueue.Records.complete wal id
    else (
      let id = mark_executed id landed in
      discharge id landed)

  let rec run_upload id (r : Wal.record) ~cancel =
    wait_gate ();
    match r.ops with
      | [Op.Put { path; _ }] -> run_one_upload id r path ~cancel
      | _ -> (
          try publish_landed id r
          with e ->
            note_link_failure e;
            raise e)

  (* 04 §4.6: chunks without the lock, the commit under it only if the edit
     generation is still the one read. *)
  and run_one_upload id (r : Wal.record) path ~cancel =
    wait_dependencies path id;
    let state =
      with_key path (fun () -> (Staged.read staged path, generation path))
    in
    try
      match state with
        | `Unparseable, _ ->
            Fail.corrupt "%s: its staged manifest cannot be decoded" path
        | `Edit { state = Committed _; _ }, _ ->
            let id =
              if r.state <> Executed then mark_executed id r.ops else id
            in
            promote path;
            discharge id r.ops
        | `Absent, _ -> (
            match Mirror.file mirror path with
              | `File m when m.link <> None ->
                  let pid = ensure_folder_id (Names.parent_of path) in
                  R.publish ~parent:pid ~leaf:(Names.leaf_of path) m;
                  let id = mark_executed id r.ops in
                  discharge id r.ops
              | `File _ when store_manifest path <> None ->
                  let id = mark_executed id r.ops in
                  discharge id r.ops
              | _ -> Dqueue.Records.complete wal id)
        | `Edit e, g ->
            let base =
              match e.base with
                | Staged.Base h -> Some h
                | Base_none -> None
                | Base_unknown ->
                    Option.map
                      (fun (m : Manifest.t) -> m.h1)
                      (Mirror.manifest mirror path)
            in
            (* An edit outlives a delete: only a peer's record in place moves
               the edit aside (conflict-resolution §5.1). *)
            if
              slot_moved_on path ~expected:(fun m ->
                  Option.map (fun (m : Manifest.t) -> m.h1) m = base)
            then (
              materialise_inherited path;
              with_meta (fun () ->
                  with_key path (fun () ->
                      match Staged.edit staged path with
                        | Some { content = Slots s; _ }
                          when Array.exists (( = ) Staged.Inherit) s ->
                            Fail.raise_ Fail.Link
                              "%s was written while being set aside" path
                        | Some _ -> (
                            let dst = aside_name path ~is_dir:false in
                            move_edit ~new_file:true ~src:path ~dst ();
                            match Staged.edit staged dst with
                              | Some e -> post_put dst e.size None
                              | None -> ())
                        | None -> ()));
              changed [path];
              raise Rt.Cancelled);
            let source i =
              match e.content with
                | Whole { body = b; _ } ->
                    Remote.Lazy
                      (fun () ->
                        let len =
                          if e.size = 0 then 0
                          else Chunking.length ~size:e.size ~cs:e.chunk_size i
                        in
                        let fd =
                          Fs.openfile (Staged.whole_path staged b) [O_RDONLY]
                        in
                        Fs.with_fd fd (fun fd ->
                            let buf = Bigstring.create len in
                            let n =
                              Fs.pread_full fd buf ~boff:0 ~len
                                ~off:(i * e.chunk_size)
                            in
                            Bigstring.sub buf ~off:0 ~len:n))
                | Slots slots -> (
                    let len =
                      if e.size = 0 then 0
                      else Chunking.length ~size:e.size ~cs:e.chunk_size i
                    in
                    match
                      if i < Array.length slots then slots.(i) else Staged.Zero
                    with
                      | Staged.Inherit -> (
                          match Mirror.manifest mirror path with
                            | Some base
                              when i < base.count
                                   && Chunking.length ~size:base.size
                                        ~cs:base.chunk_size i
                                      = len ->
                                Remote.Stored (Manifest.key base i)
                            | _ ->
                                Remote.Lazy
                                  (fun () ->
                                    read_staged path e ~off:(i * e.chunk_size)
                                      ~len))
                      | Zero ->
                          let b = Bigstring.create len in
                          Bigarray.Array1.fill b '\000';
                          Remote.Bytes b
                      | Staged { body; off } ->
                          Remote.Lazy
                            (fun () -> Staged.read_body staged body ~off ~len))
            in
            let m =
              R.upload_chunks ~cancel ~name:(Names.leaf_of path) ~size:e.size
                ~chunk_size:e.chunk_size ~mtime:e.mtime source
            in
            let resend ck =
              let rec find i =
                if i >= m.count then None
                else if Chunk_key.equal (Manifest.key m i) ck then
                  Some
                    (read_staged path e ~off:(i * e.chunk_size)
                       ~len:(Chunking.length ~size:e.size ~cs:e.chunk_size i))
                else find (i + 1)
              in
              find 0
            in
            let pid = ensure_folder_id (Names.parent_of path) in
            with_key path (fun () ->
                if generation path <> g || Atomic.get cancel then
                  raise Rt.Cancelled;
                R.publish ~resend ~parent:pid ~leaf:(Names.leaf_of path) m;
                let m = Manifest.rename m (Names.leaf_of path) in
                note_touched [path];
                Mirror.write_file ~own:true mirror path m;
                Staged.write staged path
                  { e with state = Committed m; base = Base m.h1 });
            let ops = [Op.Put { path; size = m.size; base }] in
            let id = mark_executed id ops in
            promote path;
            discharge id ops
    with e ->
      note_link_failure e;
      raise e
end
