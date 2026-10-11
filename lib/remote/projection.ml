open Tsync_core

module Make (C : Context.S) = struct
  module R = Remote.Make (C)
  module T = Tree.Make (C)

  let d = C.domain
  let store = C.store
  let slot (p : Algebra.place) = Key.child d p.parent p.name

  let held p =
    match store.get_opt (slot p) with
      | None -> `Nothing
      | Some body -> (
          match Manifest.of_body body with
            | Some m -> `Manifest m
            | None -> (
                match Folder.classify_marker (Bigstring.to_string body) with
                  | `Marker m -> `Marker m.id
                  | `Unclassifiable | `Not_marker -> `Other))

  (* §6.1: a version is saved only of the content the command replaces, so an
     entry applied again saves no second one. *)
  let save_replaced ~write p before =
    match (held p, Option.bind before Log_entry.identity) with
      | `Manifest m, Some identity when Log_entry.identity_of m = identity ->
          write (fun () -> R.save_version (slot p))
      | _ -> ()

  let apply ~before_write (commands : Log_entry.command list) =
    let write f =
      before_write ();
      f ()
    in
    let each f = List.iter f commands in
    each (function
      | `File (p, before, None) -> (
          match held p with
            | `Manifest _ ->
                save_replaced ~write p before;
                write (fun () -> ignore (store.delete (slot p)))
            | `Marker _ | `Other | `Nothing -> ())
      | `Folder (i, Some place, after) when after <> Some place -> (
          match held place with
            | `Marker j when Folder_id.equal i j ->
                write (fun () -> ignore (store.delete (slot place)))
            | _ -> ())
      | _ -> ());
    each (function
      | `Folder (i, _, Some (place : Algebra.place)) ->
          write (fun () ->
              store.put (Key.anchor d i)
                (Bigstring.of_string
                   (Folder.anchor_body
                      { parent = place.parent; aname = place.name })))
      | _ -> ());
    each (function
      | `File (p, before, Some (Log_entry.Known m)) ->
          save_replaced ~write p before;
          let m = if m.name = p.name then m else Manifest.rename m p.name in
          write (fun () -> R.put_manifest ~save:false (slot p) m)
      | `File (p, _, Some (Identity _ | Unknown)) ->
          Fail.corrupt "%s: an entry's value after is not a manifest" p.name
      | `Folder (i, _, Some place) ->
          write (fun () ->
              store.put (slot place)
                (Bigstring.of_string
                   (Folder.marker_body { name = place.name; id = i })))
      | _ -> ());
    each (function
      | `Folder (i, _, None) ->
          write (fun () -> ignore (store.delete (Key.index d i)));
          write (fun () -> ignore (store.delete (Key.anchor d i)))
      | _ -> ())

  (* 05 §4.7: an enumeration of the manifest area, so a folder is found by
     its namespace wherever its marker is. *)
  let namespaces () =
    let ids = Hashtbl.create 1024 in
    Hashtbl.replace ids Folder_id.root ();
    List.iter
      (fun (e : Tsync_store.Store.entry) ->
        Option.iter
          (fun id -> Hashtbl.replace ids id ())
          (Key.folder_of_namespace_key d e.key))
      (store.list_prefix (Key.manifests d));
    Hashtbl.fold (fun id () acc -> id :: acc) ids []

  let fold ?(width = C.max_downloads) f acc =
    let on_unusable =
      Tree.Skip (fun u -> Log.debug "state read: %s" (Tree.describe_unusable u))
    in
    let acc = ref acc and m = Mutex.create () in
    let emit record = Mutex.protect m (fun () -> acc := f !acc record) in
    Rt.iter_bounded ~width:(max 1 width)
      (fun id ->
        if not (Folder_id.is_root id) then (
          match T.anchor id with
            | Some a ->
                emit
                  (`Folder (id, { Algebra.parent = a.parent; name = a.aname }))
            | None -> ());
        List.iter
          (fun (e : Tree.entry) ->
            match e.body with
              | File m ->
                  emit (`File ({ Algebra.parent = id; name = m.name }, m))
              | Dir _ -> ())
          (T.children ~on_unusable ~write_index:true id))
      (namespaces ());
    !acc
end
