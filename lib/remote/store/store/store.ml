open Lwt.Syntax

module Make (C : Conf.S) (L : Layout.S) = struct
  module B = (val C.store : Backend.S)
  module Bb = Backend.Batched (B)

  (* Publishing may bring the folder into existence; every other operation
     resolves what is already there and treats an unknown folder as absent. *)
  let put_manifest ~key ~data =
    let* bk = L.ensure_manifest_key key in
    B.put ~key:bk ~data ()

  let get_manifest_state ~key =
    let* bk = L.manifest_key key in
    match bk with
      | None -> Lwt.return `Unresolved
      | Some bk -> (
          let+ body = B.get_opt ~key:bk () in
          match body with
            | None -> `Absent
            | Some body -> `Body (Bigstring.to_string body))

  let get_manifest_opt ~key =
    let+ state = get_manifest_state ~key in
    match state with `Body body -> Some body | `Absent | `Unresolved -> None

  let head_manifest ~key =
    let* bk = L.manifest_key key in
    match bk with None -> Lwt.return_none | Some bk -> B.head_opt ~key:bk ()

  let delete_manifest ~key =
    let* bk = L.manifest_key key in
    match bk with None -> Lwt.return_unit | Some bk -> B.delete ~key:bk ()

  (* The destination may be brought into existence; the source has to be there
     already or there is nothing to move. *)
  let copy_manifest ~src_key ~dst_key =
    let* src = L.manifest_key src_key in
    match src with
      | None -> Lwt.return_unit
      | Some src ->
          let* dst = L.ensure_manifest_key dst_key in
          let* () = B.copy ~src_key:src ~dst_key:dst () in
          B.delete ~key:src ()

  (* Records a directory under its parent's namespace so resync can rebuild the
     tree. No-op for layouts with no folder tree. *)
  let put_folder_marker ~key =
    let* m = L.ensure_folder_marker key in
    match m with
      | None -> Lwt.return_unit
      | Some (bkey, data) -> B.put ~key:bkey ~data:(Bigstring.of_string data) ()

  (* Direct children (file manifests and folder markers) of a folder namespace,
     and a raw object fetch — used by resync to walk the inode tree by id. *)
  let list_namespace ~folder_id =
    B.list_prefix
      ~prefix:
        (Stored_key.to_string
           (Stored_key.namespace ~prefix:C.domain_prefix ~folder_id))
      ()

  let get_object ~bkey =
    let+ body = B.get ~key:bkey () in
    Bigstring.to_string body

  let get_objects ?slots ~entries () =
    let+ answered = Bb.get_many ?slots ~entries () in
    List.map
      (fun (key, body) -> (key, Option.map Bigstring.to_string body))
      answered

  let delete_raw ~bkey = B.delete ~key:bkey ()
  let put_raw ~bkey ~data = B.put ~key:bkey ~data:(Bigstring.of_string data) ()
end
