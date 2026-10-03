open Tsync_core
open Tsync_store
open Tsync_remote

type finding =
  | Twice of { id : Folder_id.t; paths : string list }
  | Disowned of { marker : Key.t; anchor : Folder.anchor }
  | Trashed_live of { entry : Key.t; id : Folder_id.t }
  | Unanchored of {
      path : string;
      id : Folder_id.t;
      parent : Folder_id.t;
      name : string;
    }
  | Orphan of {
      id : Folder_id.t;
      name : string;
      parent : Folder_id.t option;
      objects : int;
      sample : Key.t list;
      newest : float;
      top_level : bool;
    }

type corrupt = { member : string; chunk : Chunk_key.t }

type report = {
  findings : finding list;
  tombstones : int;
  unreadable : Key.t list;
  corrupt : corrupt list;
}

let healthy r = r.findings = [] && r.corrupt = [] && r.unreadable = []

let folder id =
  if Folder_id.equal id Folder_id.root then "the root"
  else "folder " ^ Folder_id.to_string id

let describe = function
  | Twice { id; paths } ->
      Printf.sprintf "folder %s is at %d paths: %s" (Folder_id.to_string id)
        (List.length paths) (String.concat ", " paths)
  | Disowned { marker; anchor } ->
      Printf.sprintf "%s names a folder whose anchor files it under %s as %S"
        (Key.to_string marker) (folder anchor.parent) anchor.aname
  | Trashed_live { entry; id } ->
      Printf.sprintf "trash entry %s names folder %s, which is live"
        (Key.to_string entry) (Folder_id.to_string id)
  | Unanchored { path; id; parent; _ } ->
      Printf.sprintf "%s (folder %s)%s has no anchor" path
        (Folder_id.to_string id)
        (if Folder_id.equal parent Folder_id.trash then ", in the trash,"
         else "")
  | Orphan { id; name; objects; sample; top_level; _ } ->
      Printf.sprintf "folder %s (%S) is unreachable, holding %s%s: %s"
        (Folder_id.to_string id) name
        (Narrate.count objects "object")
        (if top_level then "" else ", inside another unreachable folder")
        (String.concat ", " (List.map Key.to_string sample))

type tree_repair =
  | Deleted
  | Anchored
  | Adopted
  | Young
  | Nested
  | Left
  | Incomplete
  | Failed of string

type chunk_repair = Cleared | Repaired of string | Unrepairable

type verified =
  | Unsupported
  | Done of { corrupt : int }
  | Stalled of { left : int; corrupt : int }
  | Abandoned of { left : int; corrupt : int }

let orphan_grace = Tsync_sync.Outbound.horizon +. (7. *. 86400.)

let rank = function
  | Twice _ -> 0
  | Disowned _ -> 1
  | Trashed_live _ -> 2
  | Unanchored _ -> 3
  | Orphan _ -> 4

module Make (C : Context.S) = struct
  module T = Tree.Make (C)

  let d = C.domain
  let store = C.store
  let anchor_leaf = Key.leaf (Key.anchor d Folder_id.root)

  (* Every folder a walk from [id] reaches, with its paths; markers whose
     anchor disowns them are reported, not followed. *)
  let walk ~cancelled ~progress ~reached ~disowned ~unanchored ~unreadable id
      ~root_path =
    T.fold_tree
      ~on_unusable:
        (Skip
           (function
           | Disowned (k, a) -> disowned := (k, a) :: !disowned
           | Unreadable (k, _) -> unreadable := k :: !unreadable
           | _ -> ()))
      id ~root_path
      (fun () parent_path (e : Tree.entry) ->
        Cancel.check cancelled;
        match e.body with
          | Dir m ->
              let path = Names.join parent_path m.name in
              progress path;
              let k = Folder_id.to_string m.id in
              Hashtbl.replace reached k
                (path :: Option.value ~default:[] (Hashtbl.find_opt reached k));
              Option.iter
                (fun parent ->
                  if T.anchor m.id = None then
                    unanchored :=
                      Unanchored { path; id = m.id; parent; name = m.name }
                      :: !unanchored)
                (Key.folder_of_namespace_key d e.key)
          | File _ -> ())
      ()

  (* gc §4.6: every namespace of the manifest area with what it holds. *)
  let namespaces ~cancelled =
    let by_ns = Hashtbl.create 64 in
    List.iter
      (fun (e : Store.entry) ->
        match Key.folder_of_namespace_key d e.key with
          | Some id ->
              let k = Folder_id.to_string id in
              Hashtbl.replace by_ns k
                ((id, e) :: Option.value ~default:[] (Hashtbl.find_opt by_ns k))
          | None -> ())
      (Cancel.race cancelled (fun () -> store.list_prefix (Key.manifests d)));
    Hashtbl.fold
      (fun _ l acc ->
        let id = fst (List.hd l) in
        (id, List.map snd l) :: acc)
      by_ns []

  let orphans ~cancelled ~reached =
    let unreached =
      List.filter
        (fun (id, _) ->
          (not (Folder_id.equal id Folder_id.root))
          && (not (Folder_id.equal id Folder_id.trash))
          && not (Hashtbl.mem reached (Folder_id.to_string id)))
        (namespaces ~cancelled)
    in
    let is_anchor (e : Store.entry) = Key.leaf e.key = anchor_leaf in
    let tombstones, orphans =
      List.partition (fun (_, es) -> List.for_all is_anchor es) unreached
    in
    let orphan_ids = Hashtbl.create 16 in
    List.iter
      (fun (id, _) -> Hashtbl.replace orphan_ids (Folder_id.to_string id) ())
      orphans;
    let found =
      List.map
        (fun (id, es) ->
          let anchor = T.anchor id in
          let objects = List.filter (fun e -> not (is_anchor e)) es in
          Orphan
            {
              id;
              name =
                (match anchor with
                  | Some a -> a.aname
                  | None -> Folder_id.to_string id);
              parent = Option.map (fun (a : Folder.anchor) -> a.parent) anchor;
              objects = List.length objects;
              sample =
                List.filteri
                  (fun i _ -> i < 3)
                  (List.map (fun (e : Store.entry) -> e.key) objects);
              newest =
                List.fold_left
                  (fun t (e : Store.entry) -> Float.max t e.last_modified)
                  0. es;
              top_level =
                (match anchor with
                  | Some a ->
                      not
                        (Hashtbl.mem orphan_ids (Folder_id.to_string a.parent))
                  | None -> true);
            })
        (List.sort (fun (a, _) (b, _) -> Folder_id.compare a b) orphans)
    in
    (found, List.length tombstones)

  let corrupt_chunks ~cancelled =
    List.concat_map
      (fun (m : Composite.member) ->
        List.filter_map
          (fun (e : Store.entry) ->
            match Key.chunk_of_marker e.key with
              | Some (d', chunk) when Domain_name.equal d' d ->
                  Some { member = m.name; chunk }
              | _ -> None)
          (Cancel.race cancelled (fun () ->
               m.store.list_prefix (Key.corrupted d))))
      (Composite.members C.composite)

  let report ?(narrate = Narrate.none) ?(cancelled = Fun.const false) () =
    let reached = Hashtbl.create 1024
    and disowned = ref []
    and unanchored = ref []
    and unreadable = ref [] in
    Narrate.say narrate "%s: walking the tree from the root"
      (Domain_name.to_string d);
    let walked = ref 0 in
    let progress path =
      incr walked;
      Narrate.progress narrate "%s walked, at %s"
        (Narrate.count !walked "folder")
        path
    in
    walk ~cancelled ~progress ~reached ~disowned ~unanchored ~unreadable
      Folder_id.root ~root_path:"";
    let live = Hashtbl.copy reached in
    let trashed = T.trashed () in
    Narrate.say narrate "  %s reached; walking %s"
      (Narrate.count (Hashtbl.length live) "folder")
      (Narrate.count (List.length trashed) "trashed folder");
    let trashed_live =
      List.concat_map
        (fun (f : T.trashed) ->
          if Hashtbl.mem live (Folder_id.to_string f.id) then
            List.map
              (fun (e : Store.entry) ->
                Trashed_live { entry = e.key; id = f.id })
              f.entries
          else (
            if f.state = `No_anchor then
              unanchored :=
                Unanchored
                  {
                    path = Option.value ~default:f.name f.path;
                    id = f.id;
                    parent = Folder_id.trash;
                    name = f.name;
                  }
                :: !unanchored;
            if not (cancelled ()) then (
              Hashtbl.replace reached (Folder_id.to_string f.id) [];
              walk ~cancelled ~progress ~reached ~disowned ~unanchored
                ~unreadable f.id ~root_path:f.name);
            []))
        trashed
    in
    Cancel.check cancelled;
    Narrate.say narrate "  listing the manifest area for unreachable folders";
    Narrate.progress narrate "listing the manifest area";
    let orphans, tombstones = orphans ~cancelled ~reached in
    let twice =
      Hashtbl.fold
        (fun k paths acc ->
          match (Folder_id.of_string k, List.sort_uniq compare paths) with
            | Some id, (_ :: _ :: _ as paths) -> Twice { id; paths } :: acc
            | _ -> acc)
        live []
      |> List.sort compare
    in
    let findings =
      twice
      @ List.rev_map
          (fun (marker, anchor) -> Disowned { marker; anchor })
          !disowned
      @ trashed_live @ List.rev !unanchored @ orphans
    in
    let corrupt = corrupt_chunks ~cancelled in
    Narrate.say narrate "  %s, %s, %s"
      (Narrate.count (List.length findings) "finding")
      (Narrate.count tombstones "tombstone")
      (Narrate.count (List.length corrupt) "corrupt chunk");
    {
      findings =
        List.stable_sort (fun a b -> compare (rank a) (rank b)) findings;
      tombstones;
      corrupt;
      unreadable = List.rev !unreadable;
    }

  (* An id at two paths is anchored at neither: where it lives is a person's
     choice. *)
  let repair_one ~apply ~now ~twice ~incomplete = function
    | Twice _ -> Left
    | Unanchored { id; _ } when List.exists (Folder_id.equal id) twice -> Left
    | Disowned { marker = k; _ } | Trashed_live { entry = k; _ } ->
        if apply then ignore (store.delete k);
        Deleted
    | Unanchored { id; parent; name; _ } ->
        if not apply then Anchored
        else if Folder_id.equal parent Folder_id.trash then (
          T.anchor_in_trash id ~name;
          Anchored)
        else (
          match T.place id ~parent ~name with
            | `Placed -> Anchored
            | `Taken other ->
                Failed ("the slot holds folder " ^ Folder_id.to_string other)
            | `Taken_by_file -> Failed "the slot holds a file")
    | Orphan _ when incomplete -> Incomplete
    | Orphan { top_level = false; _ } -> Nested
    | Orphan { newest; _ } when now -. newest < orphan_grace -> Young
    | Orphan { id; name; parent; _ } ->
        if apply then
          T.trash id
            ~old:(Option.value ~default:Folder_id.root parent, name)
            ~path:name;
        Adopted

  let repair_tree ?(narrate = Narrate.none) ?(apply = false)
      ?(cancelled = Fun.const false) ?(now = Unix.gettimeofday ()) r =
    let twice =
      List.filter_map
        (function Twice { id; _ } -> Some id | _ -> None)
        r.findings
    in
    let total = List.length r.findings in
    List.mapi (fun i f -> (i, f)) r.findings
    |> List.filter_map (fun (i, f) ->
        if cancelled () then None
        else (
          Narrate.progress narrate
            ~fraction:(float i /. float total)
            "repairing the tree: %d of %d findings" (i + 1) total;
          let outcome =
            try
              repair_one ~apply ~now ~twice ~incomplete:(r.unreadable <> []) f
            with
              | (Stop.Stopping | Rt.Cancelled) as e -> raise e
              | e -> Failed (Printexc.to_string e)
          in
          Narrate.say narrate "  %s: %s" (describe f)
            (match outcome with
              | Deleted -> if apply then "deleted" else "would be deleted"
              | Anchored -> if apply then "anchored" else "would be anchored"
              | Adopted ->
                  if apply then "adopted into the trash"
                  else "would be adopted into the trash"
              | Young -> "younger than the grace; left"
              | Nested ->
                  "inside another unreachable folder; considered once that one \
                   is adopted"
              | Left -> "left; resolve it by hand"
              | Incomplete ->
                  "left: the walk could not read every folder, so it cannot \
                   tell an orphan from a folder below one it missed"
              | Failed reason -> "failed: " ^ reason);
          Some (f, outcome)))

  let follow ~narrate ~cancelled ~poll ~stall_polls (m : Composite.member) =
    let count p =
      try Some (List.length (m.store.list_prefix p)) with
        | (Stop.Stopping | Rt.Cancelled) as e -> raise e
        | e ->
            Log.warn "verification on %s: %s" m.name (Printexc.to_string e);
            None
    in
    let rec go ~still last =
      let left = count (Key.verify_jobs d)
      and corrupt = count (Key.corrupted d) in
      let now = (left, corrupt) in
      let left' = Option.value ~default:(-1) left
      and corrupt' = Option.value ~default:0 corrupt in
      Narrate.progress narrate
        ~fraction:(1. -. (float (max 0 left') /. 4096.))
        "%s: %d shard requests left, %d corrupt chunks so far" m.name left'
        corrupt';
      if left = Some 0 then Done { corrupt = corrupt' }
      else (
        let still = if now = last || left = None then still + 1 else 0 in
        if still >= stall_polls then
          Stalled { left = left'; corrupt = corrupt' }
        else if cancelled () then Abandoned { left = left'; corrupt = corrupt' }
        else (
          Rt.sleep poll;
          go ~still now))
    in
    go ~still:0 (None, None)

  let verify ?(narrate = Narrate.none) ?(cancelled = Fun.const false)
      ?(poll = 3.) ?(stall_polls = 5) () =
    let members = Composite.members C.composite in
    let queued =
      List.map
        (fun (m : Composite.member) ->
          match Composite.queue_verification ~cancelled C.composite m with
            | `Queued n ->
                Narrate.say narrate
                  "%s: queued %d shard requests for its bucket function" m.name
                  n;
                (m, true)
            | `Unsupported -> (m, false))
        members
    in
    (* Queueing cut short checks part of the store: never reported as done. *)
    List.map
      (fun ((m : Composite.member), q) ->
        if not q then (m.name, Unsupported)
        else if cancelled () then (
          let count p =
            try List.length (m.store.list_prefix p) with
              | (Stop.Stopping | Rt.Cancelled) as e -> raise e
              | _ -> 0
          in
          ( m.name,
            Abandoned
              {
                left = count (Key.verify_jobs d);
                corrupt = count (Key.corrupted d);
              } ))
        else (m.name, follow ~narrate ~cancelled ~poll ~stall_polls m))
      queued

  let sound chunk (s : Store.t) =
    match s.get_opt (Key.chunk d chunk) with
      | Some b when Chunk_key.equal (Chunk_key.of_bigstring b) chunk -> Some b
      | _ -> None

  let repair_chunks ?(narrate = Narrate.none) ?(apply = false) ?source
      ?(cancelled = Fun.const false) r =
    let members = Composite.members C.composite in
    let total = List.length r.corrupt in
    List.filter_map
      (fun (i, c) ->
        if cancelled () then None
        else (
          Narrate.progress narrate
            ~fraction:(float i /. float total)
            "repairing chunks: %d of %d" (i + 1) total;
          let bad =
            List.find (fun (m : Composite.member) -> m.name = c.member) members
          in
          let write b =
            if apply then (
              Composite.guard C.composite bad "repair a corrupt chunk";
              bad.store.put (Key.chunk d c.chunk) b)
          in
          let outcome =
            match sound c.chunk bad.store with
              | Some b ->
                  write b;
                  Cleared
              | None -> (
                  match
                    List.find_map
                      (fun (m : Composite.member) ->
                        if
                          m.name = c.member
                          || Option.fold ~none:false ~some:(( <> ) m.name)
                               source
                        then None
                        else
                          Option.map
                            (fun b -> (m.name, b))
                            (sound c.chunk m.store))
                      members
                  with
                    | Some (from, b) ->
                        write b;
                        Repaired from
                    | None -> Unrepairable)
          in
          Narrate.say narrate "  %s on %s: %s"
            (Chunk_key.to_string c.chunk)
            c.member
            (match outcome with
              | Cleared -> "its own copy is sound; rewritten over itself"
              | Repaired from -> "a sound copy from " ^ from
              | Unrepairable -> "no member holds a sound copy");
          Some (c, outcome)))
      (List.mapi (fun i c -> (i, c)) r.corrupt)
end
