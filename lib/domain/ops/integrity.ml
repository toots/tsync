type answer = { store : string; queued : int option }
type repair = Repaired of { from_store : string } | Cleared | Unrepairable

type repair_stats = {
  checked : int;
  repaired : int;
  cleared : int;
  unrepairable : int;
  lost : string list;
}

let no_repairs =
  { checked = 0; repaired = 0; cleared = 0; unrepairable = 0; lost = [] }

let describe_repair ~chunk_key ~store = function
  | Repaired { from_store } ->
      Printf.sprintf "FIXED %s on %s (from %s)" chunk_key store from_store
  | Cleared ->
      Printf.sprintf "STALE %s on %s (body was already correct)" chunk_key store
  | Unrepairable ->
      Printf.sprintf "LOST  %s on %s (no store holds these bytes)" chunk_key
        store

type tree_finding =
  | Twice of { id : string; paths : string list }
  | Disowned of { marker : Stored_key.t; anchor : Folder.anchor }
  | Unanchored of { path : string; id : string; parent : string }
  | Orphan of { id : string; objects : int; sample : string list }
  | Trashed_live of { id : string; path : string; entry : Stored_key.t }

type tree_report = { findings : tree_finding list; orphans_checked : bool }
type tree_repair = { removed : int; anchored : int; left : tree_finding list }

let tree_unhealthy r = r.findings <> []

let describe_finding = function
  | Twice { id; paths } ->
      Printf.sprintf "TWICE %s at %s" id (String.concat " | " paths)
  | Disowned { marker; anchor } ->
      Printf.sprintf "DISOWNED %s (the folder lives under %s as %s)"
        (Stored_key.to_string marker)
        anchor.Folder.parent anchor.Folder.name
  | Unanchored { path; id; _ } -> Printf.sprintf "UNANCHORED %s (%s)" path id
  | Orphan { id; objects; sample } ->
      Printf.sprintf "ORPHAN %s (%d object%s%s)" id objects
        (if objects = 1 then "" else "s")
        (match sample with
          | [] -> ""
          | names -> ", e.g. " ^ String.concat ", " names)
  | Trashed_live { id; path; _ } ->
      Printf.sprintf
        "TRASHED-LIVE %s at %s (a trash entry still names it; expire would \
         remove it)"
        id path

(* A store whose requests are not draining is not a store that is slow: nothing
   is consuming them, which is what an undeployed or misfiltered notification
   looks like from here. *)
let poll_interval = 3.
let stall_after = 5

let unhealthy (r : Corruption.report) =
  r.Corruption.entries <> []
  || r.Corruption.unverified <> []
  || r.Corruption.unreachable <> []

module Over
    (Io : Io.S)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (Markers : Corruption.OVER with type 'a io := 'a Io.t)
    (Files : Fs.S with type 'a io := 'a Io.t)
    (Tree : Inode_tree.OVER with type 'a io := 'a Io.t)
    (Store : Store.INODE with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  let iter_p f xs = Io.iter_p f xs

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Cor = Markers.Make (C)
    module L = Chunk_layout.Make (C)
    module Tree = Tree.Make (C)
    module St = Store.Make (C)
    module Lk = Logical_key.Make (C)

    (* The namespaces a main on this disk holds, by reading its directory: no
       store lists by delimiter, and a whole listing walks every object. *)
    let namespaces_on_disk () =
      let local_root =
        List.find_map
          (fun (m : (module C.Store) Backend.member) ->
            let (module B : C.Store) = m.Backend.backend in
            if m.Backend.role = `Main then B.local_path else None)
          C.members
      in
      match local_root with
        | None -> Io.return None
        | Some root ->
            let dir =
              Filename.concat root
                (String.sub C.domain_prefix 0
                   (String.length C.domain_prefix - 1))
            in
            let+ names = Files.readdir_list_quiet dir in
            Some (List.filter (fun n -> not (Stored_key.internal_leaf n)) names)

    (* The trash entries: each names a folder by id, whose namespace and
       subtree are reachable from it. *)
    let trash_entries () =
      let module B = (val C.store : C.Store) in
      let* entries =
        B.list_prefix
          ~prefix:
            (Stored_key.to_string
               (Stored_key.trash_namespace ~prefix:C.domain_prefix))
          ()
      in
      let+ found =
        map_s
          (fun (e : Backend.file_entry) ->
            if Stored_key.is_dir_key e.Backend.key then Io.return None
            else
              Io.catch
                (fun () ->
                  let+ body = B.get ~key:e.Backend.key () in
                  Option.map
                    (fun (m : Folder.marker) -> (e.Backend.key, m.Folder.id))
                    (Folder.marker_of_string (Bigstring.to_string body)))
                (fun _ -> Io.return None))
          entries
      in
      List.filter_map Fun.id found

    let reachable_from folder_id ~seen =
      Tree.fold_tree
        ~on_unusable:(`Skip (fun _ _ -> ()))
        ~refresh_index:false ~folder_id ~key:Lk.root
        (fun () _ entry ->
          (match entry.Inode_tree.body with
            | Inode_tree.Dir m -> Hashtbl.replace seen m.Folder.id ()
            | Inode_tree.File _ -> ());
          Io.return ())
        ()

    let sample_of id =
      let* entries = St.list_namespace ~folder_id:id in
      let objects =
        List.filter Stored_key.is_child_object
          (List.map (fun (e : Backend.file_entry) -> e.Backend.key) entries)
      in
      let+ names =
        map_s
          (fun bkey ->
            Io.catch
              (fun () ->
                let+ body = St.get_object ~bkey in
                match Folder.marker_of_string body with
                  | Some m -> Some (m.Folder.name ^ "/")
                  | None -> (
                      match Manifest.of_string body with
                        | m -> Some (Manifest.recorded_name m)
                        | exception _ -> None))
              (fun _ -> Io.return None))
          (List.filteri (fun i _ -> i < 3) objects)
      in
      (List.length objects, List.filter_map Fun.id names)

    let tree_report () =
      let disowned = ref [] in
      let seen = Hashtbl.create 1024 in
      let paths : (string, string list) Hashtbl.t = Hashtbl.create 1024 in
      let unanchored = ref [] in
      let* () =
        Tree.fold_tree
          ~on_unusable:
            (`Skip
               (fun marker -> function
                 | `Disowned anchor ->
                     disowned := Disowned { marker; anchor } :: !disowned
                 | _ -> ()))
          ~refresh_index:false ~folder_id:Stored_key.root_id ~key:Lk.root
          (fun () key entry ->
            match entry.Inode_tree.body with
              | Inode_tree.File _ -> Io.return ()
              | Inode_tree.Dir m ->
                  let id = m.Folder.id in
                  let path =
                    Logical_key.path (Logical_key.dir_in key m.Folder.name)
                  in
                  Hashtbl.replace seen id ();
                  Hashtbl.replace paths id
                    (path
                    :: Option.value (Hashtbl.find_opt paths id) ~default:[]);
                  let+ anchor = St.get_anchor ~folder_id:id in
                  if anchor = None then
                    unanchored :=
                      Unanchored
                        {
                          path;
                          id;
                          parent =
                            Stored_key.parent_folder_id entry.Inode_tree.bkey;
                        }
                      :: !unanchored)
          ()
      in
      let twice =
        Hashtbl.fold
          (fun id ps acc ->
            match ps with
              | [_] -> acc
              | paths -> Twice { id; paths = List.sort compare paths } :: acc)
          paths []
      in
      let* trash = trash_entries () in
      (* A trash entry naming a folder the walk reached from the root. *)
      let trashed_live =
        List.filter_map
          (fun (entry, id) ->
            match Hashtbl.find_opt paths id with
              | Some (path :: _) -> Some (Trashed_live { id; path; entry })
              | _ -> None)
          trash
      in
      let trashed = List.map snd trash in
      let* on_disk = namespaces_on_disk () in
      let+ orphans =
        match on_disk with
          | None -> Io.return []
          | Some names ->
              let* () = iter_s (fun id -> reachable_from id ~seen) trashed in
              List.iter (fun id -> Hashtbl.replace seen id ()) trashed;
              Hashtbl.replace seen Stored_key.root_id ();
              Hashtbl.replace seen Stored_key.trash_id ();
              let+ found =
                map_s
                  (fun id ->
                    if Hashtbl.mem seen id then Io.return None
                    else
                      let+ objects, sample = sample_of id in
                      Some (Orphan { id; objects; sample }))
                  (List.sort compare names)
              in
              List.filter_map Fun.id found
      in
      {
        findings =
          List.sort compare twice @ List.rev !disowned @ trashed_live
          @ List.rev !unanchored @ orphans;
        orphans_checked = on_disk <> None;
      }

    let repair_tree ?(dry_run = false) () =
      if C.read_only && not dry_run then
        failwith
          (Printf.sprintf "%s is read-only, so nothing here may be rewritten."
             C.domain_name);
      let* report = tree_report () in
      fold_left_s
        (fun acc finding ->
          match finding with
            | Disowned { marker = stale; _ } | Trashed_live { entry = stale; _ }
              ->
                let+ removed =
                  if dry_run then Io.return true else St.delete_raw ~bkey:stale
                in
                if removed then { acc with removed = acc.removed + 1 }
                else { acc with left = acc.left @ [finding] }
            | Unanchored { id; parent; path } ->
                let+ () =
                  if dry_run then Io.return ()
                  else
                    St.put_anchor ~folder_id:id ~parent
                      ~name:(Filename.basename path)
                in
                { acc with anchored = acc.anchored + 1 }
            | Twice _ | Orphan _ ->
                Io.return { acc with left = acc.left @ [finding] })
        { removed = 0; anchored = 0; left = [] }
        report.findings

    let follow ~on_progress ~on_done ~on_stalled
        (m : (module C.Store) Backend.member) =
      let (module B : C.Store) = m.Backend.backend in
      let jobs = L.verify_jobs_prefix in
      let corrupted = L.corrupted_prefix in
      (* A listing that fails counts as nothing found rather than ending the
         watch: the store is being asked about work it may not have started. *)
      let count prefix =
        Io.catch
          (fun () ->
            let+ es = B.list_prefix ~prefix () in
            List.length es)
          (fun _ -> Io.return 0)
      in
      let store = m.Backend.name in
      let rec loop stalled last =
        let* left = count jobs in
        let* found = count corrupted in
        on_progress ~store ~left ~found;
        if left = 0 then begin
          on_done ~store ~found;
          Io.return ()
        end
        else (
          let stalled = if left = last then stalled + 1 else 0 in
          if stalled >= stall_after then begin
            on_stalled ~store;
            Io.return ()
          end
          else
            let* () = Clock.sleep poll_interval in
            loop stalled left)
      in
      loop 0 (-1)

    let verify ~on_answers ~on_progress ~on_done ~on_stalled () =
      let* answers =
        map_s
          (fun (m : (module C.Store) Backend.member) ->
            let (module B : C.Store) = m.Backend.backend in
            let+ a = B.verify_all ~chunk_prefix:C.chunk_prefix () in
            match a with
              | `Queued n -> { store = m.Backend.name; queued = Some n }
              | `Unsupported -> { store = m.Backend.name; queued = None })
          C.members
      in
      on_answers answers;
      let queued =
        List.filter_map
          (fun a -> Option.map (fun n -> (a.store, n)) a.queued)
          answers
      in
      if queued = [] then Io.return `Nothing_queued
      else
        let+ () =
          iter_p
            (fun (m : (module C.Store) Backend.member) ->
              if List.mem_assoc m.Backend.name queued then
                follow ~on_progress ~on_done ~on_stalled m
              else Io.return ())
            C.members
        in
        `Watched

    let good_body (module B : C.Store) chunk_key =
      Io.catch
        (fun () ->
          let+ body = B.get_opt ~key:(L.key chunk_key) () in
          match body with
            | Some body when Chunks.key_of_body body = chunk_key -> Some body
            | _ -> None)
        (fun _ -> Io.return None)

    let member_named name = Backend.named name C.members

    (* A backfill target is excluded by [readable]: it is not read from, and may
       not hold the chunk at all. *)
    let sources_for ~source ~bad_store =
      List.filter
        (fun (m : (module C.Store) Backend.member) ->
          m.Backend.name <> bad_store
          && m.Backend.readable
          && match source with None -> true | Some n -> m.Backend.name = n)
        C.members

    let rec first_good chunk_key = function
      | [] -> Io.return None
      | (m : (module C.Store) Backend.member) :: rest -> (
          let* body = good_body m.Backend.backend chunk_key in
          match body with
            | Some body -> return_some (m.Backend.name, body)
            | None -> first_good chunk_key rest)

    (* A stale marker is repaired by rewriting the body over itself rather than by
       removing the marker: the store has to be the one to conclude the object is
       fine — see the .mli. *)
    let repair_one ~source ~dry_run (e : Corruption.entry) =
      let chunk_key = e.Corruption.chunk_key in
      match member_named e.Corruption.store with
        | None -> Io.return Unrepairable
        | Some m -> (
            let (module Dst : C.Store) = m.Backend.backend in
            let write body =
              if dry_run then Io.return ()
              else Dst.put ~key:(L.key chunk_key) ~data:body ()
            in
            (* Its own copy first: see {!Cleared}. *)
            let* mine = good_body m.Backend.backend chunk_key in
            match mine with
              | Some body ->
                  let+ () = write body in
                  Cleared
              | None -> (
                  let* found =
                    first_good chunk_key
                      (sources_for ~source ~bad_store:e.Corruption.store)
                  in
                  match found with
                    | None -> Io.return Unrepairable
                    | Some (from_store, body) ->
                        let+ () = write body in
                        Repaired { from_store }))

    let repair ?source ?(dry_run = false) ?(on_start = fun ~total:_ -> ())
        ?(on_chunk = fun ~done_:_ ~total:_ ~chunk_key:_ ~store:_ _ -> ()) () =
      if C.read_only && not dry_run then
        failwith
          (Printf.sprintf "%s is read-only, so nothing here may be rewritten."
             C.domain_name);
      let* report = Cor.list () in
      let total = List.length report.Corruption.entries in
      on_start ~total;
      let* stats =
        fold_left_s
          (fun acc (e : Corruption.entry) ->
            let+ outcome = repair_one ~source ~dry_run e in
            let acc = { acc with checked = acc.checked + 1 } in
            on_chunk ~done_:acc.checked ~total ~chunk_key:e.Corruption.chunk_key
              ~store:e.Corruption.store outcome;
            match outcome with
              | Repaired _ -> { acc with repaired = acc.repaired + 1 }
              | Cleared -> { acc with cleared = acc.cleared + 1 }
              | Unrepairable ->
                  {
                    acc with
                    unrepairable = acc.unrepairable + 1;
                    lost = acc.lost @ [e.Corruption.chunk_key];
                  })
          no_repairs report.Corruption.entries
      in
      if not dry_run then Cor.invalidate ();
      Io.return stats
  end
end
