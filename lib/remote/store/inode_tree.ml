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

  (* An index pairs a body with the version the listing gave it, so both have to
     come from the same store. A domain's stores are presented as one, and a
     read falls through to the next where the listing does not: with more than
     one place a read can land, a body answered by the second store would be
     recorded under the first's version and served in its place ever after.

     Read as well as written under this, so a domain that gains a second
     readable store stops trusting what it wrote while it had one. *)
  let one_source =
    lazy
      (List.length
         (List.filter
            (fun (m : Backend.member) -> m.Backend.readable)
            C.members)
      = 1)

  let classify data =
    match Folder.marker_of_string data with
      | Some m -> Ok (Dir m)
      | None -> (
          match Manifest.of_string data with
            | m -> Ok (File m)
            | exception exn -> Error exn)

  (* The index is listed with the children it describes, so having it costs no
     round trip to discover. An unreadable one is one we do not have. *)
  let read_index ~slots listed =
    if
      (not (Lazy.force one_source))
      || not
           (List.exists
              (fun (e : Backend.file_entry) ->
                Stored_key.is_index_key e.Backend.key)
              listed)
    then Lwt.return Folder_index.empty
    else
      Lwt.catch
        (fun () ->
          let indexed =
            List.filter
              (fun (e : Backend.file_entry) ->
                Stored_key.is_index_key e.Backend.key
                && e.Backend.size <= Folder_index.max_bytes)
              listed
          in
          let+ answered = St.get_objects ~slots ~entries:indexed () in
          match answered with
            | [(_, Some body)] -> Folder_index.of_string body
            | _ -> Folder_index.empty)
        (fun _ -> Lwt.return Folder_index.empty)

  (* Held against the version the listing reports now, so an entry the index
     covers is one the store still has the same body for. *)
  let cached index (e : Backend.file_entry) =
    match e.Backend.etag with
      | None -> None
      | Some etag -> Folder_index.find index ~key:e.Backend.key ~etag

  (* Written by whoever has just read the whole folder anyway, and only when
     enough of it was not covered to pay for the round trip. Best effort: a
     read must not fail because its cache could not be refreshed, and a caller
     serving a read-only domain simply never asks. *)
  let write_index ~folder_id ~index ~entries ~body_of =
    if not (Lazy.force one_source) then Lwt.return_unit
    else (
      let indexable =
        List.filter
          (fun (e : Backend.file_entry) -> e.Backend.etag <> None)
          entries
      in
      let covered =
        List.length (List.filter (fun e -> cached index e <> None) indexable)
      in
      if
        not (Folder_index.worth_writing ~covered ~total:(List.length indexable))
      then Lwt.return_unit
      else (
        let bodies =
          List.filter_map
            (fun e -> Option.map (fun b -> (e, b)) (body_of e))
            indexable
        in
        Lwt.catch
          (fun () ->
            St.put_raw
              ~bkey:(C.domain_prefix ^ Stored_key.index_key ~folder_id)
              ~data:(Folder_index.of_bodies bodies))
          (fun exn ->
            Log.warn "folder index %s: %s" folder_id (Printexc.to_string exn);
            Lwt.return_unit)))

  let children ?(on_unusable = `Fail) ?(refresh_index = false)
      ?(on_index = fun _ -> ()) ?slots ~folder_id () =
    let slots =
      match slots with Some s -> s | None -> Lazy.force default_slots
    in
    let* listed = St.list_namespace ~folder_id in
    List.iter
      (fun (e : Backend.file_entry) ->
        if Stored_key.is_index_key e.Backend.key then on_index e.Backend.key)
      listed;
    let entries =
      List.filter
        (fun (e : Backend.file_entry) ->
          Stored_key.is_child_object e.Backend.key)
        listed
    in
    (* A key listed and then gone: the listing and the reads that follow it are
       not one act, and to a walk that is a child it could not read rather than
       one that was never there. *)
    let vanished bkey =
      Retry.failed ~kind:Retry.Permanent ~op:"get" ("not found: " ^ bkey)
    in
    let in_one_batch () =
      let* index = read_index ~slots listed in
      let wanted = List.filter (fun e -> cached index e = None) entries in
      let* answered = St.get_objects ~slots ~entries:wanted () in
      let fetched = Hashtbl.create (List.length answered) in
      List.iter (fun (bkey, data) -> Hashtbl.replace fetched bkey data) answered;
      let body_of (e : Backend.file_entry) =
        match cached index e with
          | Some body -> Some body
          | None -> (
              match Hashtbl.find_opt fetched e.Backend.key with
                | Some data -> data
                | None -> None)
      in
      let+ () =
        if refresh_index then write_index ~folder_id ~index ~entries ~body_of
        else Lwt.return_unit
      in
      List.map
        (fun (e : Backend.file_entry) ->
          let bkey = e.Backend.key in
          match body_of e with
            | Some data -> (bkey, Ok data)
            | None -> (bkey, Error (vanished bkey)))
        entries
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
  let fold_tree ?on_unusable ?refresh_index ?on_index ?slots ~folder_id ~rel f
      acc =
    let rec walk folder_id rel acc =
      let* entries =
        children ?on_unusable ?refresh_index ?on_index ?slots ~folder_id ()
      in
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
