open Tsync_core

type slot =
  | Inherit
  | Zero
  | Staged of { body : string; off : int }
      (** [h1]: the body's whole-file digest, the key's [content_id] (04 §2.5).
      *)

type content =
  | Slots of slot array
  | Whole of { body : string; h1 : string option }

type base = Base_unknown | Base_none | Base of string
type state = Owed | Committed of Manifest.t

type edit = {
  name : string;
  size : int;
  mtime : float;
  chunk_size : int;
  content : content;
  base : base;
  state : state;
}

let encode_slot = function
  | Inherit -> `Assoc []
  | Zero -> `Assoc [("z", `Bool true)]
  | Staged { body; off } ->
      `Assoc (("u", `String body) :: (if off = 0 then [] else [("o", `Int off)]))

let encode e =
  let fields =
    [
      ("v", `Int 2);
      ("name", `String e.name);
      ("size", `Int e.size);
      ("mtime", `Float e.mtime);
      ("chunkSize", `Int e.chunk_size);
    ]
    @ (match e.content with
      | Slots s -> [("slots", `List (Array.to_list (Array.map encode_slot s)))]
      | Whole { body; h1 } ->
          ("whole", `String body)
          :: (match h1 with Some h -> [("h1", `String h)] | None -> []))
    @ (match e.base with
      | Base_unknown -> []
      | Base_none -> [("base", `Null)]
      | Base h -> [("base", `String h)])
    @
      match e.state with
      | Owed -> []
      | Committed m -> [("published", `String (Base64.encode_string m.body))]
  in
  Yojson.Safe.to_string (`Assoc fields)

let is_hex16 s = String.length s = 16 && String.for_all Names.is_hexlower s

(* 04 §2.5 reader rules: missing slots mean Zero, extra ones are ignored, a
   [published] that does not decode reads as Owed. *)
let decode body =
  match Yojson.Safe.from_string body with
    | exception _ -> None
    | `Assoc f -> (
        let num n =
          match List.assoc_opt n f with
            | Some (`Int i) -> Some (float_of_int i)
            | Some (`Float x) -> Some x
            | _ -> None
        in
        let int n =
          match List.assoc_opt n f with Some (`Int i) -> Some i | _ -> None
        in
        let version = Option.value ~default:2 (int "v") in
        match (List.assoc_opt "name" f, int "size", num "mtime") with
          | Some (`String name), Some size, Some mtime
            when version <= 2 && size >= 0 -> (
              let chunk_size =
                match int "chunkSize" with
                  | Some cs when cs > 0 -> Some cs
                  | None -> Some Chunking.default_chunk_size
                  | _ -> None
              in
              match chunk_size with
                | None -> None
                | Some chunk_size -> (
                    let n = Chunking.count ~size ~cs:chunk_size in
                    let slot = function
                      | `Assoc s -> (
                          match
                            ( List.assoc_opt "u" s,
                              List.assoc_opt "o" s,
                              List.assoc_opt "z" s )
                          with
                            | Some (`String body), o, _
                              when String.length body > 0 ->
                                Some
                                  (Staged
                                     {
                                       body;
                                       off =
                                         (match o with
                                           | Some (`Int o) -> o
                                           | _ -> 0);
                                     })
                            | None, _, Some (`Bool true) -> Some Zero
                            | None, _, _ -> Some Inherit
                            | _ -> None)
                      | _ -> None
                    in
                    let content =
                      match
                        (List.assoc_opt "whole" f, List.assoc_opt "slots" f)
                      with
                        | Some (`String body), _ ->
                            Some
                              (Whole
                                 {
                                   body;
                                   h1 =
                                     (match List.assoc_opt "h1" f with
                                       | Some (`String h) when is_hex16 h ->
                                           Some h
                                       | _ -> None);
                                 })
                        | _, Some (`List l) ->
                            let parsed = List.map slot l in
                            if List.exists Option.is_none parsed then None
                            else (
                              let a =
                                Array.of_list (List.map Option.get parsed)
                              in
                              Some
                                (Slots
                                   (Array.init n (fun i ->
                                        if i < Array.length a then a.(i)
                                        else Zero))))
                        | None, None -> Some (Slots (Array.make n Zero))
                        | _ -> None
                    in
                    let base =
                      match List.assoc_opt "base" f with
                        | None -> Some Base_unknown
                        | Some `Null -> Some Base_none
                        | Some (`String h) when is_hex16 h -> Some (Base h)
                        | _ -> None
                    in
                    let state =
                      match List.assoc_opt "published" f with
                        | Some (`String b64) -> (
                            match
                              Option.bind
                                (Result.to_option (Base64.decode b64))
                                Manifest.decode
                            with
                              | Some m -> Committed m
                              | None -> Owed)
                        | _ -> Owed
                    in
                    match (content, base) with
                      | Some content, Some base ->
                          Some
                            {
                              name;
                              size;
                              mtime;
                              chunk_size;
                              content;
                              base;
                              state;
                            }
                      | _ -> None))
          | _ -> None)
    | _ -> None

type t = {
  manifests : string;
  chunks : string;
  whole : string;
  mirror_manifests : string;
}

let create ~cache_root domain =
  let root =
    Filename.concat
      (Filename.concat cache_root (Domain_name.to_string domain))
      "staged"
  in
  {
    manifests = Filename.concat root "manifests";
    chunks = Filename.concat root "chunks";
    whole = Filename.concat root "whole";
    mirror_manifests =
      Filename.concat
        (Filename.concat
           (Filename.concat cache_root (Domain_name.to_string domain))
           "manifests")
        "";
  }

let manifest_path t rel = Filename.concat t.manifests (Names.escape_path rel)
let body_path t id = Filename.concat t.chunks id
let whole_path t id = Filename.concat t.whole id

(* Staged manifests mirror the tree, so a path with edits beneath it is a
   directory here: that path itself has no edit. *)
let read t rel =
  let p = manifest_path t rel in
  if Fs.is_dir p then `Absent
  else (
    match Fs.read_file_opt p with
      | None -> `Absent
      | Some b -> (
          match decode b with Some e -> `Edit e | None -> `Unparseable))

let edit t rel = match read t rel with `Edit e -> Some e | _ -> None

let write ?(durable = true) t rel e =
  let p = manifest_path t rel in
  Fs.mkdir_p (Filename.dirname p);
  if durable then Fs.durable_replace p (encode e) else Fs.replace p (encode e)

let remove t rel =
  let p = manifest_path t rel in
  if Fs.release p then Fs.fsync_dir (Filename.dirname p)

(* An internal leaf, which no user name escapes to (04 §2.5). *)
let set_aside_prefix = ".tsync-bad-"
let is_set_aside_name n = String.starts_with ~prefix:set_aside_prefix n

let set_aside_path p =
  let dir = Filename.dirname p and leaf = Filename.basename p in
  let rec pick n =
    let c =
      Filename.concat dir
        (if n = 1 then set_aside_prefix ^ leaf
         else Printf.sprintf "%s%d-%s" set_aside_prefix n leaf)
    in
    if Fs.exists c then pick (n + 1) else c
  in
  pick 1

(* Every decodable file of the tree is an edit, whatever its name. An escaped
   folder's real name is the mirror's, which files the same escaped path. *)
let fold t f acc =
  let rec walk dir rel acc =
    List.fold_left
      (fun acc local ->
        if
          Names.is_temp_name local
          || (Names.is_internal_local local && not (is_set_aside_name local))
        then acc
        else (
          let p = Filename.concat dir local in
          match Fs.lstat_opt p with
            | Some { st_kind = S_DIR; _ } ->
                let name =
                  if String.starts_with ~prefix:Names.escape_prefix local then (
                    let rel_local =
                      String.sub p
                        (String.length t.manifests + 1)
                        (String.length p - String.length t.manifests - 1)
                    in
                    Option.value ~default:local
                      (Fs.read_file_opt
                         (Filename.concat
                            (Filename.concat t.mirror_manifests rel_local)
                            ".tsync-name")))
                  else local
                in
                walk p (Names.join rel name) acc
            | Some { st_kind = S_REG; _ } -> (
                match Option.bind (Fs.read_file_opt p) decode with
                  | Some e ->
                      let leaf =
                        if String.starts_with ~prefix:Names.escape_prefix local
                        then e.name
                        else local
                      in
                      f acc (`Edit (Names.join rel leaf, e))
                  | None -> f acc (`Bad p))
            | _ -> acc))
      acc
      (Option.value ~default:[] (Fs.readdir_opt dir))
  in
  walk t.manifests "" acc

let edits t =
  List.rev
    (fold t (fun acc -> function `Edit x -> x :: acc | `Bad _ -> acc) [])

let edits_under t dir =
  List.filter (fun (rel, _) -> Names.is_under ~dir rel) (edits t)

let move ?(new_file = false) t ~src ~dst =
  match edit t src with
    | None -> ()
    | Some e ->
        write t dst
          {
            e with
            name = Names.leaf_of dst;
            base = (if new_file then Base_none else e.base);
          };
        remove t src

let bodies_named e =
  match e.content with
    | Whole { body; _ } -> [body]
    | Slots s ->
        List.sort_uniq compare
          (Array.to_list
             (Array.map
                (function Staged { body; _ } -> Some body | _ -> None)
                s)
          |> List.filter_map Fun.id)

let slots e =
  match e.content with
    | Slots s -> s
    | Whole _ -> invalid_arg "Staged.slots of a whole edit"

let new_body_id () = Ids.short ()

let open_body ?(create = false) t id =
  Fs.mkdir_p t.chunks;
  Fs.openfile (body_path t id)
    (if create then [O_RDWR; O_CREAT; O_EXCL] else [O_RDWR])

let body_size t id =
  match Fs.lstat_opt (body_path t id) with
    | Some st -> Int64.to_int st.st_size
    | None -> -1

let body_links t id =
  match Fs.lstat_opt (body_path t id) with Some st -> st.st_nlink | None -> 0

(* A staged slot whose body does not exist is CORRUPT; bytes past a body's end
   within the edit's size are zeros (a staged body is sparse). *)
let read_body t id ~off ~len =
  match
    Fs.opt (fun () -> Unix.openfile (body_path t id) [O_RDONLY; O_CLOEXEC] 0)
  with
    | None -> Fail.corrupt "staged body %s is missing" id
    | Some fd ->
        Fs.with_fd fd (fun fd ->
            let buf = Bigstring.create len in
            let n = Fs.pread_full fd buf ~boff:0 ~len ~off in
            if n < len then
              Bigarray.Array1.fill
                (Bigstring.sub buf ~off:n ~len:(len - n))
                '\000';
            buf)

let write_body_at fd ~off data =
  Fs.pwrite_all fd data ~boff:0 ~len:(Bigstring.length data) ~off
