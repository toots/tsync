type value = Known of Manifest.t | Identity of string | Unknown

let identity_of (m : Manifest.t) = m.h1 ^ "-" ^ m.h2

let identity = function
  | Known m -> Some (identity_of m)
  | Identity i -> Some i
  | Unknown -> None

let equal a b =
  match (identity a, identity b) with Some a, Some b -> a = b | _ -> false

type command = value Algebra.command

let ( let* ) = Result.bind
let max_bytes = 8 lsl 20
let max_commands = 256

let place_to_json : Algebra.place option -> Yojson.Safe.t = function
  | None -> `Null
  | Some p -> `List [`String (Folder_id.to_string p.parent); `String p.name]

let place_of_json : Yojson.Safe.t -> (Algebra.place option, string) result =
  function
  | `Null -> Ok None
  | `List [`String parent; `String name] -> (
      match Folder_id.of_string parent with
        | Some parent when Names.valid_leaf name -> Ok (Some { parent; name })
        | _ -> Error "a folder id and a leaf")
  | _ -> Error "a place"

let key_fields : Algebra.key -> (string * Yojson.Safe.t) list = function
  | `File p -> [("file", place_to_json (Some p))]
  | `Folder i -> [("folder", `String (Folder_id.to_string i))]

let key_of_json json : (Algebra.key, string) result =
  let field name =
    match json with `Assoc fields -> List.assoc_opt name fields | _ -> None
  in
  match (field "file", field "folder") with
    | Some place, None -> (
        match place_of_json place with
          | Ok (Some p) -> Ok (`File p)
          | Ok None | Error _ -> Error "a file key")
    | None, Some (`String id) -> (
        match Folder_id.of_string id with
          | Some id when not (Folder_id.is_root id) -> Ok (`Folder id)
          | _ -> Error "a folder key")
    | _ -> Error "exactly one of file and folder"

let is_identity s =
  String.length s = 33
  && s.[16] = '-'
  && String.for_all (fun c -> c = '-' || Names.is_hexlower c) s

let guard_to_json = function
  | None -> `Null
  | Some v -> (
      match identity v with
        | Some i -> `String i
        | None -> Fail.invalid "a guard with no content identity")

let guard_of_json : Yojson.Safe.t -> (value option, string) result = function
  | `Null -> Ok None
  | `String i when is_identity i -> Ok (Some (Identity i))
  | _ -> Error "a content identity"

let manifest_to_json ~leaf = function
  | None -> `Null
  | Some (Known m) ->
      let m = if m.name = leaf then m else Manifest.rename m leaf in
      `String (Base64.encode_string m.body)
  | Some (Identity _ | Unknown) ->
      Fail.invalid "%s: a value after that is not a manifest" leaf

let manifest_of_json : Yojson.Safe.t -> (value option, string) result = function
  | `Null -> Ok None
  | `String b -> (
      match
        Result.to_option (Base64.decode b)
        |> Fun.flip Option.bind Manifest.decode
      with
        | Some m -> Ok (Some (Known m))
        | None -> Error "a manifest")
  | _ -> Error "a manifest"

type t = { author : string; commands : command list }

let command_to_json (c : command) : Yojson.Safe.t =
  let before, after =
    match c with
      | `File (p, before, after) ->
          (guard_to_json before, manifest_to_json ~leaf:p.name after)
      | `Folder (_, before, after) -> (place_to_json before, place_to_json after)
  in
  `Assoc (key_fields (Algebra.key_of c) @ [("before", before); ("after", after)])

let command_of_json json : (command, string) result =
  let field name =
    match json with
      | `Assoc fields ->
          Option.to_result ~none:name (List.assoc_opt name fields)
      | _ -> Error "an object"
  in
  let* key = key_of_json json in
  let* before = field "before" in
  let* after = field "after" in
  match key with
    | `File p ->
        let* before = guard_of_json before in
        let* after = manifest_of_json after in
        Ok (`File (p, before, after))
    | `Folder i ->
        let* before = place_of_json before in
        let* after = place_of_json after in
        Ok (`Folder (i, before, after))

let distinct_keys commands =
  let keys = List.map Algebra.key_of commands in
  List.length (List.sort_uniq Algebra.compare_key keys) = List.length keys

let decode body =
  match Yojson.Safe.from_string body with
    | exception _ -> `Corrupt "a JSON object"
    | `Assoc fields -> (
        match List.assoc_opt "v" fields with
          | Some (`Int v) when v > 1 -> `Later_version v
          | Some (`Int _) -> (
              let commands =
                match List.assoc_opt "commands" fields with
                  | Some (`List (_ :: _ as l)) ->
                      List.fold_right
                        (fun json acc ->
                          let* acc = acc in
                          let* c = command_of_json json in
                          Ok (c :: acc))
                        l (Ok [])
                  | _ -> Error "a non-empty array of commands"
              in
              match (List.assoc_opt "author" fields, commands) with
                | _, Error what -> `Corrupt what
                | Some (`String author), Ok commands ->
                    if distinct_keys commands then `Entry { author; commands }
                    else `Corrupt "commands on distinct keys"
                | _ -> `Corrupt "an author")
          | _ -> `Corrupt "a version")
    | _ -> `Corrupt "a JSON object"

(* What a reader gets back: guards as identities, manifests under their leaf. *)
let as_read (c : command) : command =
  match c with
    | `File (p, before, after) ->
        let guard v = Option.map (fun i -> Identity i) (identity v) in
        `File
          ( p,
            Option.bind before guard,
            Option.map
              (function
                | Known m when m.name <> p.name ->
                    Known (Manifest.rename m p.name)
                | v -> v)
              after )
    | `Folder _ -> c

let encode t =
  if t.commands = [] then Fail.invalid "a log entry with no command";
  if not (distinct_keys t.commands) then
    Fail.invalid "a log entry with two commands on one key";
  let body =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("v", `Int 1);
           ("author", `String t.author);
           ("commands", `List (List.map command_to_json t.commands));
         ])
  in
  let sorted l =
    List.sort
      (fun a b -> Algebra.compare_key (Algebra.key_of a) (Algebra.key_of b))
      l
  in
  (match decode body with
    | `Entry read
      when read.author = t.author
           && sorted read.commands = sorted (List.map as_read t.commands) ->
        ()
    | _ -> Fail.invalid "a log entry that does not read back as its batch");
  body

let chunk_names body =
  match decode (Bigstring.to_string body) with
    | `Corrupt what -> Error ("expected " ^ what)
    | `Later_version v -> Error (Printf.sprintf "version %d" v)
    | `Entry t ->
        List.fold_left
          (fun acc (c : command) ->
            let* acc = acc in
            match c with
              | `File (_, _, Some (Known m)) ->
                  let* keys =
                    Manifest.chunk_names (Bigstring.of_string m.body)
                  in
                  Ok (keys @ acc)
              | _ -> Ok acc)
          (Ok []) t.commands
