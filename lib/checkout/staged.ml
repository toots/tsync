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

type state = Owed | Uploaded of Manifest.t

type edit = {
  name : string;
  size : int;
  times : Fs.times;
  chunk_size : int;
  content : content;
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
      ("v", `Int 3);
      ("name", `String e.name);
      ("size", `Int e.size);
      ("mtimeNs", `Int e.times.mtime);
      ("createdNs", `Int e.times.created);
      ("chunkSize", `Int e.chunk_size);
    ]
    @ (match e.content with
      | Slots s -> [("slots", `List (Array.to_list (Array.map encode_slot s)))]
      | Whole { body; h1 } ->
          ("whole", `String body)
          :: (match h1 with Some h -> [("h1", `String h)] | None -> []))
    @
      match e.state with
      | Owed -> []
      | Uploaded m -> [("uploaded", `String (Base64.encode_string m.body))]
  in
  Yojson.Safe.to_string (`Assoc fields)

let is_hex16 s = String.length s = 16 && String.for_all Names.is_hexlower s

(* 04 §2.5 reader rules: missing slots mean Zero, extra ones are ignored, a
   [uploaded] that does not decode reads as Owed. *)
let decode body =
  match Yojson.Safe.from_string body with
    | exception _ -> None
    | `Assoc f -> (
        let int n =
          match List.assoc_opt n f with Some (`Int i) -> Some i | _ -> None
        in
        let version = Option.value ~default:3 (int "v") in
        match
          (List.assoc_opt "name" f, int "size", int "mtimeNs", int "createdNs")
        with
          | Some (`String name), Some size, Some mtime, Some created
            when version = 3 && size >= 0 -> (
              let chunk_size =
                match int "chunkSize" with
                  | Some cs when cs > 0 -> Some cs
                  | None -> Some Chunking.default_chunk_size
                  | _ -> None
              in
              match chunk_size with
                | None -> None
                | Some chunk_size ->
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
                    let state =
                      match List.assoc_opt "uploaded" f with
                        | Some (`String b64) -> (
                            match
                              Option.bind
                                (Result.to_option (Base64.decode b64))
                                Manifest.decode
                            with
                              | Some m -> Uploaded m
                              | None -> Owed)
                        | _ -> Owed
                    in
                    Option.map
                      (fun content ->
                        {
                          name;
                          size;
                          times = { mtime; created };
                          chunk_size;
                          content;
                          state;
                        })
                      content)
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

(* local-names §3.2: every component at its handle, so no two names of the
   tree ever share a slot and no edit moves for a sibling. *)
let handles rel =
  if rel = "" then [] else List.map Names.handle (String.split_on_char '/' rel)

let manifest_path t rel =
  List.fold_left Filename.concat t.manifests (handles rel)

let name_marker = Local_names.name_marker

(* A directory takes its handle whole, its name marker in it. Another writer
   may have made it meanwhile. *)
let make_dir dir leaf =
  let p = Filename.concat dir (Names.handle leaf) in
  if not (Fs.is_dir p) then (
    let tmp = Fs.temp_in dir in
    Fs.mkdir_p tmp;
    Fs.durable_replace (name_marker tmp) leaf;
    match Fs.rename tmp p with
      | () -> Fs.fsync_dir dir
      | exception Fail.E { kind = Exists | Not_empty; _ } -> Fs.rm_rf tmp
      | exception e ->
          Fs.rm_rf tmp;
          raise e);
  p

let ensure_dirs t rel =
  Fs.mkdir_p t.manifests;
  ignore
    (List.fold_left make_dir t.manifests
       (if rel = "" then [] else String.split_on_char '/' rel))

(* A staged directory outlives its edits (local-names §3.2); one with no file
   but name markers beneath it is cleared out of a name's way, and one with an
   edit beneath it is refused with nothing changed. *)
let rec holds_edits p =
  List.exists
    (fun l ->
      let c = Filename.concat p l in
      match Fs.lstat_opt c with
        | Some { st_kind = S_DIR; _ } -> holds_edits c
        | Some _ -> l <> ".tsync-name"
        | None -> false)
    (Fs.readdir p)

let clear_way p =
  if Fs.is_dir p then (
    if holds_edits p then
      Fail.raise_ Fail.Not_empty
        "%s: a staged directory with edits is in the way" p;
    Fs.rm_rf p)

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

(* A folder whose edits are all gone leaves its directory here, in the way of
   a file taking its name. *)
let write ?(durable = true) t rel e =
  let p = manifest_path t rel in
  ensure_dirs t (Names.parent_of rel);
  clear_way p;
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

(* Every decodable file of the tree is an edit, whatever its name; names come
   from the records, never the listing. *)
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
                  Option.value ~default:local (Fs.read_file_opt (name_marker p))
                in
                walk p (Names.join rel name) acc
            | Some { st_kind = S_REG; _ } -> (
                match Option.bind (Fs.read_file_opt p) decode with
                  | Some e -> f acc (`Edit (Names.join rel e.name, e))
                  | None -> f acc (`Bad p))
            | _ -> acc))
      acc
      (Option.value ~default:[] (Fs.readdir_opt dir))
  in
  walk t.manifests "" acc

(* local-names §3.2 migration: a tree filed by name moves to handles. An old
   directory's name is the mirror folder's at the same path, which the old
   layout shared, found by the mirror's own lookup so a repeat after a crash
   still finds it. *)
let migrate_layout t =
  let rec walk dir mirror_dir =
    List.iter
      (fun local ->
        if not (Names.is_temp_name local || Names.is_internal_local local) then (
          let p = Filename.concat dir local in
          match Fs.lstat_opt p with
            | Some { st_kind = S_DIR; _ } -> migrate_dir dir mirror_dir local p
            | Some { st_kind = S_REG; _ } -> (
                match Option.bind (Fs.read_file_opt p) decode with
                  | Some e when local <> Names.handle e.name ->
                      let target = Filename.concat dir (Names.handle e.name) in
                      if Fs.exists target then (
                        Fs.rename p (set_aside_path p);
                        Log.warn "set aside the staged manifest %s: %s is taken"
                          p target)
                      else Fs.rename p target
                  | _ -> ())
            | _ -> ()))
      (Option.value ~default:[] (Fs.readdir_opt dir));
    Fs.fsync_dir dir
  and migrate_dir dir mirror_dir local p =
    let name =
      match Fs.read_file_opt (name_marker p) with
        | Some n -> Some n
        | None ->
            let named = Local_names.name_at mirror_dir local in
            if String.starts_with ~prefix:Names.escape_prefix local then
              Option.bind named (fun n ->
                  if Names.handle n = local then Some n else None)
            else Some (Option.value ~default:local named)
    in
    match name with
      | None ->
          Log.warn "staged directory %s has no name; left where it is" p;
          walk p (Filename.concat mirror_dir local)
      | Some name ->
          Fs.durable_replace (name_marker p) name;
          let target = Filename.concat dir (Names.handle name) in
          if target <> p then (
            clear_way target;
            Fs.rename p target);
          let mirror_child =
            Filename.concat mirror_dir
              (Option.value ~default:(Names.escape name)
                 (Local_names.find mirror_dir name))
          in
          walk target mirror_child
  in
  if Fs.is_dir t.manifests then walk t.manifests t.mirror_manifests

let edits t =
  List.rev
    (fold t (fun acc -> function `Edit x -> x :: acc | `Bad _ -> acc) [])

let edits_under t dir =
  List.filter (fun (rel, _) -> Names.is_under ~dir rel) (edits t)

let move t ~src ~dst =
  match edit t src with
    | None -> ()
    | Some e ->
        write t dst { e with name = Names.leaf_of dst };
        remove t src

(* The marker first: a crash before the rename leaves a directory whose
   handle disagrees with its name, which [migrate_layout] moves on. *)
let move_dir t ~src ~dst =
  let s = manifest_path t src and d = manifest_path t dst in
  if Fs.exists s then (
    ensure_dirs t (Names.parent_of dst);
    clear_way d;
    Fs.durable_replace (name_marker s) (Names.leaf_of dst);
    Fs.rename s d;
    Fs.fsync_dir (Filename.dirname d))

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

(* 04 §2.6: a whole body is never modified in place, so an upload's chunk and
   adoption's digest map it (P6); memory M.2 reads it by position per kernel
   request, on a network mount, which could fault a mapped page, and on
   Windows, where a live mapping would keep its release from unlinking it. *)
let whole t id ~mapped ~off ~len =
  let path = whole_path t id in
  Fs.with_fd
    (Fs.openfile path [O_RDONLY])
    (Fs.read_range
       ~map:(mapped && (not Sys.win32) && not (Fs.is_network_fs path))
       ~off ~len)

let read_whole t id ~off ~len = whole t id ~mapped:false ~off ~len
let map_whole t id ~off ~len = whole t id ~mapped:true ~off ~len

(* A staged slot whose body does not exist is CORRUPT; bytes past a body's end
   within the edit's size are zeros (a staged body is sparse). *)
let read_body t id ~off ~len =
  match Fs.opt (fun () -> Fs.unix_openfile (body_path t id) [O_RDONLY] 0) with
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
