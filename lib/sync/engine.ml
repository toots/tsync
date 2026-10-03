open Tsync_core
open Tsync_remote
open Tsync_checkout

type bridge = Outbound.bridge = Incremental | Hold of string

module type S = Engine_intf.S

let pause_flag ~data_dir d =
  List.fold_left Filename.concat data_dir ["paused"; Domain_name.to_string d]

module Make (C : Engine_ctx.S) = struct
  include Rsync.Make (C)

  (* Unpublished work of ours, read once per entry under the metadata lock. *)
  type owed = { ops : (string * Wal.record) list }

  let owed () =
    {
      ops =
        List.filter_map
          (fun id ->
            match read_record id with
              | Some r when r.state <> Executed -> Some (id, r)
              | _ -> None)
          (Dqueue.Records.list wal);
    }

  let owed_ops o = List.concat_map (fun (_, (r : Wal.record)) -> r.ops) o.ops

  let renamed_onto o l =
    List.exists
      (function Op.Rename { is_dir = false; dst; _ } -> dst = l | _ -> false)
      (owed_ops o)

  let owed_carries o id =
    List.exists
      (function
        | Op.Mkdir { id = Some i; _ }
        | Op.Rename { is_dir = true; id = Some i; _ } ->
            Folder_id.equal i id
        | _ -> false)
      (owed_ops o)

  let owed_rmdir o id =
    List.exists
      (function
        | Op.Rmdir { id = Some i; _ } -> Folder_id.equal i id | _ -> false)
      (owed_ops o)

  let occupant o ~op_id l =
    match Mirror.kind mirror l with
      | `Dir -> (
          match Mirror.folder_id mirror l with
            | None -> Conflict.Folder_no_id
            | Some id
              when match op_id with
                     | Some i -> Folder_id.equal i id
                     | None -> false ->
                Folder_same
            | Some id ->
                if owed_carries o id then Folder_ours else Folder_published)
      | _ ->
          if renamed_onto o l then Renamed_file
          else if Staged.edit staged l <> None then Staged_file
          else if Mirror.kind mirror l = `File then File
          else Nothing

  (* conflict-resolution §3.5: under an unpublished rmdir of ours, with the
     removed folder and the path below it. *)
  let removal o l =
    let rec up p =
      if p = "" then None
      else (
        match Mirror.whereabouts mirror p with
          | `Removed id when owed_rmdir o id -> Some (p, id)
          | _ -> up (Names.parent_of p))
    in
    up (Names.parent_of l)

  (* Folder translation: a folder this client moved, and the store still files
     under the peer's name, is where the peer's path lands here. [placed] says
     whether the store files the folder there. *)
  let translate ~placed p =
    let segs = if p = "" then [] else String.split_on_char '/' p in
    List.fold_left
      (fun cur seg ->
        let cand = Names.join cur seg in
        match Mirror.whereabouts mirror cand with
          | `Moved (id, at) -> (
              match Mirror.folder_id mirror cur with
                | Some pid when placed id ~parent:pid ~name:seg -> at
                | _ -> cand)
          | _ -> cand)
      "" segs

  let follow_owed_renames o p =
    let renames =
      List.filter_map
        (function
          | Op.Rename { is_dir = false; src; dst; _ } -> Some (src, dst)
          | _ -> None)
        (owed_ops o)
    in
    let rec go p n =
      if n = 0 then p
      else (
        match List.assoc_opt p renames with Some d -> go d (n - 1) | None -> p)
    in
    go p (List.length renames)

  type answers = {
    manifests : (string, Manifest.t option) Hashtbl.t;
    anchors : (string, Folder.anchor option) Hashtbl.t;
    legacy_ids : (string, Folder_id.t) Hashtbl.t;
        (** an id-less mkdir's or folder rename's id, by its target path *)
    placements : (string, bool) Hashtbl.t;
        (** whether the store files a folder at a slot, by {!placement} *)
  }

  let placement id ~parent ~name =
    String.concat "/" [Folder_id.to_string id; Folder_id.to_string parent; name]

  let placed_answer answers id ~parent ~name =
    match Hashtbl.find_opt answers.placements (placement id ~parent ~name) with
      | Some here -> here
      | None -> raise Exit

  let store_at answers p =
    match Hashtbl.find_opt answers.manifests p with
      | Some m -> m
      | None -> raise Exit

  let place_answer answers id =
    match Hashtbl.find_opt answers.anchors (Folder_id.to_string id) with
      | Some None -> Conflict.Place_unknown
      | Some (Some a) when Folder.in_trash a -> In_trash
      | Some (Some a) -> (
          match Mirror.key_of_id mirror a.parent with
            | Some pp -> At (Names.join pp a.aname)
            | None -> Place_unknown)
      | None -> raise Exit

  (* Ancestor adoption never mints: a folder with no id here takes the id the
     store's marker names, and a folder missing here is made from it, unless
     this client moved or removed that id. *)
  let adopt_ancestors paths =
    List.iter
      (fun p ->
        let rec down cur = function
          | [] -> ()
          | seg :: rest -> (
              let next = Names.join cur seg in
              match
                ( Mirror.kind mirror next,
                  Mirror.folder_id mirror next,
                  Mirror.folder_id mirror cur )
              with
                | `Dir, None, Some pid -> (
                    match T.holder_at pid seg with
                      | Some id ->
                          (match Mirror.whereabouts mirror next with
                            | `Moved _ | `Removed _ -> ()
                            | _ ->
                                with_meta (fun () ->
                                    if Mirror.kind mirror next = `Dir then
                                      ignore
                                        (Mirror.record_folder ~on_other:`Keep
                                           mirror next id)));
                          down next rest
                      | None -> ())
                | `Dir, Some _, _ -> down next rest
                | `Absent, None, Some pid when Staged.edit staged next = None
                  -> (
                    match T.holder_at pid seg with
                      | Some id
                        when Mirror.key_of_id mirror id = None
                             &&
                               match Mirror.whereabouts mirror next with
                               | `Moved _ | `Removed _ -> false
                               | _ -> true ->
                          let made =
                            with_meta (fun () ->
                                Mirror.kind mirror next = `Absent
                                &&
                                (ignore (Mirror.record_folder mirror next id);
                                 true))
                          in
                          if made then (
                            changed [next];
                            down next rest)
                      | _ -> ())
                | _ -> ())
        in
        down ""
          (if Names.parent_of p = "" then []
           else String.split_on_char '/' (Names.parent_of p)))
      paths

  let read_ahead ops =
    let a =
      {
        manifests = Hashtbl.create 8;
        anchors = Hashtbl.create 4;
        legacy_ids = Hashtbl.create 1;
        placements = Hashtbl.create 1;
      }
    in
    let placed id ~parent ~name =
      let k = placement id ~parent ~name in
      match Hashtbl.find_opt a.placements k with
        | Some here -> here
        | None ->
            let here = T.placed id ~parent ~name = `Here in
            Hashtbl.replace a.placements k here;
            here
    in
    let translate = translate ~placed in
    let man p =
      if not (Hashtbl.mem a.manifests p) then
        Hashtbl.replace a.manifests p
          (match
             store_record (Names.parent_of (translate p)) (Names.leaf_of p)
           with
            | `Record m -> m
            | _ -> None);
      if not (Hashtbl.mem a.manifests (translate p)) then
        Hashtbl.replace a.manifests (translate p) (Hashtbl.find a.manifests p)
    in
    let holder path =
      Option.bind
        (Mirror.lookup_id_removed mirror (Names.parent_of path))
        (fun pid -> T.holder_at pid (Names.leaf_of path))
    in
    let anchor id =
      if not (Hashtbl.mem a.anchors (Folder_id.to_string id)) then
        Hashtbl.replace a.anchors (Folder_id.to_string id) (T.anchor id)
    in
    List.iter
      (function
        | Op.Put { path; _ } -> man path
        | Delete p -> man p
        | Mkdir { id = Some id; path } ->
            anchor id;
            man path
        | Rmdir { id = Some id; path } ->
            anchor id;
            man path
        | Rename { is_dir = true; id = Some id; src; dst; _ } ->
            anchor id;
            man src;
            man dst
        | Mkdir { id = None; path } ->
            Option.iter
              (fun id ->
                Hashtbl.replace a.legacy_ids path id;
                anchor id)
              (holder path);
            man path
        | Rename { is_dir = true; id = None; src; dst; _ } ->
            (match
               match Mirror.folder_id mirror (translate src) with
                 | Some id -> Some id
                 | None -> holder dst
             with
              | Some id ->
                  Hashtbl.replace a.legacy_ids dst id;
                  anchor id
              | None -> ());
            man src;
            man dst
        | Rename { src; dst; _ } ->
            man src;
            man dst
        | _ -> ())
      ops;
    (* An edit an arrival may put aside takes its inherited bytes here, where a
       cold cache fetches them without the metadata lock. *)
    List.iter
      (fun op ->
        List.iter
          (fun p ->
            let l = translate p in
            materialise_inherited l;
            List.iter
              (fun (under, _) -> materialise_inherited under)
              (Staged.edits_under staged l))
          (Op.paths op))
      ops;
    a

  (* wal-and-journal §4.4: one pass or rebuild at a time, so the deferred
     list below belongs to the one running. *)
  let pass_lock = Rt.Fmutex.create ()
  let after_lock : (unit -> unit) list ref = ref []
  let defer f = after_lock := f :: !after_lock

  let install l (m : Manifest.t option) =
    Dqueue.cancel_key uploads l;
    end_lineage l;
    match m with
      | Some m ->
          Mirror.ensure_dirs mirror (Names.parent_of l);
          Mirror.write_file mirror l m
      | None -> ()

  (* ponytail: the read-ahead materialises an edit at the op's own paths; one
     reached only through an owed rename of ours still fetches its inherited
     bytes under the metadata lock. Follow owed renames in the read-ahead if
     that shows. *)
  let file_aside l =
    let dst = aside_name l ~is_dir:false in
    materialise_inherited l;
    with_key l (fun () -> move_edit ~new_file:true ~src:l ~dst ());
    (match Staged.edit staged dst with
      | Some e -> post_put dst e.size None
      | None -> ());
    changed [l; dst]

  let file_aside_published l =
    let dst = aside_name l ~is_dir:false in
    record_owed
      ~priors:[(0, view_prior dst)]
      [
        Op.Rename
          { dst; src = l; is_dir = false; size = Some (size_of l); id = None };
      ]
      (fun () -> ignore (rename_local ~src:l ~dst ~is_dir:false));
    changed [l; dst]

  let folder_aside l =
    let dst = aside_name l ~is_dir:true in
    let id = Mirror.folder_id mirror l in
    record_owed
      [Op.Rename { dst; src = l; is_dir = true; size = None; id }]
      (fun () -> repost_moved (rename_local ~src:l ~dst ~is_dir:true));
    changed [l; dst]

  let folder_aside_local l =
    let dst = aside_name l ~is_dir:true in
    Mirror.move_folder mirror ~src:l ~dst;
    changed [l; dst]

  (* R(F) of conflict-resolution §3.5: the first conflicted name that is free,
     made here, or already holds a folder an unpublished mkdir of ours made. *)
  let rescue_folder f =
    let ours id =
      List.exists
        (function
          | Op.Mkdir { id = Some i; _ } -> Folder_id.equal i id | _ -> false)
        (owed_ops (owed ()))
    in
    let rec pick n =
      let r =
        Names.join (Names.parent_of f)
          (Conflict.conflict_name ~client:C.client_name ~is_dir:true
             (Names.leaf_of f) n)
      in
      match (kind r, Mirror.folder_id mirror r) with
        | `Absent, _ ->
            let id = Identity.mint folder_minter in
            record_owed
              [Op.Mkdir { path = r; id = Some id }]
              (fun () -> ignore (Mirror.record_folder mirror r id));
            r
        | `Dir, Some id when ours id -> r
        | _ -> pick (n + 1)
    in
    pick 1

  (* rescue-ours-under: our unpublished items below a folder a peer removed
     keep their structure in a conflicted copy of it. *)
  let rescue_ours_under o f =
    let staged_items = Staged.edits_under staged f in
    let renamed =
      List.filter_map
        (function
          | Op.Rename { is_dir = false; dst; _ } when Names.is_under ~dir:f dst
            ->
              Some dst
          | _ -> None)
        (owed_ops o)
    in
    let ours_folders =
      let rec walk rel acc =
        List.fold_left
          (fun acc (c : Mirror.child) ->
            match c.kind with
              | `Dir (Some id) when owed_carries o id ->
                  Names.join rel c.name :: acc
              | `Dir _ -> walk (Names.join rel c.name) acc
              | `File _ -> acc)
          acc (Mirror.list mirror rel)
      in
      walk f []
    in
    if staged_items <> [] || renamed <> [] || ours_folders <> [] then (
      let r = rescue_folder f in
      let rebase p =
        Names.join r
          (String.sub p
             (String.length f + 1)
             (String.length p - String.length f - 1))
      in
      List.iter
        (fun p ->
          let dst = rebase p in
          Mirror.ensure_dirs mirror (Names.parent_of dst);
          repost_moved (rename_local ~src:p ~dst ~is_dir:true))
        (List.sort compare ours_folders);
      List.iter
        (fun (p, (e : Staged.edit)) ->
          if Staged.edit staged p <> None then (
            let dst = rebase p in
            Mirror.ensure_dirs mirror (Names.parent_of dst);
            materialise_inherited p;
            with_key p (fun () -> move_edit ~src:p ~dst ());
            post_put dst e.size None))
        staged_items;
      List.iter
        (fun p -> retarget_rename ~old_dst:p ~new_dst:(rebase p))
        renamed;
      changed [f; r])

  (* rescue-theirs: a peer's item landing under a folder we removed is moved by
     an op of ours into the removed folder's conflicted copy. *)
  let rescue_theirs o answers ~peer_path ~local (f, _) ~kind:k =
    ignore o;
    let r = rescue_folder f in
    let rel =
      String.sub local
        (String.length f + 1)
        (String.length local - String.length f - 1)
    in
    let dst = Names.join r rel in
    Mirror.ensure_dirs mirror (Names.parent_of dst);
    (match k with
      | `File ->
          record_owed
            [
              Op.Rename
                { dst; src = peer_path; is_dir = false; size = None; id = None };
            ]
            (fun () ->
              install dst (try store_at answers peer_path with Exit -> None))
      | `Folder id ->
          record_owed
            [
              Op.Rename
                {
                  dst;
                  src = peer_path;
                  is_dir = true;
                  size = None;
                  id = Some id;
                };
            ]
            (fun () ->
              match Mirror.key_of_id mirror id with
                | Some here -> Mirror.move_folder mirror ~src:here ~dst
                | None -> ignore (Mirror.record_folder mirror dst id)));
    changed [dst]

  (* revive-ours (A2a): their concurrent edit goes aside, and our view is put
     back at the name, both published by records of ours. *)
  let revive_ours answers l =
    match
      (Mirror.manifest mirror l, try store_at answers l with Exit -> None)
    with
      | Some v, Some theirs ->
          let aside = aside_name l ~is_dir:false in
          install aside (Some theirs);
          defer (fun () ->
              let pid = ensure_folder_id (Names.parent_of l) in
              R.publish ~parent:pid ~leaf:(Names.leaf_of aside) theirs;
              R.publish ~parent:pid ~leaf:(Names.leaf_of l) v;
              post_put aside theirs.size None;
              post_put l v.size (Some theirs.h1));
          changed [l; aside]
      | _ -> ()

  let retire_stale_source ~source ~target =
    match Mirror.folder_id mirror source with
      | Some id ->
          Mirror.forget_subtree mirror source;
          ignore (Mirror.record_folder mirror target id);
          let dst = aside_name source ~is_dir:true in
          Mirror.move_folder mirror ~src:source ~dst;
          changed [source; dst]
      | None -> ()

  (* [fid] receives the file id of the local file the op acted on, at the path
     the op acts on here (pitfall A-6.25): a put's and a rename's afterwards,
     a delete's only when it removed the file. *)
  let apply_op o answers ~fid op =
    let translate = translate ~placed:(placed_answer answers) in
    let decision_and_enact facts enact =
      let decision = Conflict.arrival facts in
      if Conflict.clashed decision then
        Log.info "arrival %s: %s" (Op.to_string op) (Conflict.describe decision);
      match decision with
        | Conflict.Skip _ -> ()
        | Apply acts -> List.iter enact acts
    in
    match op with
      | Op.Put { path; _ } ->
          let l = follow_owed_renames o (translate path) in
          Fun.protect ~finally:(fun () -> fid (Mirror.file_id mirror l))
          @@ fun () ->
          let s = store_at answers path in
          let occ = occupant o ~op_id:None l in
          let a2a =
            match (op, Mirror.manifest mirror l) with
              | Op.Put { base = Some b; _ }, Some v when Mirror.is_own mirror l
                -> (
                  b <> v.h1
                  && match s with Some sm -> sm.h1 <> v.h1 | None -> false)
              | _ -> false
          in
          decision_and_enact
            (Put_facts
               {
                 store_present = s <> None;
                 removal = removal o l <> None;
                 occupant = occ;
                 base_differs_from_own_view = a2a;
               })
            (function
              | Conflict.Write_theirs -> install l s
              | File_aside -> file_aside l
              | Retarget_our_rename ->
                  retarget_rename ~old_dst:l
                    ~new_dst:(aside_name l ~is_dir:false)
              | Folder_aside -> folder_aside l
              | Folder_aside_local -> folder_aside_local l
              | Rescue_theirs ->
                  rescue_theirs o answers ~peer_path:path ~local:l
                    (Option.get (removal o l))
                    ~kind:`File
              | Revive_ours -> revive_ours answers l
              | _ -> ())
      | Delete p ->
          let l = translate p in
          let before = Mirror.file_id mirror l in
          Fun.protect ~finally:(fun () ->
              if Mirror.file_id mirror l = None then fid before)
          @@ fun () ->
          let s = store_at answers p in
          decision_and_enact
            (Delete_facts
               {
                 store_present = s <> None;
                 removal = removal o l <> None;
                 occupant = occupant o ~op_id:None l;
               })
            (function
              | Conflict.Write_theirs -> install l s
              | Remove_file -> remove_local_file l
              | Folder_aside -> folder_aside l
              | Folder_aside_local -> folder_aside_local l
              | File_aside -> file_aside l
              | Retarget_our_rename ->
                  retarget_rename ~old_dst:l
                    ~new_dst:(aside_name l ~is_dir:false)
              | _ -> ())
      | Mkdir { path; id } -> (
          let id =
            match id with
              | Some id -> Some id
              | None -> Hashtbl.find_opt answers.legacy_ids path
          in
          match id with
            | None ->
                if Mirror.kind mirror (translate path) = `Absent then
                  Mirror.mkdir_without_id mirror (translate path)
            | Some id ->
                let held = Mirror.key_of_id mirror id <> None in
                let place = place_answer answers id in
                let t = match place with At l -> l | _ -> translate path in
                decision_and_enact
                  (Mkdir_facts
                     {
                       held;
                       place;
                       removal = removal o t <> None;
                       occupant = occupant o ~op_id:(Some id) t;
                     })
                  (function
                    | Conflict.Make_folder ->
                        Mirror.ensure_dirs mirror (Names.parent_of t);
                        ignore (Mirror.record_folder mirror t id)
                    | File_aside_published -> file_aside_published t
                    | File_aside -> file_aside t
                    | Retarget_our_rename ->
                        retarget_rename ~old_dst:t
                          ~new_dst:(aside_name t ~is_dir:false)
                    | Folder_aside -> folder_aside t
                    | Rescue_theirs ->
                        rescue_theirs o answers ~peer_path:path ~local:t
                          (Option.get (removal o t))
                          ~kind:(`Folder id)
                    | _ -> ()))
      | Rmdir { path; id } ->
          let restored =
            match id with
              | Some id -> (
                  match
                    Hashtbl.find_opt answers.anchors (Folder_id.to_string id)
                  with
                    | Some (Some a) -> not (Folder.in_trash a)
                    | _ -> false)
              | None -> false
          in
          let tp = translate path in
          let target, f =
            match id with
              | Some id when Mirror.key_of_id mirror id <> None ->
                  (`By_id, Mirror.key_of_id mirror id)
              | _ -> (
                  match (Mirror.kind mirror tp, Mirror.folder_id mirror tp) with
                    | `Dir, None -> (`At_path, Some tp)
                    | `Dir, Some _ -> (`Held_by_another, None)
                    | _ -> (`Gone, None))
          in
          decision_and_enact
            (Rmdir_facts { restored; target })
            (function
              | Conflict.Rescue_ours_under ->
                  Option.iter (rescue_ours_under o) f
              | Remove_folder ->
                  Option.iter
                    (fun f ->
                      List.iter
                        (fun (p, _) -> Dqueue.cancel_key uploads p)
                        (Staged.edits_under staged f);
                      Mirror.remove_folder mirror f;
                      changed [f])
                    f
              | Fill_vacated ->
                  Option.iter
                    (fun f ->
                      install f (try store_at answers path with Exit -> None))
                    f
              | _ -> ())
      | Rename { is_dir = true; src; dst; id; _ } -> (
          let id =
            match id with
              | Some id -> Some id
              | None -> Hashtbl.find_opt answers.legacy_ids dst
          in
          match id with
            | None -> ()
            | Some id ->
                let s' = translate src in
                let source =
                  if
                    Mirror.kind mirror s' = `Dir
                    &&
                      match Mirror.folder_id mirror s' with
                      | Some i -> Folder_id.equal i id
                      | None -> true
                  then `At_path
                  else if Mirror.key_of_id mirror id <> None then `By_id
                  else `Gone
                in
                let place = place_answer answers id in
                let t = match place with At l -> l | _ -> translate dst in
                let src_local =
                  match source with
                    | `At_path -> Some s'
                    | `By_id -> Mirror.key_of_id mirror id
                    | `Gone -> None
                in
                decision_and_enact
                  (Rename_dir_facts
                     {
                       ours_owed =
                         owed_carries o id
                         || List.exists
                              (function
                                | Op.Rmdir { id = Some i; _ } ->
                                    Folder_id.equal i id
                                | _ -> false)
                              (owed_ops o);
                       place;
                       source;
                       already_there = src_local = Some t;
                       removal = removal o t <> None;
                       occupant = occupant o ~op_id:(Some id) t;
                     })
                  (function
                    | Conflict.Move_folder ->
                        Option.iter
                          (fun s ->
                            Mirror.ensure_dirs mirror (Names.parent_of t);
                            repost_moved
                              (rename_local ~src:s ~dst:t ~is_dir:true);
                            changed [s; t])
                          src_local
                    | Fill_vacated ->
                        Option.iter
                          (fun s ->
                            install s
                              (try store_at answers src with Exit -> None))
                          src_local
                    | Retire_stale_source ->
                        Option.iter
                          (fun s -> retire_stale_source ~source:s ~target:t)
                          src_local
                    | Folder_aside -> folder_aside t
                    | Folder_aside_local -> folder_aside_local t
                    | File_aside_published -> file_aside_published t
                    | File_aside -> file_aside t
                    | Retarget_our_rename ->
                        retarget_rename ~old_dst:t
                          ~new_dst:(aside_name t ~is_dir:false)
                    | Rescue_theirs ->
                        rescue_theirs o answers ~peer_path:dst ~local:t
                          (Option.get (removal o t))
                          ~kind:(`Folder id)
                    | _ -> ()))
      | Rename { src; dst; _ } ->
          let s' = translate src and t = translate dst in
          Fun.protect ~finally:(fun () -> fid (Mirror.file_id mirror t))
          @@ fun () ->
          let sd = store_at answers dst in
          let ss = try store_at answers src with Exit -> None in
          let source_here =
            match occupant o ~op_id:None s' with
              | File | Staged_file -> true
              | _ -> false
          in
          decision_and_enact
            (Rename_file_facts
               {
                 dst_present = sd <> None;
                 removal = removal o t <> None;
                 occupant = occupant o ~op_id:None t;
               })
            (function
              | Conflict.Arrive ->
                  if source_here then (
                    repost_moved
                      (with_keys [s'; t] (fun () ->
                           rename_local ~src:s' ~dst:t ~is_dir:false));
                    if
                      Staged.edit staged t = None
                      && not
                           (Option.equal Manifest.equal_content
                              (Mirror.manifest mirror t) sd)
                    then install t sd)
                  else install t sd;
                  changed [s'; t]
              | File_aside -> file_aside t
              | Retarget_our_rename ->
                  retarget_rename ~old_dst:t
                    ~new_dst:(aside_name t ~is_dir:false)
              | Folder_aside -> folder_aside t
              | Folder_aside_local -> folder_aside_local t
              | Rescue_theirs ->
                  rescue_theirs o answers ~peer_path:dst ~local:t
                    (Option.get (removal o t))
                    ~kind:`File
              | Source_rule -> (
                  match occupant o ~op_id:None s' with
                    | Nothing | File -> (
                        match ss with
                          | Some _ -> install s' ss
                          | None ->
                              if Mirror.kind mirror s' = `File then
                                remove_local_file s')
                    | _ -> ())
              | _ -> ())

  (* conflict-resolution §4.1: store facts are read ahead, local ones under the
     lock; one entry's ops are enacted within one hold of the lock. Answers the
     file ids its ops named (03 §2.7): a delete's read before it runs. *)
  let apply_entry ops =
    adopt_ancestors (List.concat_map Op.paths ops);
    let answers = read_ahead ops in
    let fids = ref [] in
    after_lock := [];
    (try
       with_meta (fun () ->
           let o = owed () in
           List.iteri
             (fun i op ->
               apply_op o answers op
                 ~fid:(Option.iter (fun id -> fids := (i, id) :: !fids)))
             ops)
     with Exit ->
       Fail.raise_ Fail.Local "local state changed during the read-ahead");
    let later = List.rev !after_lock in
    after_lock := [];
    List.iter (fun f -> f ()) later;
    changed (List.concat_map Op.paths ops);
    !fids

  let mark () = Mark.read ~data_dir:C.data_dir d

  let unapplied () =
    Mutex.protect stepped_m (fun () ->
        Hashtbl.fold (fun k r acc -> (k, r) :: acc) stepped_aside [])

  let hold reason =
    if Atomic.get bridge_state = Incremental then
      Log.warn "cannot bridge the journal: %s; holding until a rebuild" reason;
    Atomic.set bridge_state (Hold reason);
    (* wal-and-journal §4.8: the catch-up gate does not apply in hold, so a
       queue waiting at it must hear of it. *)
    Rt.Signal.broadcast gate_signal

  (* wal-and-journal §4.8: evidence that entries could be missed above the
     mark, never the mark's age. *)
  let cannot_bridge mark listing cursor =
    match mark with
      | None -> Some "no last-sync mark"
      | Some m ->
          let now_ms =
            Int64.of_float ((Unix.gettimeofday () -. Outbound.horizon) *. 1000.)
          in
          let hidden =
            List.find_opt
              (fun (k, _) ->
                Entry_key.compare k m > 0
                && Entry_key.ms k < now_ms
                && not (Applied.contains applied k))
              listing
          in
          let others =
            List.filter
              (fun (k, _) ->
                match cursor with
                  | Some c -> not (Entry_key.equal k c)
                  | None -> true)
              listing
          in
          let mark_old = Entry_key.ms m < now_ms in
          if hidden <> None then
            Some "an unhandled entry is older than the horizon"
          else if not mark_old then None
          else (
            match others with
              | (k, _) :: _ when Entry_key.compare k m > 0 ->
                  Some "the journal was pruned past the mark"
              | [] -> (
                  match cursor with
                    | Some c
                      when List.exists
                             (fun (k, _) -> Entry_key.equal k c)
                             listing
                           && Entry_key.compare c m > 0 ->
                        Some "the journal was pruned past the mark"
                    | _ -> None)
              | _ -> None)

  let apply_pass () =
    match Atomic.get bridge_state with
      | Hold _ -> 0
      | Incremental -> (
          let t0 = Unix.gettimeofday () and epoch = gate_epoch () in
          let listing = Journal.list_entries journal in
          let cursor =
            match Journal.cursor_read journal with
              | `Key k -> Some k
              | _ -> None
          in
          match cannot_bridge (mark ()) listing cursor with
            | Some reason ->
                hold reason;
                0
            | None ->
                let horizon_ms =
                  Int64.of_float ((t0 -. Outbound.horizon) *. 1000.)
                in
                let due =
                  List.filter
                    (fun (k, _) ->
                      Entry_key.ms k >= horizon_ms
                      && not (Applied.contains applied k))
                    listing
                in
                let applied_n = ref 0 and oldest_open = ref None in
                List.iter
                  (fun (k, key) ->
                    Stop.check ();
                    match Journal.read_entry journal key with
                      | None ->
                          hold "a due entry vanished";
                          raise Exit
                      | exception Fail.E ({ kind = Corrupt | Invalid; _ } as f)
                        ->
                          Mutex.protect stepped_m (fun () ->
                              Hashtbl.replace stepped_aside
                                (Entry_key.to_string k) f.reason);
                          if !oldest_open = None then oldest_open := Some k
                      | Some ops -> (
                          match apply_entry ops with
                            | fids ->
                                (* Only what apply_op reported: a peer's paths
                                   are not this client's (pitfall A-6.25). *)
                                Applied.note ~fids applied k ops;
                                Mutex.protect stepped_m (fun () ->
                                    Hashtbl.remove stepped_aside
                                      (Entry_key.to_string k));
                                incr applied_n
                            | exception ((Stop.Stopping | Rt.Cancelled) as e) ->
                                raise e
                            | exception (Fail.E f as e)
                              when Fail.retryable f.kind ->
                                raise e
                            | exception e ->
                                let f = Fail.classify e in
                                Mutex.protect stepped_m (fun () ->
                                    Hashtbl.replace stepped_aside
                                      (Entry_key.to_string k) f.reason);
                                Log.warn "stepping aside journal entry %s: %s"
                                  (Entry_key.to_string k) (Fail.to_string f);
                                if !oldest_open = None then
                                  oldest_open := Some k))
                  due;
                let target =
                  match !oldest_open with
                    | None ->
                        Entry_key.of_time ~client:C.client_uuid
                          (t0 -. Outbound.list_slack)
                    | Some k ->
                        Entry_key.make
                          ~ms:(Int64.pred (Entry_key.ms k))
                          ~client:C.client_uuid
                in
                (match mark () with
                  | Some m when Entry_key.compare m target >= 0 -> ()
                  | _ -> Mark.write ~data_dir:C.data_dir d target);
                open_gate ~since:epoch ();
                !applied_n)

  let apply_pass () =
    Rt.Fmutex.with_lock pass_lock (fun () -> try apply_pass () with Exit -> 0)

  let metadata_owed () =
    List.exists (fun (_, (r : Wal.record)) -> Wal.is_metadata r) (owed ()).ops

  (* wal-and-journal §4.8 and 05 §4.7: rewrite the mirror in place from a
     complete walk, report the differences in the applied log, then move the
     mark; nothing is swept after an incomplete walk. *)
  let rec rebuild ?narrate ?parallelism () =
    Rt.Fmutex.with_lock pass_lock (fun () ->
        rebuild_locked ?narrate ?parallelism ())

  and rebuild_locked ?(narrate = Narrate.none) ?(parallelism = 32) () =
    if metadata_owed () then
      Fail.raise_ Fail.Unprepared
        "metadata operations are not published yet, and a rebuild would undo \
         them";
    let t0 = Unix.gettimeofday () and epoch = gate_epoch () in
    Atomic.set touched (Some (Hashtbl.create 64));
    Fun.protect ~finally:(fun () -> Atomic.set touched None) @@ fun () ->
    let listing = Journal.list_entries journal in
    let failures = ref 0 and diffs = ref [] and manifests = ref 0 in
    let deleted_fids = Hashtbl.create 64 in
    let folders = ref 0 in
    let walked () =
      Narrate.progress narrate "walking the store: %s, %s"
        (Narrate.count !folders "folder")
        (Narrate.count !manifests "file")
    in
    let seen_files = Hashtbl.create 4096 and seen_dirs = Hashtbl.create 1024 in
    let on_unusable =
      Tree.Skip
        (fun u ->
          (match u with Tree.Disowned _ -> () | _ -> incr failures);
          Log.warn "resync: %s" (Tree.describe_unusable u))
    in
    ignore
      (T.fold_tree ~on_unusable ~width:parallelism ~write_index:true
         Folder_id.root ~root_path:""
         (fun () dir (e : Tree.entry) ->
           match e.body with
             | Dir m ->
                 let p = Names.join dir m.name in
                 incr folders;
                 walked ();
                 Hashtbl.replace seen_dirs p ();
                 with_meta (fun () ->
                     match
                       Mirror.record_folder ~durable:false mirror p m.id
                     with
                       | `Same -> ()
                       | `Changed ->
                           diffs :=
                             Op.Mkdir { path = p; id = Some m.id } :: !diffs
                       | `Replaced old ->
                           diffs :=
                             Op.Mkdir { path = p; id = Some m.id }
                             :: Op.Rmdir { path = p; id = Some old }
                             :: !diffs
                       | `Held _ -> ())
             | File m ->
                 incr manifests;
                 walked ();
                 let p = Names.join dir m.name in
                 Hashtbl.replace seen_files p ();
                 with_meta (fun () ->
                     let same =
                       match Mirror.manifest mirror p with
                         | Some old ->
                             Manifest.equal_content old m && old.mtime = m.mtime
                         | None -> false
                     in
                     if not same then (
                       with_key p (fun () ->
                           Mirror.write_file ~durable:false mirror p m);
                       diffs :=
                         Op.Put { path = p; size = m.size; base = None }
                         :: !diffs)))
         ());
    if !failures = 0 then (
      with_meta (fun () ->
          let rec sweep rel =
            List.iter
              (fun (c : Mirror.child) ->
                let p = Names.join rel c.name in
                match c.kind with
                  | `Dir _ when was_touched p && not (Hashtbl.mem seen_dirs p)
                    ->
                      ()
                  | `Dir id ->
                      if Hashtbl.mem seen_dirs p then sweep p
                      else (
                        (match id with
                          | Some id -> (
                              Mirror.remove_folder mirror p;
                              match Mirror.key_of_id mirror id with
                                | Some now ->
                                    diffs :=
                                      Op.Rename
                                        {
                                          dst = now;
                                          src = p;
                                          is_dir = true;
                                          size = None;
                                          id = Some id;
                                        }
                                      :: !diffs
                                | None ->
                                    diffs :=
                                      Op.Rmdir { path = p; id = Some id }
                                      :: !diffs)
                          | None -> Mirror.remove_folder mirror p);
                        ())
                  | `File _ ->
                      if not (Hashtbl.mem seen_files p) then
                        with_key p (fun () ->
                            (* An owed edit outlives a peer's delete: its
                               upload publishes the file again. *)
                            if
                              (not (was_touched p))
                              && Staged.edit staged p = None
                            then (
                              Option.iter
                                (Hashtbl.replace deleted_fids p)
                                (Mirror.file_id mirror p);
                              remove_local_file p;
                              diffs := Op.Delete p :: !diffs)))
              (Mirror.list mirror rel)
          in
          Narrate.progress narrate "removing what the store no longer has";
          sweep "";
          Mirror.rebuild_index mirror);
      let ops = List.rev !diffs in
      (* One pass over the diffs, 64 to an applied record. *)
      let rec chunks batch n = function
        | op :: rest when n < 64 -> chunks (op :: batch) (n + 1) rest
        | rest ->
            if batch <> [] then (
              let batch = List.rev batch in
              let known =
                List.concat
                  (List.mapi
                     (fun i op ->
                       match op with
                         | Op.Delete p -> (
                             match Hashtbl.find_opt deleted_fids p with
                               | Some id -> [(i, id)]
                               | None -> [])
                         | _ -> [])
                     batch)
              in
              Applied.note ~fids:(note_fids ~known batch) applied
                (Option.get (Entry_key.parse (mint ())))
                batch);
            if rest <> [] then chunks [] 0 rest
      in
      (* The walk wrote the mirror without fsyncs: one flush makes it durable
         before the applied log and the mark claim it. *)
      Fs.syncfs (Mirror.root mirror);
      chunks [] 0 ops;
      List.iter
        (fun (k, _) ->
          if not (Applied.contains applied k) then Applied.note applied k [])
        listing;
      Mark.write ~data_dir:C.data_dir d
        (Entry_key.of_time ~client:C.client_uuid (t0 -. Outbound.list_slack));
      Mutex.protect stepped_m (fun () -> Hashtbl.reset stepped_aside);
      Atomic.set bridge_state Incremental;
      open_gate ~since:epoch ();
      changed (List.concat_map Op.paths ops));
    (* A rebuild churns through every manifest of the domain: its garbage is
       given back to the kernel, not left in the allocator's arenas. *)
    Usage.release ();
    Narrate.say narrate "rebuilt from %s and %s in %s"
      (Narrate.count !folders "folder")
      (Narrate.count !manifests "file")
      (Narrate.duration (Unix.gettimeofday () -. t0));
    (!manifests, !failures)

  (* 05 §4.7: a pass, or a rebuild when the client cannot bridge (or when asked). *)
  let resync ?narrate ?(full = false) ?parallelism () =
    let full =
      full
      ||
        match Atomic.get bridge_state with
        | Hold _ -> true
        | Incremental -> false
    in
    if full then (
      Dqueue.settle ~timeout:60. metadata;
      let m, f = rebuild ?narrate ?parallelism () in
      `Full (m, f))
    else (
      Atomic.set bridge_state Incremental;
      let n = apply_pass () in
      match Atomic.get bridge_state with
        | Hold _ ->
            let m, f = rebuild ?narrate ?parallelism () in
            `Full (m, f)
        | Incremental -> `Incremental n)

  let resync_generation_path =
    Filename.concat C.data_dir ("resync-" ^ Domain_name.to_string d)

  let resync_generation () =
    match Fs.read_file_opt resync_generation_path with
      | Some s -> String.trim s
      | None -> ""

  (* 08 §3.6: the entry of the oldest anchor the feed's consumer may present,
     and when it last moved. *)
  let watermark_path =
    Filename.concat C.data_dir ("feed-watermark-" ^ Domain_name.to_string d)

  let dropped_path =
    Filename.concat C.data_dir ("feed-dropped-" ^ Domain_name.to_string d)

  let feed_watermark_max_age = 180. *. 86400.
  let feed_m = Mutex.create ()

  (* [None]: no consumer holds an anchor; an entry of [None] is "before every
     entry". A lost or torn record reads as absent. *)
  let read_watermark () =
    match Fs.read_file_opt watermark_path with
      | None -> None
      | Some s -> (
          match String.split_on_char ' ' (String.trim s) with
            | [entry; ms] -> (
                match (entry, Int64.of_string_opt ms) with
                  | "", Some ms -> Some (None, ms)
                  | e, Some ms ->
                      Option.map (fun k -> (Some k, ms)) (Entry_key.parse e)
                  | _, None -> None)
            | [ms] -> Option.map (fun ms -> (None, ms)) (Int64.of_string_opt ms)
            | _ -> None)

  let write_watermark entry =
    Fs.durable_replace watermark_path
      (Printf.sprintf "%s %.0f"
         (Option.fold ~none:"" ~some:Entry_key.to_string entry)
         (Unix.gettimeofday () *. 1000.))

  let stamp_generation () =
    Mutex.protect feed_m (fun () ->
        Fs.durable_replace resync_generation_path
          (Printf.sprintf "%.0f" (Unix.gettimeofday () *. 1000.));
        if Fs.release watermark_path then Fs.fsync_dir C.data_dir)

  let anchor_of gen entry =
    gen ^ "|" ^ Option.fold ~none:"" ~some:Entry_key.to_string entry

  let cursor () =
    Mutex.protect feed_m (fun () ->
        let head = Applied.head applied in
        if read_watermark () = None then write_watermark head;
        anchor_of (resync_generation ()) head)

  let changes_since anchor ~limit =
    Mutex.protect feed_m (fun () ->
        let gen = resync_generation () in
        match String.index_opt anchor '|' with
          | None -> `Stale
          | Some i -> (
              let entry_s =
                String.sub anchor (i + 1) (String.length anchor - i - 1)
              in
              let entry =
                if entry_s = "" then Some None
                else Option.map Option.some (Entry_key.parse entry_s)
              in
              match entry with
                | None -> `Stale
                | Some _ when String.sub anchor 0 i <> gen -> `Stale
                | Some None when Fs.exists dropped_path -> `Stale
                | Some entry ->
                    write_watermark entry;
                    let head = Applied.head applied in
                    let same =
                      match (entry, head) with
                        | None, None -> true
                        | Some a, Some b -> Entry_key.equal a b
                        | _ -> false
                    in
                    if same then `Page (anchor_of gen head, false, [])
                    else (
                      match Applied.since applied entry limit with
                        | `Stale -> `Stale
                        | `Page (pg : Applied.page) ->
                            let cursor =
                              match List.rev pg.entries with
                                | (k, _) :: _ -> anchor_of gen (Some k)
                                | [] -> anchor
                            in
                            `Page
                              (cursor, pg.more, List.concat_map snd pg.entries))
              ))

  (* wal-and-journal §4.8: held back by the watermark until it lapses. *)
  let prune_applied () =
    let hold =
      Mutex.protect feed_m (fun () ->
          match read_watermark () with
            | None -> `Nothing
            | Some (_, ms)
              when Unix.gettimeofday () -. (Int64.to_float ms /. 1000.)
                   > feed_watermark_max_age ->
                Log.warn
                  "%s: the change feed's consumer has not read it for %.0f \
                   days; its anchor no longer holds the applied log"
                  (Domain_name.to_string d)
                  (feed_watermark_max_age /. 86400.);
                `Nothing
            | Some (None, _) -> `Everything
            | Some (Some k, _) -> `From k)
    in
    Applied.prune ~hold
      ~before_drop:(fun () ->
        if not (Fs.exists dropped_path) then Fs.durable_replace dropped_path "")
      applied ~now:(Unix.gettimeofday ())
      ~keep:(Outbound.horizon +. Outbound.list_slack)

  (* durable-queue §4.2: records other processes submitted, a WAL record
     without an entry key getting one. *)
  let rescan_logs () =
    Dqueue.rescan
      ~rekey:(fun id ->
        if Entry_key.parse id = None then Some (mint ()) else None)
      metadata;
    Dqueue.rescan uploads

  let wake_poller () = Rt.Signal.broadcast poll_signal
  let trim_cache () = ignore (Cache.enforce_cap cache)

  let poll () =
    rescan_logs ();
    Tsync_store.Composite.rescan C.composite;
    wake_poller ()

  (* wal-and-journal §4.3: the sweep is timed from the last listing, never from
     a wait's expiry. *)
  let poller () =
    let last_seen = ref None and last_listing = ref neg_infinity in
    let rec loop () =
      Stop.check ();
      if Atomic.get paused then (
        Stop.sleep 1.;
        loop ())
      else (
        (match Atomic.get bridge_state with
          | Hold _ when (not (metadata_owed ())) && Dqueue.parked metadata = []
            -> (
              try ignore (rebuild ())
              with e ->
                Log.warn "automatic rebuild failed: %s" (Printexc.to_string e))
          | _ -> ());
        let since = Rt.Signal.version poll_signal in
        (try
           Rt.first ~detach:true
             [
               (fun () -> Journal.cursor_wait journal !last_seen);
               (fun () -> Rt.Signal.wait ~since poll_signal);
               (fun () -> Stop.sleep Outbound.sweep);
             ]
         with
          | Stop.Stopping -> raise Stop.Stopping
          | _ -> ());
        (match
           let token = Journal.cursor_token journal in
           let moved = token <> !last_seen in
           let due = Rt.now () -. !last_listing >= Outbound.sweep in
           let asked = Rt.Signal.version poll_signal <> since in
           if moved || due || asked then (
             last_listing := Rt.now ();
             ignore (apply_pass ());
             last_seen := token)
         with
          | () -> ()
          | exception ((Stop.Stopping | Rt.Cancelled) as e) -> raise e
          | exception e ->
              note_link_failure e;
              Log.info "journal pass failed: %s" (Printexc.to_string e);
              Stop.sleep Outbound.retry_floor);
        loop ())
    in
    try loop () with Stop.Stopping -> ()

  let run_pass_safely () =
    try ignore (apply_pass ()) with
      | Stop.Stopping -> ()
      | e ->
          note_link_failure e;
          Log.info "journal pass failed: %s" (Printexc.to_string e)

  (* 04 §4.6: the version's manifest first; then, under the locks, the staged
     edit goes and a put is owed before the store and the mirror change, so the
     upload queue discharges the record by the no-staged-edit rule. *)
  let revert ?version path =
    if not C.versioning then
      Fail.raise_ Fail.Refused "%s does not keep versions"
        (Domain_name.to_string d);
    let parent = require_parent path and leaf = Names.leaf_of path in
    let versions = R.list_versions parent leaf in
    let chosen =
      match version with
        | None -> List.nth_opt versions 0
        | Some ns -> List.find_opt (fun (v, _) -> Int64.equal v ns) versions
    in
    match chosen with
      | None -> Fail.absent "%s: no such version" path
      | Some (_, entry) ->
          let m =
            match Manifest.decode (R.get_version entry) with
              | Some m -> Manifest.rename m leaf
              | None -> Fail.corrupt "%s: the version is not a manifest" path
          in
          with_meta (fun () ->
              with_key path (fun () ->
                  ignore (discard_edit path);
                  bump path;
                  post_put path m.size None;
                  R.revert ~parent ~leaf entry;
                  Mirror.write_file ~own:true mirror path m));
          changed [path]

  (* 05 §4.8, §4.2: the store side first, so the folder is filed where its
     Mkdir says; then the folder and its whole subtree are announced, since
     peers dropped them when it was trashed. *)
  let restore_from_trash path =
    match
      List.find_opt
        (fun (f : T.trashed) -> f.path = Some path && f.state <> `Live)
        (T.trashed ())
    with
      | None -> `Not_in_trash
      | Some m ->
          if kind path <> `Absent then `Exists
          else (
            let parent = require_parent path in
            match T.restore m.id ~parent ~name:(Names.leaf_of path) with
              | `Taken _ | `Taken_by_file -> `Exists
              | `Placed ->
                  let announced = ref 1 in
                  with_meta (fun () ->
                      (* Unpublished work of ours took the name during the
                         round trip: it steps aside. *)
                      (match kind path with
                        | `File -> file_aside path
                        | `Dir -> folder_aside path
                        | `Absent -> ());
                      record_owed
                        [Op.Mkdir { path; id = Some m.id }]
                        (fun () ->
                          ignore (Mirror.record_folder mirror path m.id)));
                  T.fold_tree m.id ~root_path:path
                    (fun () dir (e : Tree.entry) ->
                      incr announced;
                      match e.body with
                        | Dir d ->
                            let p = Names.join dir d.name in
                            with_meta (fun () ->
                                record_owed
                                  [Op.Mkdir { path = p; id = Some d.id }]
                                  (fun () ->
                                    ignore (Mirror.record_folder mirror p d.id)))
                        | File f ->
                            let p = Names.join dir f.name in
                            with_meta (fun () ->
                                with_key p (fun () ->
                                    Mirror.write_file mirror p f));
                            post_put p f.size None)
                    ();
                  changed [path];
                  `Restored !announced)

  let reconcile () =
    List.iter
      (fun id ->
        match Entry_key.parse id with
          | Some k
            when Entry_key.client k <> C.client_uuid && String.length id > 20 ->
              Log.warn "WAL record %s names another client; left alone" id
          | _ -> (
              try
                match read_record id with
                  | None -> ()
                  | Some r when r.ops = [] -> Dqueue.Records.complete wal id
                  | Some r -> (
                      match r.state with
                        | Executed -> discharge_executed id r
                        | Prepared -> ()
                        | Intent when Wal.puts_only r ->
                            Dqueue.Records.update wal id (fun _ ->
                                Wal.encode { r with state = Prepared })
                        | Intent ->
                            let puts = List.filter Op.is_put r.ops
                            and meta =
                              List.filter (fun o -> not (Op.is_put o)) r.ops
                            in
                            List.iter
                              (fun op ->
                                match op with
                                  | Op.Put { path; size; base } ->
                                      post_put path size base
                                  | _ -> ())
                              puts;
                            let r =
                              {
                                r with
                                ops = meta;
                                fids = Wal.carry_fids r meta;
                              }
                            in
                            redo r;
                            Dqueue.Records.update wal id (fun _ ->
                                Wal.encode
                                  { r with state = Prepared; local_from = [] }))
              with e ->
                Log.warn "reconcile of %s failed: %s" id (Printexc.to_string e)))
      (Dqueue.Records.list wal)

  (* Every maximal run of exactly 16 lowercase hex characters: the bodies a
     set-aside manifest may name. *)
  let hex_runs s =
    let n = String.length s in
    let rec go i acc =
      if i >= n then acc
      else if Names.is_hexlower s.[i] then (
        let j = ref i in
        while !j < n && Names.is_hexlower s.[!j] do
          incr j
        done;
        go !j (if !j - i = 16 then String.sub s i 16 :: acc else acc))
      else go (i + 1) acc
    in
    go 0 []

  (* 04 §4.10: before anything is served. *)
  let staged_set_aside = Atomic.make 0

  let recover_local () =
    let root = Mirror.root mirror in
    let rec sweep_temps dir =
      Fs.sweep_temps ~older_than:86400. dir;
      List.iter
        (fun n ->
          let p = Filename.concat dir n in
          if Fs.kind p = `Dir then sweep_temps p)
        (Fs.readdir dir)
    in
    if Fs.is_dir root then sweep_temps root;
    Cache.sweep_at_start cache;
    let named = Hashtbl.create 64 in
    let staged_dir = Filename.concat root "staged" in
    Staged.fold staged
      (fun () -> function
        | `Edit (_, e) ->
            List.iter
              (fun b -> Hashtbl.replace named b ())
              (Staged.bodies_named e)
        | `Bad p ->
            Atomic.incr staged_set_aside;
            let body = Option.value ~default:"" (Fs.read_file_opt p) in
            let base = Filename.basename p in
            if not (Staged.is_set_aside_name base) then (
              Fs.rename p (Staged.set_aside_path p);
              Log.warn "set aside the undecodable staged manifest %s" p);
            let re = hex_runs body in
            List.iter (fun b -> Hashtbl.replace named b ()) re)
      ();
    List.iter
      (fun (p, (e : Staged.edit)) ->
        match e.state with Committed _ -> promote p | Owed -> ())
      (Staged.edits staged);
    List.iter
      (fun sub ->
        List.iter
          (fun b ->
            if (not (Names.is_temp_name b)) && not (Hashtbl.mem named b) then
              ignore
                (Fs.release
                   (Filename.concat (Filename.concat staged_dir sub) b)))
          (Fs.readdir (Filename.concat staged_dir sub)))
      ["chunks"; "whole"];
    (* 04 §4.10 step 8: the index first, so it sees every marker minted here;
       no read path mints a file id. *)
    Mirror.load_file_ids mirror;
    let minted = Mirror.backfill_file_ids mirror in
    List.iter
      (fun (p, _) -> ignore (Mirror.ensure_file_id mirror p))
      (Staged.edits staged);
    if minted > 0 then Log.info "gave file ids to %d files" minted

  let adopt_unrecorded () =
    let named =
      List.filter_map
        (fun (_, (r : Wal.record)) ->
          match r.ops with [Op.Put { path; _ }] -> Some path | _ -> None)
        (owed ()).ops
    in
    List.iter
      (fun (p, (e : Staged.edit)) ->
        if e.state = Owed && not (List.mem p named) then
          post_put p e.size (base_hex e))
      (Staged.edits staged)

  let paused_path = pause_flag ~data_dir:C.data_dir d

  (* An owner that never starts its queues still answers for the durable
     state (pitfall A-10.14). *)
  let () = Atomic.set paused (Fs.exists paused_path)

  let set_paused on =
    if on then Fs.durable_replace paused_path ""
    else if Fs.release paused_path then
      Fs.fsync_dir (Filename.dirname paused_path);
    Atomic.set paused on;
    let f = if on then Dqueue.pause else Dqueue.resume in
    f uploads;
    f metadata;
    (if on then Tsync_store.Composite.pause else Tsync_store.Composite.resume)
      C.composite;
    if not on then wake_poller ()

  let is_paused () = Atomic.get paused

  let start ?(poll_journal = not C.lazy_tree) () =
    Applied.load applied;
    let is_paused = Fs.exists paused_path in
    Atomic.set paused is_paused;
    recover_local ();
    Dqueue.start ~paused:is_paused uploads run_upload;
    Dqueue.start ~paused:is_paused metadata run_metadata;
    reconcile ();
    rescan_logs ();
    adopt_unrecorded ();
    Dqueue.start claim_queue run_claim;
    Tsync_store.Composite.start ~paused:is_paused C.composite;
    if C.lazy_tree then open_gate ()
    else if poll_journal then Rt.spawn ~name:"poller" poller
    else Rt.spawn ~name:"catch-up" run_pass_safely

  (* 07 §3.4: metadata, then uploads, raced against a fraction of the grace,
     then the cursor flush and the copies. *)
  let drain ?(grace = Stop.grace) () =
    let deadline = Rt.now () +. grace in
    (try
       Rt.with_timeout (0.8 *. grace) (fun () ->
           Dqueue.settle ~timeout:grace metadata;
           Dqueue.settle ~timeout:grace uploads)
     with Rt.Timeout ->
       Log.info "queues still busy after the grace; the rest is owed on disk");
    Journal.flush journal;
    let left = deadline -. Rt.now () in
    if left > 0. then Tsync_store.Composite.settle ~timeout:left C.composite;
    Mirror.save_file_ids mirror

  let pending_uploads () = Dqueue.pending uploads

  let uploads_running () =
    List.concat_map
      (fun id ->
        match read_record id with
          | Some r ->
              List.filter_map
                (function
                  | Op.Put { path; size; _ } ->
                      Some
                        {
                          Engine_intf.path;
                          size;
                          bytes = 0;
                          started = Unix.gettimeofday ();
                        }
                  | _ -> None)
                r.ops
          | None -> [])
      (Dqueue.running uploads)

  let activity () : Engine_intf.activity =
    let records =
      List.filter_map
        (fun id -> Option.map (fun r -> (id, r)) (read_record id))
        (Dqueue.Records.list wal)
    in
    let count s =
      List.length
        (List.filter (fun (_, (r : Wal.record)) -> r.state = s) records)
    in
    let owed =
      List.fold_left
        (fun acc (_, (r : Wal.record)) ->
          if r.state = Executed then acc
          else
            List.fold_left
              (fun acc -> function
                | Op.Put { size; _ } -> acc + size | _ -> acc)
              acc r.ops)
        0 records
    in
    let parked = Dqueue.parked uploads @ Dqueue.parked metadata in
    let retrying = Dqueue.retrying uploads @ Dqueue.retrying metadata in
    {
      intent = count Intent;
      prepared = count Prepared;
      executed = count Executed;
      stuck = List.length parked;
      retrying = List.length retrying;
      set_aside =
        Atomic.get staged_set_aside
        + List.length (Dqueue.Records.set_aside_records wal);
      last_error =
        (match parked @ retrying with
          | (_, n) :: _ -> Some (Fail.to_string n.last)
          | [] -> None);
      in_flight =
        List.concat_map
          (fun id ->
            match List.assoc_opt id records with
              | Some r -> List.concat_map Op.paths r.ops
              | None -> [])
          (Dqueue.running uploads);
      bytes_owed = owed;
      mark_age =
        Option.map
          (fun k ->
            Unix.gettimeofday () -. (Int64.to_float (Entry_key.ms k) /. 1000.))
          (mark ());
      cache =
        (match Cache.last_counts cache with
          | Some c -> c
          | None -> Cache.enforce_cap cache);
      max_cache = Cache.cap cache;
    }

  let pending_metadata () = Dqueue.pending metadata

  let residency path =
    match resolve path with
      | Some (Published m) -> Cache.resident cache m
      | Some (Staged_edit _) -> (1, 1)
      | None -> Fail.absent "%s: no such file" path

  (* ponytail: polled; a per-key signal from the queue if the latency of a
     saved file's acknowledgement ever matters. *)
  let await_upload path =
    let names (id, _) =
      match read_record id with
        | Some r -> List.mem path (List.concat_map Op.paths r.ops)
        | None -> false
    in
    let failing () =
      List.exists names (Dqueue.retrying uploads @ Dqueue.parked uploads)
      || Dqueue.retrying metadata @ Dqueue.parked metadata <> []
    in
    while
      Staged.edit staged path <> None
      && (not (Atomic.get paused))
      && not (failing ())
    do
      Stop.sleep 0.1
    done

  (* 04 §2.3: the lazy tree's markers, decimal epoch milliseconds. *)
  let pull_marker dir = Filename.concat (Mirror.path mirror dir) ".tsync-pulled"

  let hold_marker dir =
    Filename.concat (Mirror.path mirror dir) ".tsync-view-hold"

  let read_seconds path =
    Option.bind (Fs.read_file_opt path) (fun s ->
        Option.map (fun ms -> ms /. 1000.) (float_of_string_opt (String.trim s)))

  let write_seconds path at =
    Fs.replace path (Printf.sprintf "%.0f" (at *. 1000.))

  let pulled_at dir = read_seconds (pull_marker dir)
  let view_hold dir = read_seconds (hold_marker dir)

  let hold_views dir ~until =
    let rec up dir =
      (match view_hold dir with
        | Some held when held >= until -> ()
        | _ ->
            if Fs.is_dir (Mirror.path mirror dir) then
              write_seconds (hold_marker dir) until);
      if dir <> "" then up (Names.parent_of dir)
    in
    up dir

  (* What local changes and uploads touch while a pull's listing is in flight
     is newer than the listing: its sweep leaves it alone, as a rebuild's does. *)
  let pulls_running = ref 0

  let while_noting_touched f =
    Mutex.protect touched_m (fun () ->
        if !pulls_running = 0 then Atomic.set touched (Some (Hashtbl.create 16));
        incr pulls_running);
    Fun.protect f ~finally:(fun () ->
        Mutex.protect touched_m (fun () ->
            decr pulls_running;
            if !pulls_running = 0 then Atomic.set touched None))

  (* 04 §3.5: the store's listing replaces the folder's published entries,
     overlaid with this client's owed work. *)
  let pull_folder dir =
    let id =
      match Mirror.folder_id mirror dir with
        | Some id -> id
        | None ->
            Fail.raise_ Fail.Unprepared "%s: this client has not resolved it"
              dir
    in
    while_noting_touched @@ fun () ->
    let entries = T.children ~on_unusable:Tree.Fail_on_unusable id in
    with_meta @@ fun () ->
    if Mirror.folder_id mirror dir <> Some id then
      Fail.raise_ Fail.Local "%s moved while it was being pulled" dir;
    let o = owed () in
    let ops = owed_ops o in
    let differs = ref false in
    let listed = Hashtbl.create 64 in
    let free p = Staged.edit staged p = None && not (was_touched p) in
    let owed_below p =
      List.exists
        (fun op -> List.exists (Names.is_under ~dir:p) (Op.paths op))
        ops
    in
    let removes_file p =
      List.exists
        (function
          | Op.Delete q -> q = p
          | Rename { is_dir = false; src; _ } -> src = p
          | _ -> false)
        ops
    in
    let creates_file p =
      renamed_onto o p
      || List.exists
           (function Op.Put { path; _ } -> path = p | _ -> false)
           ops
    in
    let ours = function Some id -> owed_carries o id | None -> false in
    let record p id =
      ignore
        (Mirror.record_folder ~durable:false ~on_other:`Replace mirror p id);
      differs := true
    in
    let folder p (m : Folder.marker) =
      if not (owed_rmdir o m.id || owed_carries o m.id) then (
        match (Mirror.key_of_id mirror m.id, Mirror.kind mirror p) with
          | Some here, _ when here = p -> ()
          | Some here, `Absent when free p ->
              repost_moved (rename_local ~src:here ~dst:p ~is_dir:true);
              differs := true
          | Some _, _ -> ()
          | None, `Absent -> if free p then record p m.id
          | None, `Dir ->
              if not (ours (Mirror.folder_id mirror p)) then record p m.id
          | None, `File ->
              if free p then (
                remove_local_file p;
                record p m.id))
    in
    let file p (m : Manifest.t) =
      if free p && not (removes_file p) then (
        let write () =
          with_key p (fun () ->
              end_lineage p;
              Mirror.write_file ~durable:false mirror p m);
          differs := true
        in
        match Mirror.file mirror p with
          | `File old when Manifest.equal_content old m && old.mtime = m.mtime
            ->
              ()
          | `Dir ->
              if
                (not (ours (Mirror.folder_id mirror p)))
                && Staged.edits_under staged p = []
                && not (owed_below p)
              then (
                Mirror.remove_folder mirror p;
                write ())
          | _ -> write ())
    in
    List.iter
      (fun (e : Tree.entry) ->
        match e.body with
          | Dir m ->
              Hashtbl.replace listed m.name ();
              folder (Names.join dir m.name) m
          | File m ->
              Hashtbl.replace listed m.name ();
              file (Names.join dir m.name) m)
      entries;
    List.iter
      (fun (c : Mirror.child) ->
        let p = Names.join dir c.name in
        if (not (Hashtbl.mem listed c.name)) && not (was_touched p) then (
          match c.kind with
            | `File _ ->
                if Staged.edit staged p = None && not (creates_file p) then (
                  remove_local_file p;
                  differs := true)
            | `Dir id ->
                if
                  (not (ours id))
                  && Staged.edits_under staged p = []
                  && not (owed_below p)
                then (
                  Mirror.remove_folder mirror p;
                  differs := true)))
      (Mirror.list mirror dir);
    write_seconds (pull_marker dir) (Unix.gettimeofday ());
    !differs

  let pulling : (string, bool Rt.Promise.t) Hashtbl.t = Hashtbl.create 8
  let pulling_m = Mutex.create ()

  (* Concurrent pulls of one folder share one store read. *)
  let pull dir =
    let running, mine =
      Mutex.protect pulling_m (fun () ->
          match Hashtbl.find_opt pulling dir with
            | Some p -> (p, false)
            | None ->
                let p = Rt.Promise.create () in
                Hashtbl.replace pulling dir p;
                (p, true))
    in
    if mine then (
      let outcome = try Ok (pull_folder dir) with e -> Error e in
      Mutex.protect pulling_m (fun () -> Hashtbl.remove pulling dir);
      ignore (Rt.Promise.try_resolve_result running outcome));
    Rt.Promise.await running

  (* android §3.2 rule 3: the store's current manifest becomes the entry. *)
  let refresh_file path =
    if Staged.edit staged path = None then
      while_noting_touched @@ fun () ->
      match store_record (Names.parent_of path) (Names.leaf_of path) with
        | `Unresolved -> ()
        | `Record (Some m) ->
            with_meta (fun () ->
                let same =
                  match Mirror.manifest mirror path with
                    | Some old ->
                        Manifest.equal_content old m && old.mtime = m.mtime
                    | None -> false
                in
                if
                  (not same)
                  && Staged.edit staged path = None
                  && (not (was_touched path))
                  && Mirror.kind mirror path <> `Dir
                then (
                  with_key path (fun () ->
                      end_lineage path;
                      Mirror.write_file ~durable:false mirror path
                        (Manifest.rename m (Names.leaf_of path)));
                  changed [path]))
        | `Record None | `Absent | `Folder ->
            with_meta (fun () ->
                if
                  Staged.edit staged path = None
                  && (not (was_touched path))
                  && Mirror.kind mirror path = `File
                  && not
                       (List.exists
                          (function
                            | Op.Put { path = p; _ } -> p = path
                            | Rename { is_dir = false; dst; _ } -> dst = path
                            | _ -> false)
                          (owed_ops (owed ())))
                then (
                  remove_local_file path;
                  changed [path]))

  type handle = Local_ops.handle

  let bridge () = Atomic.get bridge_state
  let atomically = with_meta
  let folder_id path = Mirror.folder_id mirror path
  let path_of_id id = Mirror.key_of_id mirror id
  let parked () = Dqueue.parked uploads @ Dqueue.parked metadata

  let rearm () =
    Dqueue.rearm uploads + Dqueue.rearm metadata
    + Tsync_store.Composite.rearm C.composite

  let set_changed_hook f = changed_hook := f
  let staged_edits () = Staged.edits staged

  (* Last: [uploads] is the upload queue everywhere above. *)
  let uploads = uploads_running
end
