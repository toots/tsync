open Tsync_core

type t =
  | Put of { path : string; size : int }
  | Delete of string
  | Mkdir of { path : string; id : Folder_id.t option }
  | Rmdir of { path : string; id : Folder_id.t option }
  | Rename of {
      dst : string;
      src : string;
      is_dir : bool;
      size : int option;
      id : Folder_id.t option;
    }

let opt k f = function Some v -> [(k, f v)] | None -> []

let to_json = function
  | Put { path; size } ->
      `Assoc [("op", `String "put"); ("key", `String path); ("size", `Int size)]
  | Delete p -> `Assoc [("op", `String "delete"); ("key", `String p)]
  | Mkdir { path; id } ->
      `Assoc
        ([("op", `String "mkdir"); ("key", `String path)]
        @ opt "id" (fun i -> `String (Folder_id.to_string i)) id)
  | Rmdir { path; id } ->
      `Assoc
        ([("op", `String "rmdir"); ("key", `String path)]
        @ opt "id" (fun i -> `String (Folder_id.to_string i)) id)
  | Rename { dst; src; is_dir; size; id } ->
      `Assoc
        ([
           ("op", `String "rename");
           ("key", `String dst);
           ("src", `String src);
           ("is_dir", `Bool is_dir);
         ]
        @ opt "size" (fun s -> `Int s) size
        @ opt "id" (fun i -> `String (Folder_id.to_string i)) id)

let to_string op = Yojson.Safe.to_string (to_json op)

exception Bad of string

let valid_path p = p <> "" && Names.valid_path p

(* 03 §2.9: an unknown op is ignored; a known op with a missing or ill-typed
   field is [Bad]. *)
let of_json = function
  | `Assoc f -> (
      let bad what = raise (Bad what) in
      let path n =
        match List.assoc_opt n f with
          | Some (`String p) when valid_path p -> p
          | _ -> bad ("a valid " ^ n)
      in
      let id () =
        match List.assoc_opt "id" f with
          | None | Some `Null -> None
          | Some (`String s) -> (
              match Folder_id.of_string s with
                | Some id -> Some id
                | None -> bad "a folder id")
          | _ -> bad "a folder id"
      in
      let size n =
        match List.assoc_opt n f with
          | Some (`Int s) when s >= 0 -> Some s
          | None -> None
          | _ -> bad n
      in
      match List.assoc_opt "op" f with
        | Some (`String "put") ->
            Some
              (Put
                 {
                   path = path "key";
                   size =
                     (match size "size" with Some s -> s | None -> bad "size");
                 })
        | Some (`String "delete") -> Some (Delete (path "key"))
        | Some (`String "mkdir") ->
            Some (Mkdir { path = path "key"; id = id () })
        | Some (`String "rmdir") ->
            Some (Rmdir { path = path "key"; id = id () })
        | Some (`String "rename") ->
            let is_dir =
              match List.assoc_opt "is_dir" f with
                | Some (`Bool b) -> b
                | None -> false
                | _ -> bad "is_dir"
            in
            Some
              (Rename
                 {
                   dst = path "key";
                   src = path "src";
                   is_dir;
                   size = size "size";
                   id = id ();
                 })
        | Some (`String _) -> None
        | _ -> bad "an op")
  | _ -> raise (Bad "an object")

let paths = function
  | Put { path; _ } | Delete path | Mkdir { path; _ } | Rmdir { path; _ } ->
      [path]
  | Rename { dst; src; _ } -> [dst; src]

let list_to_json ops = `List (List.map to_json ops)

(* In an applied-log line an op the reader cannot decode is dropped, not the
   line. *)
let list_of_json_lenient = function
  | `List l ->
      Some (List.filter_map (fun j -> try of_json j with Bad _ -> None) l)
  | _ -> None
