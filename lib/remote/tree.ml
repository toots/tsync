open Tsync_core
open Tsync_store

type body = Dir of Folder.marker | File of Manifest.t
type entry = { key : Key.t; leaf_hash : string; body : body }

type unusable =
  | Unreadable of Key.t * string
  | Unclassifiable of Key.t
  | Disowned of Key.t * Folder.anchor

type on_unusable = Fail_on_unusable | Skip of (unusable -> unit)

let describe_unusable = function
  | Unreadable (k, why) ->
      Printf.sprintf "%s: unreadable (%s)" (Key.to_string k) why
  | Unclassifiable k -> Printf.sprintf "%s: unclassifiable" (Key.to_string k)
  | Disowned (k, a) ->
      Printf.sprintf "%s: disowned by its anchor (%s/%s)" (Key.to_string k)
        (Folder_id.to_string a.parent)
        a.aname

module Make (C : Context.S) = struct
  let d = C.domain
  let store = C.store

  let anchor id =
    Option.bind (store.get_opt (Key.anchor d id)) Folder.decode_anchor

  let placed id ~parent ~name =
    match anchor id with
      | None -> `Unanchored
      | Some a when Folder_id.equal a.parent parent && a.aname = name -> `Here
      | Some a -> `Elsewhere a

  (* data-model §6.3: a marker is filed iff its folder's anchor names its slot,
     or the folder has no anchor. *)
  let filed ~parent ~name id =
    match placed id ~parent ~name with
      | `Here | `Unanchored -> true
      | `Elsewhere _ -> false

  let slot parent name = Key.child d parent name

  let classify_slot parent name body =
    match Folder.classify_marker body with
      | `Marker (m, _) ->
          if filed ~parent ~name m.id then `Filed m.id else `Disowned m.id
      | `Unclassifiable -> `Unclassifiable
      | `Not_marker ->
          if Manifest.is_manifest body then `File else `Unclassifiable

  let holder_at parent name =
    match store.get_opt (slot parent name) with
      | None -> None
      | Some b -> (
          match classify_slot parent name b with
            | `Filed id -> Some id
            | _ -> None)

  let remove_marker_if ~parent ~name id =
    let k = slot parent name in
    match store.get_opt k with
      | Some b -> (
          match Folder.classify_marker b with
            | `Marker (m, _) when Folder_id.equal m.id id ->
                ignore (store.delete k)
            | _ -> ())
      | None -> ()

  let write_anchor id ~parent ~name =
    store.put (Key.anchor d id) (Folder.anchor_body { parent; aname = name })

  (* data-model §6.2 step 1: create-if-absent, then read what holds the slot;
     an answer that names nobody is read back, never taken as won. *)
  let rec claim ?(rounds = 8) ~parent ~name id =
    if rounds = 0 then
      Fail.raise_ Fail.Load "claim of %s keeps meeting litter" name
    else (
      let k = slot parent name in
      let body = Folder.marker_body { name; id } in
      let holder =
        match store.put_if_absent k body with Store.Won -> body | Held b -> b
      in
      let holder =
        match Folder.classify_marker holder with
          | `Marker _ -> Some holder
          | _ -> store.get_opt k
      in
      match holder with
        | None -> claim ~rounds:(rounds - 1) ~parent ~name id
        | Some h -> (
            match Folder.classify_marker h with
              | `Marker (m, _) when Folder_id.equal m.id id -> (
                  match placed id ~parent ~name with
                    | `Unanchored ->
                        write_anchor id ~parent ~name;
                        `Won
                    | `Here -> `Won
                    | `Elsewhere _ ->
                        Fail.raise_ Fail.Link
                          "folder %s moved while claiming %s"
                          (Folder_id.to_string id) name)
              | `Marker (m, _) ->
                  if filed ~parent ~name m.id then `Taken m.id
                  else (
                    remove_marker_if ~parent ~name m.id;
                    claim ~rounds:(rounds - 1) ~parent ~name id)
              | `Unclassifiable | `Not_marker ->
                  Fail.raise_ Fail.Exists
                    "%s is held by something that is not a folder" name))

  (* data-model §6.2 step 3. *)
  let confirm ~parent ~name id =
    match store.get_opt (slot parent name) with
      | None -> (
          match claim ~parent ~name id with
            | `Won -> `Reclaimed
            | `Taken j -> `Lost j)
      | Some b -> (
          match classify_slot parent name b with
            | `Filed j when Folder_id.equal j id -> `Final
            | `Filed j -> `Lost j
            | `Disowned j -> (
                remove_marker_if ~parent ~name j;
                match claim ~parent ~name id with
                  | `Won -> `Reclaimed
                  | `Taken j -> `Lost j)
            | `File | `Unclassifiable ->
                Fail.raise_ Fail.Exists "%s is held by a file" name)

  (* data-model §6.4: the anchor first is the commit point; the marker's
     create-if-absent decides the name. *)
  let rec place ?(rounds = 8) id ~parent ~name =
    write_anchor id ~parent ~name;
    let k = slot parent name in
    let body = Folder.marker_body { name; id } in
    let holder =
      match store.put_if_absent k body with
        | Store.Won -> Some body
        | Held b -> Some b
    in
    let holder =
      match Option.map Folder.classify_marker holder with
        | Some (`Marker _) -> holder
        | _ -> store.get_opt k
    in
    match Option.map (classify_slot parent name) holder with
      | None ->
          if rounds > 0 then place ~rounds:(rounds - 1) id ~parent ~name
          else Fail.raise_ Fail.Load "placement of %s keeps failing" name
      | Some (`Filed j) when Folder_id.equal j id -> `Placed
      | Some (`Filed j) -> `Taken j
      | Some (`Disowned j) ->
          remove_marker_if ~parent ~name j;
          if rounds > 0 then place ~rounds:(rounds - 1) id ~parent ~name
          else Fail.raise_ Fail.Load "placement of %s keeps failing" name
      | Some (`File | `Unclassifiable) -> `Taken_by_file

  let move id ~old:(op, on) ~parent ~name =
    match place id ~parent ~name with
      | `Placed ->
          if not (Folder_id.equal op parent && on = name) then
            remove_marker_if ~parent:op ~name:on id;
          `Placed
      | r -> r

  let trash id ~old:(op, on) ~path =
    let entry = Key.trash_entry d (Ids.short ()) in
    store.put entry (Folder.trash_body { name = on; id } ~path);
    write_anchor id ~parent:Folder_id.trash ~name:on;
    remove_marker_if ~parent:op ~name:on id

  let trash_entries () =
    List.filter_map
      (fun (e : Store.entry) ->
        match store.get_opt e.key with
          | Some b -> (
              match Folder.classify_marker b with
                | `Marker (m, path) -> Some (e, m, path)
                | _ -> None)
          | None -> None)
      (List.filter
         (fun (e : Store.entry) ->
           Key.is_child_of ~namespace:(Key.namespace d Folder_id.trash) e.key)
         (store.list_prefix (Key.namespace d Folder_id.trash)))

  let restore id ~parent ~name =
    match place id ~parent ~name with
      | `Placed ->
          List.iter
            (fun ((e : Store.entry), (m : Folder.marker), _) ->
              if Folder_id.equal m.id id then ignore (store.delete e.key))
            (trash_entries ());
          `Placed
      | r -> r

  let classify_child body =
    match Folder.classify_marker body with
      | `Marker (m, _) -> `Dir m
      | `Unclassifiable -> `Unclassifiable
      | `Not_marker -> (
          match Manifest.decode body with
            | Some m -> `File m
            | None -> `Unclassifiable)

  let entries_of ~id ~on_unusable listing bodies =
    let unusable u =
      match on_unusable with
        | Fail_on_unusable -> Some u
        | Skip report ->
            report u;
            None
    in
    let failure = ref None in
    let out =
      List.filter_map
        (fun ((e : Store.entry), body) ->
          match body with
            | None -> (
                match unusable (Unreadable (e.key, "listed but gone")) with
                  | Some u ->
                      if !failure = None then failure := Some u;
                      None
                  | None -> None)
            | Some b -> (
                match classify_child b with
                  | `Unclassifiable -> (
                      match on_unusable with
                        | Skip r ->
                            r (Unclassifiable e.key);
                            None
                        | Fail_on_unusable -> None)
                  | `File m ->
                      Some
                        {
                          key = e.key;
                          leaf_hash = Key.leaf e.key;
                          body = File m;
                        }
                  | `Dir m -> (
                      match placed m.id ~parent:id ~name:m.name with
                        | `Elsewhere a -> (
                            match on_unusable with
                              | Skip r ->
                                  r (Disowned (e.key, a));
                                  None
                              | Fail_on_unusable -> None)
                        | _ ->
                            Some
                              {
                                key = e.key;
                                leaf_hash = Key.leaf e.key;
                                body = Dir m;
                              })))
        (List.combine listing bodies)
    in
    match !failure with
      | Some u ->
          Fail.raise_ Fail.Corrupt "folder %s: %s" (Folder_id.to_string id)
            (describe_unusable u)
      | None -> out

  (* 02 §4.5: the listing is the truth; each child object is read and
     classified. *)
  let children ?(on_unusable = Fail_on_unusable) id =
    let ns = Key.namespace d id in
    let listing =
      List.filter
        (fun (e : Store.entry) -> Key.is_child_of ~namespace:ns e.key)
        (store.list_prefix ns)
    in
    let bodies = List.map snd (Store.read_many store listing) in
    entries_of ~id ~on_unusable listing bodies

  let find id names =
    let rec go id = function
      | [] -> `Folder id
      | [leaf] -> (
          match store.get_opt (slot id leaf) with
            | None -> `Missing
            | Some b -> (
                match classify_child b with
                  | `File m -> `File m
                  | `Dir m ->
                      if filed ~parent:id ~name:leaf m.id then `Folder m.id
                      else `Missing
                  | `Unclassifiable ->
                      Fail.corrupt "%s: unclassifiable body" leaf))
      | leaf :: rest -> (
          match store.get_opt (slot id leaf) with
            | None -> `Missing
            | Some b -> (
                match classify_child b with
                  | `Dir m when filed ~parent:id ~name:leaf m.id -> go m.id rest
                  | `Dir _ | `File _ -> `Missing
                  | `Unclassifiable ->
                      Fail.corrupt "%s: unclassifiable body" leaf))
    in
    go id names

  (* Depth first, each folder visited before its descent and [f] handed the real
     path of the containing folder; subfolders are fetched ahead, which leaves
     the visit order unchanged. A folder failing transiently under [Skip] is
     retried once after the walk. *)
  let fold_tree ?(on_unusable = Fail_on_unusable) ?(width = C.max_downloads) id
      ~root_path f acc =
    let slots = Rt.Semaphore.create (max 1 width) in
    let fetch id =
      Rt.async (fun () ->
          Rt.Semaphore.with_slot slots (fun () -> children ~on_unusable id))
    in
    let acc = ref acc and later = ref [] in
    let rec visit id path pending =
      match Rt.Promise.await pending with
        | entries ->
            List.iter (fun e -> acc := f !acc path e) entries;
            let dirs =
              List.filter_map
                (fun e ->
                  match e.body with
                    | Dir mk -> Some (mk.Folder.id, Names.join path mk.name)
                    | File _ -> None)
                entries
            in
            let fetched = List.map (fun (id, p) -> (id, p, fetch id)) dirs in
            List.iter (fun (id, p, pr) -> visit id p pr) fetched
        | exception (Fail.E fl as e) when Fail.retryable fl.kind -> (
            match on_unusable with
              | Skip _ -> later := (id, path) :: !later
              | Fail_on_unusable -> raise e)
    in
    visit id root_path (fetch id);
    List.iter
      (fun (id, path) ->
        match children ~on_unusable id with
          | entries -> List.iter (fun e -> acc := f !acc path e) entries
          | exception e -> (
              match on_unusable with
                | Skip r ->
                    r (Unreadable (Key.anchor d id, Printexc.to_string e))
                | Fail_on_unusable -> raise e))
      (List.rev !later);
    !acc
end
