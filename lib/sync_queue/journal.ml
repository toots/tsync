type rename_op = {
  dst : string;
  src : string;
  size : int64 option;
  is_dir : bool;
}

type op =
  [ `Delete of string
  | `Mkdir of string
  | `Put of string * int64
  | `Rename of rename_op
  | `Rmdir of string ]

let share_dir () =
  match Sys.getenv_opt "XDG_DATA_HOME" with
    | Some d -> Filename.concat d "tsync"
    | None -> Filename.concat (Sys.getenv "HOME") ".local/share/tsync"

let client_uuid () =
  let uuid_file = Filename.concat (share_dir ()) "client-uuid" in
  if Sys.file_exists uuid_file then (
    let ic = open_in uuid_file in
    let s = input_line ic in
    close_in ic;
    String.trim s)
  else (
    let buf = Bytes.create 16 in
    let fd = Unix.openfile "/dev/urandom" [Unix.O_RDONLY] 0 in
    ignore (Unix.read fd buf 0 16);
    Unix.close fd;
    let hex = Buffer.create 32 in
    for i = 0 to Bytes.length buf - 1 do
      Buffer.add_string hex
        (Printf.sprintf "%02x" (Char.code (Bytes.get buf i)))
    done;
    let uuid = Buffer.contents hex in
    let dir = share_dir () in
    (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let oc = open_out uuid_file in
    output_string oc uuid;
    close_out oc;
    uuid)

(* %013Ld: 13-digit zero-padded int64; current ms timestamps are 13 digits,
   ensuring lexicographic order matches chronological order *)
let entry_key () =
  let ms = Int64.of_float (Unix.gettimeofday () *. 1000.) in
  Printf.sprintf "%013Ld-%s" ms (client_uuid ())

(* Accept either a bare entry key ("0001750000000000-uuid") or a full S3 key *)
let timestamp_ms_of_filename s =
  let s = Filename.basename s in
  let i = String.index s '-' in
  Int64.of_string (String.sub s 0 i)

let client_uuid_of_filename s =
  let s = Filename.basename s in
  let i = String.index s '-' in
  String.sub s (i + 1) (String.length s - i - 1)

let encode ops =
  let encode_one = function
    | `Put (key, size) ->
        `Assoc
          [
            ("op", `String "put");
            ("key", `String key);
            ("size", `Int (Int64.to_int size));
          ]
    | `Delete key -> `Assoc [("op", `String "delete"); ("key", `String key)]
    | `Mkdir key -> `Assoc [("op", `String "mkdir"); ("key", `String key)]
    | `Rmdir key -> `Assoc [("op", `String "rmdir"); ("key", `String key)]
    | `Rename { dst; src; size; is_dir } ->
        let fields =
          [
            ("op", `String "rename");
            ("key", `String dst);
            ("src", `String src);
            ("is_dir", `Bool is_dir);
          ]
          @
            match size with
            | None -> []
            | Some s -> [("size", `Int (Int64.to_int s))]
        in
        `Assoc fields
  in
  String.concat "\n"
    (List.map (fun op -> Yojson.Basic.to_string (encode_one op)) ops)
  ^ "\n"

let decode s =
  List.filter_map
    (fun line ->
      let line = String.trim line in
      if line = "" then None
      else (
        try
          let open Yojson.Basic.Util in
          let j = Yojson.Basic.from_string line in
          let key = j |> member "key" |> to_string in
          let op =
            match j |> member "op" |> to_string with
              | "put" -> `Put (key, j |> member "size" |> to_int |> Int64.of_int)
              | "delete" -> `Delete key
              | "mkdir" -> `Mkdir key
              | "rmdir" -> `Rmdir key
              | "rename" ->
                  let src = j |> member "src" |> to_string in
                  let size =
                    match j |> member "size" with
                      | `Int n -> Some (Int64.of_int n)
                      | _ -> None
                  in
                  let is_dir =
                    match j |> member "is_dir" with `Bool b -> b | _ -> false
                  in
                  `Rename { dst = key; src; size; is_dir }
              | s -> failwith ("unknown op: " ^ s)
          in
          Some op
        with _ -> None))
    (String.split_on_char '\n' s)

let pending_dir () = Filename.concat (share_dir ()) "journal-pending"

let write_local_pending ~entry_key ops =
  let dir = pending_dir () in
  (try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let oc = open_out (Filename.concat dir entry_key) in
  output_string oc (encode ops);
  close_out oc

let delete_local_pending ~entry_key =
  try Unix.unlink (Filename.concat (pending_dir ()) entry_key)
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let local_pending_entries ~uuid =
  let dir = pending_dir () in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun name ->
        try client_uuid_of_filename name = uuid with _ -> false)
    |> List.sort String.compare
    |> List.filter_map (fun name ->
        let path = Filename.concat dir name in
        try
          let ic = open_in path in
          let n = in_channel_length ic in
          let s = Bytes.create n in
          really_input ic s 0 n;
          close_in ic;
          Some (name, decode (Bytes.to_string s))
        with _ -> None)
