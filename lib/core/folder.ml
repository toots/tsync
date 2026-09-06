type marker = { name : string; id : string }

let marker_to_string { name; id } =
  Yojson.Basic.to_string
    (`Assoc [("dir", `Bool true); ("name", `String name); ("id", `String id)])

(* A trashed folder's marker additionally records its original path, so it can be
   listed and restored. Extra fields are ignored by {!marker_of_string}. *)
let trash_marker_to_string ~name ~id ~path =
  Yojson.Basic.to_string
    (`Assoc
       [
         ("dir", `Bool true);
         ("name", `String name);
         ("id", `String id);
         ("path", `String path);
       ])

let trash_path_of_string data =
  match Yojson.Basic.from_string data with
    | `Assoc fields -> (
        match List.assoc_opt "path" fields with
          | Some (`String s) -> Some s
          | _ -> None)
    | _ | (exception _) -> None

type anchor = { parent : string; name : string }

let anchor_to_string { parent; name } =
  Yojson.Basic.to_string
    (`Assoc [("parent", `String parent); ("name", `String name)])

(* No ["dir"] field, so {!marker_of_string} never takes an anchor for a marker. *)
let anchor_of_string data =
  match Yojson.Basic.from_string data with
    | `Assoc fields -> (
        match
          (List.assoc_opt "parent" fields, List.assoc_opt "name" fields)
        with
          | Some (`String parent), Some (`String name) -> Some { parent; name }
          | _ -> None)
    | _ -> None
    | exception _ -> None

(* [Some marker] when [data] is a folder marker; [None] for a file manifest. *)
let marker_of_string data =
  match Yojson.Basic.from_string data with
    | `Assoc fields when List.assoc_opt "dir" fields = Some (`Bool true) ->
        let str k =
          match List.assoc_opt k fields with Some (`String s) -> s | _ -> ""
        in
        Some { name = str "name"; id = str "id" }
    | _ -> None
    | exception _ -> None
