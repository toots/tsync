type marker = { name : string; id : Folder_id.t }
type anchor = { parent : Folder_id.t; aname : string }

let marker_body m =
  Printf.sprintf {|{"dir":true,"name":%s,"id":%s}|}
    (Yojson.Safe.to_string (`String m.name))
    (Yojson.Safe.to_string (`String (Folder_id.to_string m.id)))

let trash_body m ~path =
  Printf.sprintf {|{"dir":true,"name":%s,"id":%s,"path":%s}|}
    (Yojson.Safe.to_string (`String m.name))
    (Yojson.Safe.to_string (`String (Folder_id.to_string m.id)))
    (Yojson.Safe.to_string (`String path))

let anchor_body a =
  Printf.sprintf {|{"parent":%s,"name":%s}|}
    (Yojson.Safe.to_string (`String (Folder_id.to_string a.parent)))
    (Yojson.Safe.to_string (`String a.aname))

let fields body =
  match Yojson.Safe.from_string body with
    | `Assoc f -> Some f
    | _ -> None
    | exception _ -> None

let str f n =
  match List.assoc_opt n f with Some (`String s) -> Some s | _ -> None

(* A body is a marker iff it is an object with "dir": true; one whose id is not
   a folder id is unclassifiable. *)
let classify_marker body =
  match fields body with
    | Some f when List.assoc_opt "dir" f = Some (`Bool true) -> (
        let name = Option.value ~default:"" (str f "name") in
        match Option.bind (str f "id") Folder_id.of_string with
          | Some id -> `Marker ({ name; id }, str f "path")
          | None -> `Unclassifiable)
    | _ -> `Not_marker

let decode_anchor body =
  match fields body with
    | Some f -> (
        match
          (Option.bind (str f "parent") Folder_id.of_string, str f "name")
        with
          | Some parent, Some aname -> Some { parent; aname }
          | _ -> None)
    | None -> None

let in_trash a = Folder_id.equal a.parent Folder_id.trash
