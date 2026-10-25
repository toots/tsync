type t = {
  color : string option;
  icon : string option;
  modified : int;
  unknown : (string * Yojson.Safe.t) list;
}

let none = { color = None; icon = None; modified = 0; unknown = [] }

(* Ten hues readable on light and dark backgrounds, apart at a glance. *)
let palette =
  [
    "#2563eb";
    "#dc2626";
    "#16a34a";
    "#9333ea";
    "#ea580c";
    "#0d9488";
    "#db2777";
    "#ca8a04";
    "#4f46e5";
    "#475569";
  ]

(* §8.1: the key id's first byte picks it, so every machine agrees with nothing
   written. *)
let default_color ~key_id =
  let byte =
    match int_of_string_opt ("0x" ^ String.sub key_id 0 2) with
      | Some b -> b
      | None | (exception Invalid_argument _) -> 0
  in
  List.nth palette (byte mod List.length palette)

let color t ~key_id =
  match t.color with Some c -> c | None -> default_color ~key_id

let check_color c =
  let c = String.lowercase_ascii c in
  if
    String.length c = 7
    && c.[0] = '#'
    && String.for_all
         (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false)
         (String.sub c 1 6)
  then Ok c
  else Error "a colour is #rrggbb"

let icon_max_side = 256
let icon_max_bytes = 65536
let png_magic = "\x89PNG\r\n\x1a\n"

(* §8.1: a PNG is told by its signature and its IHDR, the first chunk. *)
let check_icon body =
  let be32 off =
    (Char.code body.[off] lsl 24)
    lor (Char.code body.[off + 1] lsl 16)
    lor (Char.code body.[off + 2] lsl 8)
    lor Char.code body.[off + 3]
  in
  if String.length body > icon_max_bytes then
    Error (Printf.sprintf "an icon is at most %d bytes" icon_max_bytes)
  else if
    String.length body < 24
    || String.sub body 0 8 <> png_magic
    || String.sub body 12 4 <> "IHDR"
  then Error "an icon is a PNG"
  else (
    let width = be32 16 and height = be32 20 in
    if width <> height then Error "an icon is square"
    else if width < 1 || width > icon_max_side then
      Error (Printf.sprintf "an icon is at most %d pixels a side" icon_max_side)
    else Ok body)

let to_string t =
  Yojson.Safe.to_string
    (`Assoc
       ((match t.color with Some c -> [("color", `String c)] | None -> [])
       @ (match t.icon with
         | Some i -> [("icon", `String (Base64.encode_string i))]
         | None -> [])
       @ [("modified", `Int t.modified)]
       @ t.unknown))

let ( let* ) = Result.bind

let of_string body =
  match Yojson.Safe.from_string body with
    | `Assoc l ->
        let* color =
          match List.assoc_opt "color" l with
            | None -> Ok None
            | Some (`String c) -> Result.map Option.some (check_color c)
            | Some _ -> Error "the colour is not a string"
        in
        let* icon =
          match List.assoc_opt "icon" l with
            | None -> Ok None
            | Some (`String b) -> (
                match Base64.decode b with
                  | Ok png -> Result.map Option.some (check_icon png)
                  | Error _ -> Error "the icon is not base64")
            | Some _ -> Error "the icon is not a string"
        in
        let modified =
          match List.assoc_opt "modified" l with Some (`Int m) -> m | _ -> 0
        in
        Ok
          {
            color;
            icon;
            modified;
            unknown = Members.unknown ~known:["color"; "icon"; "modified"] l;
          }
    | _ | (exception Yojson.Json_error _) -> Error "not an appearance"
