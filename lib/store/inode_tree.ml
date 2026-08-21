(* Reading the backend's folder tree.

   A folder's children live under [manifests/<folder_id>/], each object either a
   folder marker (naming a subfolder and pointing at its namespace) or a file
   manifest, told apart only by their body. Callers keep their own folds — they
   want different things — and share only that classification step. *)

open Lwt.Syntax

type body = Dir of Folder.marker | File of Manifest.t
type entry = { bkey : string; body : body }
type unusable = [ `Unreadable of exn | `Unclassifiable of exn ]
type on_unusable = [ `Fail | `Skip of string -> unusable -> unit ]

module Make (C : Conf.S) = struct
  module St = Store.Make (C) (Layout.Inode.Make (C))

  let namespace_prefix folder_id = C.domain_prefix ^ folder_id ^ "/"

  (* The domain's download budget, since a child is one object read like any
     other, and shared so a resync, a mirror and a share server in one process
     bound each other rather than each holding a budget of its own. *)
  let default_slots =
    lazy
      (Lwt_bounded.shared ~key:C.domain_prefix ~name:"tree reads"
         ~max:C.max_downloads ())

  let classify data =
    match Folder.marker_of_string data with
      | Some m -> Ok (Dir m)
      | None -> (
          match Manifest.of_string data with
            | m -> Ok (File m)
            | exception exn -> Error exn)

  let children ?(on_unusable = `Fail) ?slots ~folder_id () =
    let slots =
      match slots with Some s -> s | None -> Lazy.force default_slots
    in
    let* listed = St.list_namespace ~folder_id in
    (* An empty namespace lists as its own directory key — a zero-byte object on
       S3, a real directory on a filesystem, where the read below fails
       outright. It is not a child on either. *)
    let entries =
      List.filter
        (fun (e : Backend.file_entry) -> not (Key.is_dir e.Backend.key))
        listed
    in
    (* A key listed and then gone: the listing and the reads that follow it are
       not one act, and to a walk that is a child it could not read rather than
       one that was never there. *)
    let vanished bkey =
      Backend.failed ~kind:Backend.Permanent ~op:"get" ("not found: " ^ bkey)
    in
    let in_one_batch () =
      let+ answered = St.get_objects ~slots ~entries () in
      List.map
        (fun (bkey, data) ->
          match data with
            | Some data -> (bkey, Ok data)
            | None -> (bkey, Error (vanished bkey)))
        answered
    in
    (* A batch is all or nothing, so one object that cannot be read would cost
       every sibling it was asked for alongside. Only a caller that wanted the
       rest pays this second pass. *)
    let key_by_key () =
      Lwt_bounded.map_with slots
        (fun (e : Backend.file_entry) ->
          let bkey = e.Backend.key in
          Lwt.catch
            (fun () ->
              let+ data = St.get_object ~bkey in
              (bkey, Ok data))
            (fun exn -> Lwt.return (bkey, Error exn)))
        entries
    in
    let* read =
      match on_unusable with
        | `Fail -> in_one_batch ()
        | `Skip _ -> Lwt.catch in_one_batch (fun _ -> key_by_key ())
    in
    (* Classified once, then reported and filtered from the same list: two
       passes over [classify] would be the same rule answered twice. *)
    let outcome (bkey, data) =
      match data with
        | Error exn -> (bkey, Error (`Unreadable exn))
        | Ok data -> (
            match classify data with
              | Ok body -> (bkey, Ok { bkey; body })
              | Error exn -> (bkey, Error (`Unclassifiable exn)))
    in
    let outcomes = List.map outcome read in
    let kept = List.filter_map (fun (_, r) -> Result.to_option r) outcomes in
    match on_unusable with
      | `Fail -> (
          (* An unclassifiable body is a write in flight and is skipped; a read
             that failed is not, and a walk deciding what to delete must not
             take one for an absent subtree. *)
          match
            List.find_map
              (function _, Error (`Unreadable exn) -> Some exn | _ -> None)
              outcomes
          with
            | Some exn -> Lwt.fail exn
            | None -> Lwt.return kept)
      | `Skip f ->
          List.iter
            (function _, Ok _ -> () | bkey, Error r -> f bkey r)
            outcomes;
          Lwt.return kept

  (* [f acc rel entry] sees each entry with the real relative path of the folder
     holding it. A folder is visited before it is descended into, so a caller
     collecting keys gets the marker too. *)
  let fold_tree ?on_unusable ?slots ~folder_id ~rel f acc =
    let rec walk folder_id rel acc =
      let* entries = children ?on_unusable ?slots ~folder_id () in
      Lwt_list.fold_left_s
        (fun acc entry ->
          let* acc = f acc rel entry in
          match entry.body with
            | Dir m -> walk m.Folder.id (Key.join rel m.Folder.name) acc
            | File _ -> Lwt.return acc)
        acc entries
    in
    walk folder_id rel acc
end
