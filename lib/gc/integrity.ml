open Tsync_core
open Tsync_store
open Tsync_remote

type finding =
  | Disowned of { marker : Key.t; anchor : Folder.anchor option }
  | Unmarked of { id : Folder_id.t; parent : Folder_id.t; name : string }
  | Unaccounted of { key : Key.t; found : string; expected : string option }

type tree =
  | Behind of { tree_head : int; head : int }
  | Findings of finding list

type corrupt = { member : string; chunk : Chunk_key.t }
type report = { tree : tree; corrupt : corrupt list }

let healthy r = r.tree = Findings [] && r.corrupt = []

let folder id =
  if Folder_id.equal id Folder_id.root then "the root"
  else "folder " ^ Folder_id.to_string id

let describe = function
  | Disowned { marker; anchor = Some anchor } ->
      Printf.sprintf "%s names a folder whose anchor files it under %s as %S"
        (Key.to_string marker) (folder anchor.parent) anchor.aname
  | Disowned { marker; anchor = None } ->
      Printf.sprintf "%s names a folder that has no anchor"
        (Key.to_string marker)
  | Unmarked { id; parent; name } ->
      Printf.sprintf
        "folder %s is anchored under %s as %S and has no marker there"
        (Folder_id.to_string id) (folder parent) name
  | Unaccounted { key; found; expected } ->
      Printf.sprintf "%s holds %s%s" (Key.to_string key) found
        (match expected with
          | Some e -> ", and the log gives it " ^ e
          | None -> ", which the log does not account for")

type chunk_repair = Cleared | Repaired of string | Unrepairable

type verified =
  | Unsupported
  | Done of { corrupt : int }
  | Stalled of { left : int option; corrupt : int option }
  | Abandoned of { left : int option; corrupt : int option }

module Make (C : Context.S) = struct
  module T = Tree.Make (C)

  let d = C.domain
  let store = C.store

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

  (* 05 §4.10: the last value the retained entries give each key they name. *)
  let expected ~cancelled log =
    let numbers =
      List.filter_map
        (fun (e : Store.entry) -> int_of_string_opt (Key.leaf e.key))
        (Cancel.race cancelled (fun () -> store.list_prefix (Key.log d)))
    in
    let table = Hashtbl.create 256 in
    (match List.sort compare numbers with
      | [] -> ()
      | first :: _ ->
          List.iter
            (fun (e : Log_store.entry) ->
              List.iter
                (fun (c : Log_entry.command) ->
                  Hashtbl.replace table (Algebra.key_of c) c)
                (Option.value ~default:[] (Log_store.commands e)))
            (Log_store.read_entries log first));
    table

  let tree_findings ~narrate ~cancelled log =
    let expected = expected ~cancelled log in
    let ids = Hashtbl.create 1024 in
    Hashtbl.replace ids Folder_id.root ();
    List.iter
      (fun (e : Store.entry) ->
        Option.iter
          (fun id -> Hashtbl.replace ids id ())
          (Key.folder_of_namespace_key d e.key))
      (Cancel.race cancelled (fun () -> store.list_prefix (Key.manifests d)));
    let m = Mutex.create () in
    let disowned = ref []
    and anchors = Hashtbl.create 1024
    and markers = Hashtbl.create 1024
    and files = Hashtbl.create 4096
    and strays = ref []
    and walked = ref 0 in
    let locked f = Mutex.protect m f in
    Rt.iter_bounded ~width:(max 1 C.max_downloads)
      (fun id ->
        Cancel.check cancelled;
        let anchor = if Folder_id.is_root id then None else T.anchor id in
        let children =
          T.children
            ~on_unusable:
              (Skip
                 (function
                 | Disowned (marker, anchor) ->
                     locked (fun () ->
                         disowned := Disowned { marker; anchor } :: !disowned)
                 | _ -> ()))
            id
        in
        locked (fun () ->
            incr walked;
            Narrate.progress narrate "%s read"
              (Narrate.count !walked "namespace");
            Option.iter (Hashtbl.replace anchors id) anchor;
            List.iter
              (fun (e : Tree.entry) ->
                (match e.body with
                  | Dir marker -> Hashtbl.replace markers marker.id e.key
                  | File manifest ->
                      Hashtbl.replace files
                        { Algebra.parent = id; name = manifest.name }
                        (e.key, manifest));
                if anchor = None && not (Folder_id.is_root id) then
                  strays := e.key :: !strays)
              children))
      (Hashtbl.fold (fun id () acc -> id :: acc) ids []);
    let unmarked =
      Hashtbl.fold
        (fun id (a : Folder.anchor) acc ->
          if Hashtbl.mem markers id then acc
          else Unmarked { id; parent = a.parent; name = a.aname } :: acc)
        anchors []
    in
    let place (p : Algebra.place) =
      Printf.sprintf "%S in %s" p.name (folder p.parent)
    in
    let unaccounted =
      Hashtbl.fold
        (fun (_ : Algebra.key) (c : Log_entry.command) acc ->
          match c with
            | `File (p, _, after) ->
                let record = Hashtbl.find_opt files p in
                let found =
                  Option.map (fun (_, m) -> Log_entry.identity_of m) record
                and wanted = Option.bind after Log_entry.identity in
                let content = function
                  | Some i -> "content " ^ i
                  | None -> "no record"
                in
                if found = wanted then acc
                else
                  Unaccounted
                    {
                      key =
                        (match record with
                          | Some (k, _) -> k
                          | None -> Key.child d p.parent p.name);
                      found = content found;
                      expected = Some (content wanted);
                    }
                  :: acc
            | `Folder (i, _, after) ->
                let found =
                  Option.map
                    (fun (a : Folder.anchor) ->
                      { Algebra.parent = a.parent; name = a.aname })
                    (Hashtbl.find_opt anchors i)
                in
                let at = function
                  | Some p -> "the place " ^ place p
                  | None -> "no anchor"
                in
                if found = after then acc
                else
                  Unaccounted
                    {
                      key = Key.anchor d i;
                      found = at found;
                      expected = Some (at after);
                    }
                  :: acc)
        expected []
    in
    List.sort compare !disowned @ List.sort compare unmarked
    @ List.sort compare unaccounted
    @ List.map
        (fun key ->
          Unaccounted
            {
              key;
              found = "a record of a folder with no anchor";
              expected = None;
            })
        (List.sort Key.compare !strays)

  (* 05 §4.10: read-only, answered by the main. With an entry above the tree
     head the records are legitimately between two trees, and nothing is
     found. *)
  let report ?(narrate = Narrate.none) ?(cancelled = Fun.const false) () =
    let log = Log_store.create d store in
    let tree_head = Log_store.tree_head log in
    let tree =
      match Log_store.read_entries log (tree_head + 1) with
        | _ :: _ as above ->
            Narrate.say narrate
              "%s: the tree is behind its log (tree head %d, head %d); a \
               projection is owed or in progress"
              (Domain_name.to_string d) tree_head
              (tree_head + List.length above);
            Behind { tree_head; head = tree_head + List.length above }
        | [] ->
            Narrate.say narrate "%s: reading every namespace of the tree"
              (Domain_name.to_string d);
            Findings (tree_findings ~narrate ~cancelled log)
    in
    let corrupt = corrupt_chunks ~cancelled in
    Narrate.say narrate "  %s, %s"
      (match tree with
        | Findings f -> Narrate.count (List.length f) "finding"
        | Behind _ -> "no finding made")
      (Narrate.count (List.length corrupt) "corrupt chunk");
    { tree; corrupt }

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
      let shown = function Some n -> string_of_int n | None -> "?" in
      Narrate.progress narrate
        ~fraction:(1. -. (float (Option.value ~default:4096 left) /. 4096.))
        "%s: %s shard requests left, %s corrupt chunks so far" m.name
        (shown left) (shown corrupt);
      match now with
        | Some 0, Some corrupt -> Done { corrupt }
        | _ ->
            let still =
              if now = last || left = None || corrupt = None then still + 1
              else 0
            in
            if still >= stall_polls then Stalled { left; corrupt }
            else if cancelled () then Abandoned { left; corrupt }
            else (
              Rt.sleep poll;
              go ~still now)
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
            try Some (List.length (m.store.list_prefix p)) with
              | (Stop.Stopping | Rt.Cancelled) as e -> raise e
              | _ -> None
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
      | Some b when Chunk_key.names chunk b -> Some b
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
