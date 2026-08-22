open Lwt.Syntax

type outcome = Restored | Not_in_trash | Parent_unknown

module Make (C : Conf.S) = struct
  module L = Layout.Inode.Make (C)
  module St = Store.Make (C) (L)
  module B = (val C.store : Backend.S)

  (* A directory key is the namespace itself, not one of the markers filed in
     it. *)
  let markers () =
    let+ entries =
      B.list_prefix ~prefix:(C.domain_prefix ^ Folder.trash_id ^ "/") ()
    in
    List.filter
      (fun (e : Backend.file_entry) -> not (Key.is_dir e.Backend.key))
      entries

  let list () =
    let* markers = markers () in
    Lwt_list.filter_map_s
      (fun (e : Backend.file_entry) ->
        let+ data = B.get ~key:e.Backend.key () in
        Folder.trash_path_of_string (Chunk.to_string data))
      markers

  let find path =
    let* markers = markers () in
    let+ found =
      Lwt_list.filter_map_s
        (fun (e : Backend.file_entry) ->
          let+ data = B.get ~key:e.Backend.key () in
          let data = Chunk.to_string data in
          match
            (Folder.trash_path_of_string data, Folder.marker_of_string data)
          with
            | Some p, Some m when p = path -> Some (e.Backend.key, m)
            | _ -> None)
        markers
    in
    match found with [] -> None | hit :: _ -> Some hit

  let restore path =
    let* found = find path in
    match found with
      | None -> Lwt.return Not_in_trash
      | Some (trash_key, m) -> (
          (* Where it goes back is filed under its parent's namespace, so a
             client that has never resolved the parent has no key to write and
             must sync before it can put anything back. *)
          let* new_key = L.folder_marker_key (C.domain_prefix ^ path) in
          match new_key with
            | None -> Lwt.return Parent_unknown
            | Some new_key ->
                (* O(1): the subtree is untouched. The local mirror copy is
                   rebuilt by a later full sync. *)
                let marker =
                  Folder.marker_to_string
                    { Folder.name = m.Folder.name; id = m.Folder.id }
                in
                let* () = St.put_raw ~bkey:new_key ~data:marker in
                let+ () = St.delete_raw ~bkey:trash_key in
                Restored)
end
