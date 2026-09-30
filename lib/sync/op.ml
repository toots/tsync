open Tsync_core

type t =
  | Put of { path : string; size : int; base : string option }
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
  | Put { path; size; base } ->
      `Assoc
        ([("op", `String "put"); ("key", `String path); ("size", `Int size)]
        @ opt "base" (fun b -> `String b) base)
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

(* 03 §2.3: an unknown op is ignored; a known op with a missing or ill-typed
   field makes the whole entry CORRUPT. *)
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
            let base =
              match List.assoc_opt "base" f with
                | None -> None
                | Some (`String b)
                  when String.length b = 16
                       && String.for_all Names.is_hexlower b ->
                    Some b
                | _ -> bad "a base"
            in
            Some
              (Put
                 {
                   path = path "key";
                   size =
                     (match size "size" with Some s -> s | None -> bad "size");
                   base;
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

let is_put = function Put _ -> true | _ -> false

let encode_entry ops =
  String.concat "" (List.map (fun op -> to_string op ^ "\n") ops)

let decode_entry body =
  let lines =
    List.filter
      (fun l -> l <> "")
      (List.map String.trim (String.split_on_char '\n' body))
  in
  try
    Ok
      (List.filter_map
         (fun l ->
           match Yojson.Safe.from_string l with
             | j -> of_json j
             | exception Yojson.Json_error _ -> raise (Bad "a JSON object"))
         lines)
  with Bad what -> Error what

let list_to_json ops = `List (List.map to_json ops)

(* In an applied-log line an op the reader cannot decode is dropped, not the
   line. *)
let list_of_json_lenient = function
  | `List l ->
      Some (List.filter_map (fun j -> try of_json j with Bad _ -> None) l)
  | _ -> None
