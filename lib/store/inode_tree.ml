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
     other. Module-level so the several walks of a domain share it rather than
     each holding its own idea of the bound. *)
  let default_slots =
    lazy (Lwt_bounded.create ~name:"tree reads" ~max:C.max_downloads ())

  let classify data =
    match Folder.marker_of_string data with
      | Some m -> Ok (Dir m)
      | None -> (
          match Manifest.of_string data with
            | m -> Ok (File m)
            | exception exn -> Error exn)

  (* ponytail: one GET per child. Fine for ordinary folders; a folder with
     thousands of direct children pays that many round trips. *)
  let children ?(on_unusable = `Fail) ?slots ~folder_id () =
    let slots =
      match slots with Some s -> s | None -> Lazy.force default_slots
    in
    let* entries = St.list_namespace ~folder_id in
    (* An empty namespace lists as its own directory key — a zero-byte object on
       S3, a real directory on a filesystem, where the GET below fails outright.
       It is not a child on either. *)
    let entries =
      List.filter
        (fun (e : Backend.file_entry) -> not (Key.is_dir e.Backend.key))
        entries
    in
    let report bkey reason =
      (match on_unusable with `Fail -> () | `Skip f -> f bkey reason);
      None
    in
    let fetch (e : Backend.file_entry) =
      let bkey = e.Backend.key in
      let attempt () =
        let+ data = St.get_object ~bkey in
        match classify data with
          | Ok body -> Some { bkey; body }
          | Error exn -> report bkey (`Unclassifiable exn)
      in
      match on_unusable with
        | `Fail -> attempt ()
        | `Skip _ ->
            Lwt.catch attempt (fun exn ->
                Lwt.return (report bkey (`Unreadable exn)))
    in
    Lwt_bounded.filter_map_with slots fetch entries

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
