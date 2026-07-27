(* Reading the backend's folder tree.

   Under the inode layout a folder's children all live under
   [manifests/<folder_id>/], and each object there is either a folder marker
   (naming a subfolder and pointing at its namespace) or a file manifest. The
   two are told apart only by their body, so every walk has to fetch each child
   and classify it — export rebuilding real paths, expire collecting a trashed
   subtree, the share server listing a shared folder. That step is here once.

   Each caller keeps its own fold: they want genuinely different things (paths,
   keys, sizes). What they share is knowing how to get from a folder id to its
   classified children — including how to name a child folder's namespace, which
   is not something to re-derive by taking a prefix apart. *)

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

  (* Direct children of a folder namespace, in listing order. An object that is
     neither a marker nor a clean manifest is skipped: it is mid-write, and no
     walk here can say anything about it.

     With [skip_errors], a child that cannot be fetched is skipped too — for a
     caller that would rather return a partial tree than none at all. Off by
     default: a walk that decides what to delete must not mistake a failed GET
     for an absent subtree.

     ponytail: one GET per child. Fine for ordinary folders; a folder with
     thousands of direct children pays that many round trips. *)
  let children ?(skip_errors = false) ~folder_id () =
    let* entries = St.list_namespace ~folder_id in
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

  (* Depth-first over the whole subtree under [folder_id]. [f acc rel entry] sees
     each entry with the real relative path of the folder holding it, [rel]
     starting from the caller's [rel] at the root. Folders are visited before
     they are descended into, so a caller collecting keys gets the marker too. *)
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
