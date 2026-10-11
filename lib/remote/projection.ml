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
                  | `Marker (m, _) -> `Marker m.id
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

  let fold ?width f acc =
    let on_unusable =
      Tree.Skip
        (function
        | Tree.Unreadable (key, _) as u when Key.is_internal_leaf (Key.leaf key)
          ->
            Fail.raise_ Fail.Link "state read: %s" (Tree.describe_unusable u)
        | u -> Log.debug "state read: %s" (Tree.describe_unusable u))
    in
    T.fold_tree ~on_unusable ?width ~write_index:true Folder_id.root
      ~root_path:""
      (fun acc _ (e : Tree.entry) ->
        match Folder_id.of_string (Key.parent_segment e.key) with
          | None -> acc
          | Some parent -> (
              match e.body with
                | File m -> f acc (`File ({ Algebra.parent; name = m.name }, m))
                | Dir m ->
                    f acc (`Folder (m.id, { Algebra.parent; name = m.name }))))
      acc
end
