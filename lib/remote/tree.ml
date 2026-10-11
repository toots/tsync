open Tsync_core
open Tsync_store

type body = Dir of Folder.marker | File of Manifest.t
type entry = { key : Key.t; leaf_hash : string; body : body }

type unusable =
  | Unreadable of Key.t * string
  | Unclassifiable of Key.t
  | Disowned of Key.t * Folder.anchor option

type on_unusable = Fail_on_unusable | Skip of (unusable -> unit)

let describe_unusable = function
  | Unreadable (k, why) ->
      Printf.sprintf "%s: unreadable (%s)" (Key.to_string k) why
  | Unclassifiable k -> Printf.sprintf "%s: unclassifiable" (Key.to_string k)
  | Disowned (k, Some a) ->
      Printf.sprintf "%s: disowned by its anchor (%s/%s)" (Key.to_string k)
        (Folder_id.to_string a.parent)
        a.aname
  | Disowned (k, None) ->
      Printf.sprintf "%s: its folder has no anchor" (Key.to_string k)

module Make (C : Context.S) = struct
  let d = C.domain
  let store = C.store

  (* Markers, anchors and manifests are small; they cross as strings. *)
  let get k = Option.map Bigstring.to_string (store.get_opt k)
  let anchor id = Option.bind (get (Key.anchor d id)) Folder.decode_anchor

  let placed id ~parent ~name =
    match anchor id with
      | None -> `Unanchored
      | Some a when Folder_id.equal a.parent parent && a.aname = name -> `Here
      | Some a -> `Elsewhere a

  (* data-model §6.2: a marker is filed iff its folder's anchor names its
     slot; a marker whose folder has no anchor is disowned. *)
  let filed ~parent ~name id = placed id ~parent ~name = `Here
  let slot parent name = Key.child d parent name

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
                      let disowned anchor =
                        match on_unusable with
                          | Skip r ->
                              r (Disowned (e.key, anchor));
                              None
                          | Fail_on_unusable -> None
                      in
                      match placed m.id ~parent:id ~name:m.name with
                        | `Elsewhere a -> disowned (Some a)
                        | `Unanchored -> disowned None
                        | `Here ->
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

  (* 02 §2.10: with two readable members a listing and an index may come from
     different stores, so only a domain with one reads or writes indexes. *)
  let indexing () = List.length (Composite.readable C.composite) = 1

  let read_index (listed : Store.entry list) id =
    let key = Key.index d id in
    match
      List.find_opt (fun (e : Store.entry) -> Key.equal e.key key) listed
    with
      | Some e when e.size <= Folder_index.max_bytes && indexing () -> (
          match Option.bind (get key) Folder_index.decode with
            | Some entries ->
                let t = Hashtbl.create (List.length entries) in
                List.iter
                  (fun (x : Folder_index.entry) -> Hashtbl.replace t x.key x)
                  entries;
                t
            | None -> Hashtbl.create 0)
      | _ -> Hashtbl.create 0

  (* 02 §4.5: the listing is the truth; each child object is read and
     classified. *)
  let children ?(on_unusable = Fail_on_unusable) ?(write_index = false) id =
    let ns = Key.namespace d id in
    let listed = store.list_prefix ns in
    let listing =
      List.filter
        (fun (e : Store.entry) -> Key.is_child_of ~namespace:ns e.key)
        listed
    in
    let index = read_index listed id in
    let from_index (e : Store.entry) =
      match (e.etag, Hashtbl.find_opt index (Key.to_string e.key)) with
        | Some tag, Some x when x.etag = tag -> Some x.body
        | _ -> None
    in
    let need = List.filter (fun e -> from_index e = None) listing in
    let read = Hashtbl.create (List.length need) in
    List.iter
      (fun (k, b) ->
        Hashtbl.replace read (Key.to_string k)
          (Option.map Bigstring.to_string b))
      (Store.read_many store need);
    let bodies =
      List.map
        (fun (e : Store.entry) ->
          match from_index e with
            | Some b -> Some b
            | None -> Option.join (Hashtbl.find_opt read (Key.to_string e.key)))
        listing
    in
    let n = List.length listing in
    let served = n - List.length need in
    if
      write_index && indexing () && n > 1
      && n <= Folder_index.max_children
      && served * 4 < n * 3
    then (
      let entries =
        List.filter_map
          (fun ((e : Store.entry), b) ->
            match (e.etag, b) with
              | Some etag, Some body ->
                  Some { Folder_index.key = Key.to_string e.key; etag; body }
              | _ -> None)
          (List.combine listing bodies)
      in
      try
        store.put (Key.index d id)
          (Bigstring.of_string (Folder_index.encode entries))
      with e when not (Rt.is_cancelled e) ->
        Log.debug "folder index of %s not written: %s" (Folder_id.to_string id)
          (Printexc.to_string e));
    entries_of ~id ~on_unusable listing bodies

  let find id names =
    let rec go id = function
      | [] -> `Folder id
      | [leaf] -> (
          match get (slot id leaf) with
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
          match get (slot id leaf) with
            | None -> `Missing
            | Some b -> (
                match classify_child b with
                  | `Dir m when filed ~parent:id ~name:leaf m.id -> go m.id rest
                  | `Dir _ | `File _ -> `Missing
                  | `Unclassifiable ->
                      Fail.corrupt "%s: unclassifiable body" leaf))
    in
    go id names

  (* Depth first over an explicit stack, each folder visited before its descent
     and [f] handed the real path of the containing folder, with only the next
     [width] folders fetched ahead so at most that many listings wait in memory.

     A folder failing transiently under [Skip] is walked again once after the
     walk, its subtree with it. *)
  let fold_tree ?(on_unusable = Fail_on_unusable) ?(width = C.max_downloads)
      ?write_index id ~root_path f acc =
    let width = max 1 width in
    let fetch id = Rt.async (fun () -> children ~on_unusable ?write_index id) in
    let acc = ref acc and later = ref [] in
    let rec prefetch n = function
      | [] -> ()
      | _ when n = 0 -> ()
      | (id, _, (p : _ option ref)) :: rest ->
          if !p = None then p := Some (fetch id);
          prefetch (n - 1) rest
    in
    let rec loop ~last = function
      | [] -> ()
      | (id, path, p) :: rest as stack -> (
          prefetch width stack;
          let pending = Option.get !p in
          match Rt.Promise.await pending with
            | entries ->
                List.iter (fun e -> acc := f !acc path e) entries;
                let dirs =
                  List.filter_map
                    (fun e ->
                      match e.body with
                        | Dir mk ->
                            Some
                              (mk.Folder.id, Names.join path mk.name, ref None)
                        | File _ -> None)
                    entries
                in
                loop ~last (dirs @ rest)
            | exception (Fail.E fl as e) when Fail.retryable fl.kind && not last
              -> (
                match on_unusable with
                  | Skip _ ->
                      later := (id, path) :: !later;
                      loop ~last rest
                  | Fail_on_unusable -> raise e)
            | exception e when last && not (Rt.is_cancelled e) -> (
                match on_unusable with
                  | Skip r ->
                      r (Unreadable (Key.anchor d id, Printexc.to_string e));
                      loop ~last rest
                  | Fail_on_unusable -> raise e))
    in
    loop ~last:false [(id, root_path, ref None)];
    loop ~last:true
      (List.rev_map (fun (id, path) -> (id, path, ref None)) !later);
    !acc
end
