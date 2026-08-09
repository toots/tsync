(* Reading the backend's folder tree.

   A folder's children live under [manifests/<folder_id>/], each object either a
   folder marker (naming a subfolder and pointing at its namespace) or a file
   manifest, told apart only by their body. Callers keep their own folds — they
   want different things — and share only that classification step. *)

open Lwt.Syntax

type body = Dir of Folder.marker | File of Manifest.t
type entry = { bkey : string; body : body }

module Make (C : Conf.S) = struct
  module St = Store.Make (C) (Layout.Inode.Make (C))

  let namespace_prefix folder_id = C.domain_prefix ^ folder_id ^ "/"

  let classify data =
    match Folder.marker_of_string data with
      | Some m -> Some (Dir m)
      | None -> (
          match Manifest.of_string data with
            | m -> Some (File m)
            | exception _ -> None)

  (* An object that is neither a marker nor a clean manifest is mid-write and is
     skipped. [skip_errors] also skips a child that cannot be fetched, for a
     caller preferring a partial tree; off by default, since a walk deciding what
     to delete must not mistake a failed GET for an absent subtree.

     ponytail: one GET per child. Fine for ordinary folders; a folder with
     thousands of direct children pays that many round trips. *)
  let children ?(skip_errors = false) ~folder_id () =
    let* entries = St.list_namespace ~folder_id in
    (* An empty namespace lists as its own directory key — a zero-byte object on
       S3, a real directory on a filesystem, where the GET below fails outright.
       It is not a child on either. *)
    let entries =
      List.filter
        (fun (e : Backend.file_entry) -> not (Key.is_dir e.Backend.key))
        entries
    in
    Lwt_list.filter_map_s
      (fun (e : Backend.file_entry) ->
        let fetch () =
          let+ data = St.get_object ~bkey:e.Backend.key in
          Option.map
            (fun body -> { bkey = e.Backend.key; body })
            (classify data)
        in
        if skip_errors then Lwt.catch fetch (fun _ -> Lwt.return_none)
        else fetch ())
      entries

  (* [f acc rel entry] sees each entry with the real relative path of the folder
     holding it. A folder is visited before it is descended into, so a caller
     collecting keys gets the marker too. *)
  let fold_tree ?skip_errors ~folder_id ~rel f acc =
    let rec walk folder_id rel acc =
      let* entries = children ?skip_errors ~folder_id () in
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
