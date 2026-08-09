(* Reserved namespace ids share the [.tsync-] sentinel prefix used for internal
   markers, so they never collide with a (random hex) folder id and read as
   internal. *)
let root_id = ".tsync-root"

(* A deleted folder's marker moves here, unreachable from root, so the subtree
   vanishes from listings and resync until [expire] drops it. *)
let trash_id = ".tsync-trash"

(* Minted at mkdir. *)
let new_id = Id.short

(* The dual-seed xxHash of the leaf name, matching the chunk-key convention:
   fixed length and filesystem-safe regardless of the real name. *)
let hash_name name = Xxhash.hash_hex name 0 ^ "-" ^ Xxhash.hash_hex name 1
let child_key ~folder_id name = folder_id ^ "/" ^ hash_name name

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
