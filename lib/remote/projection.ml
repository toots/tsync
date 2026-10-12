open Tsync_core

let project_width = 8

module Make (C : Context.S) = struct
  module R = Remote.Make (C)
  module T = Tree.Make (C)

  let d = C.domain
  let store = C.store
  let slot (p : Algebra.place) = Key.child d p.parent p.name

  let classify = function
    | None -> `Nothing
    | Some body -> (
        match Manifest.of_body body with
          | Some m -> `Manifest (m, body)
          | None -> (
              match Folder.classify_marker (Bigstring.to_string body) with
                | `Marker m -> `Marker m.id
                | `Unclassifiable | `Not_marker -> `Other))

  (* §6.1 Reads: what the slots of one pass hold, read together. *)
  let held_at places =
    let read = Hashtbl.create 64 in
    List.iter
      (fun (key, body) -> Hashtbl.replace read key (classify body))
      (Tsync_store.Store.read_keys store (List.map slot places));
    fun p ->
      match Hashtbl.find_opt read (slot p) with
        | Some holds -> holds
        | None -> invalid_arg "Projection: a slot that was not read"

  (* §6.1: a version is saved only of the content the command replaces, so an
     entry applied again saves no second one. *)
  let save_replaced ~write p held before =
    match (held, Option.bind before Log_entry.identity) with
      | `Manifest (m, body), Some identity
        when Log_entry.identity_of m = identity ->
          write (fun () -> R.save_version ~body (slot p))
      | _ -> ()

  let apply ?(width = project_width) ~before_write
      (commands : Log_entry.command list) =
    (* publication §4.6: once a check or a write fails nothing more is issued. *)
    let failed = Atomic.make None in
    let stopped () = Option.iter raise (Atomic.get failed) in
    let write f =
      stopped ();
      before_write ();
      f ()
    in
    let each f l =
      Rt.iter_bounded ~width
        (fun x ->
          stopped ();
          try f x
          with e ->
            Atomic.set failed (Some e);
            raise e)
        l
    in
    let leaving =
      List.filter_map
        (function
          | `File (p, before, None) -> Some (p, `File before)
          | `Folder (i, Some place, after) when after <> Some place ->
              Some (place, `Folder i)
          | _ -> None)
        commands
    in
    let held = held_at (List.map fst leaving) in
    each
      (fun (p, leaves) ->
        match (leaves, held p) with
          | `File before, (`Manifest _ as holds) ->
              save_replaced ~write p holds before;
              write (fun () -> ignore (store.delete (slot p)))
          | `Folder i, `Marker j when Folder_id.equal i j ->
              write (fun () -> ignore (store.delete (slot p)))
          | _ -> ())
      leaving;
    each
      (function
        | `Folder (i, _, Some (place : Algebra.place)) ->
            write (fun () ->
                store.put (Key.anchor d i)
                  (Bigstring.of_string
                     (Folder.anchor_body
                        { parent = place.parent; aname = place.name })))
        | _ -> ())
      commands;
    (* §6.1 Reads: the slot of a command that can save a version. *)
    let replaces : Log_entry.command -> Algebra.place option = function
      | `File (p, Some _, Some (Known _)) when C.versioning -> Some p
      | _ -> None
    in
    let held = held_at (List.filter_map replaces commands) in
    each
      (fun (c : Log_entry.command) ->
        match c with
          | `File (p, before, Some (Log_entry.Known m)) ->
              Option.iter
                (fun p -> save_replaced ~write p (held p) before)
                (replaces c);
              let m = if m.name = p.name then m else Manifest.rename m p.name in
              write (fun () -> R.put_manifest ~save:false (slot p) m)
          | `File (p, _, Some (Identity _ | Unknown)) ->
              Fail.corrupt "%s: an entry's value after is not a manifest" p.name
          | `Folder (i, _, Some place) ->
              write (fun () ->
                  store.put (slot place)
                    (Bigstring.of_string
                       (Folder.marker_body { name = place.name; id = i })))
          | _ -> ())
      commands;
    each
      (function
        | `Folder (i, _, None) ->
            write (fun () -> ignore (store.delete (Key.index d i)));
            write (fun () -> ignore (store.delete (Key.anchor d i)))
        | _ -> ())
      commands

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
