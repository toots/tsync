(** What this client has changed and not published: one sidecar per file, in a
    tree keyed exactly like the published one.

    The only copy there is — a resync rebuilds everything else in the checkout
    and must leave this alone. Its bytes live next door in {!Staged_body}. *)

open Manifest

(* [s_size] is authoritative rather than derived from a file length, so a
   truncate either way is a metadata write plus at most one boundary fixup.

   A staged manifest on disk means an upload is owed; once [s_published] is set
   it is instead the commit record of a promotion to replay. *)

(** Where a chunk's bytes are within [staged/chunks/<uuid>]. One body holds
    every staged member of a cache group, so the offset is what separates them
    and is carried rather than derived: it is fixed when the bytes are written,
    while the group size it would be derived from is configuration and can
    change between runs. *)
type body = { uuid : string; offset : int }

type slot =
  | Staged of body
  | Inherit  (** the published manifest's entry at this index *)
  | Zero  (** never written; reads as zeros *)

type staged = {
  s_name : string;
  s_size : int64;
  s_mtime : float;
  s_chunk_size : int;
  s_slots : slot array;
  s_whole : string option;
      (** A whole file handed over by a frontend: its bytes are one file rather
          than per-chunk bodies, [s_slots] is empty, and the upload needs no
          chunking pass. *)
}

(* Which half of the lifecycle the sidecar is in. A mutation can only produce
   [Owed]: the manifest an upload published is not a field of the record it
   would have to clear, so no write can carry a stale one past itself. *)
type state = Owed of staged | Committed of staged * t

let edits = function Owed st | Committed (st, _) -> st
let new_uuid = Id.short

let slot_to_json = function
  (* The offset is omitted when zero, which is every slot of an ungrouped file
     and every first member of a group. *)
  | Staged { uuid; offset } ->
      `Assoc
        (("u", `String uuid)
        :: (if offset = 0 then [] else [("o", `Int offset)]))
  | Inherit -> `Assoc []
  | Zero -> `Assoc [("z", `Bool true)]

let slot_of_json j =
  let open Yojson.Basic.Util in
  match j |> member "u" with
    | `String uuid ->
        let offset = match j |> member "o" with `Int o -> o | _ -> 0 in
        Staged { uuid; offset }
    | _ -> ( match j |> member "z" with `Bool true -> Zero | _ -> Inherit)

let slot_body = function Staged b -> Some b | Inherit | Zero -> None

(* Deduplicated, since a group's members share one. *)
let body_uuids slots =
  Array.fold_left
    (fun acc slot ->
      match slot_body slot with
        | Some { uuid; _ } when not (List.mem uuid acc) -> uuid :: acc
        | _ -> acc)
    [] slots
  |> List.sort compare

(* Read as well as written, so a sidecar from a newer build is set aside rather
   than decoded into something it does not mean. *)
let staged_version = 2

let staged_of_version json =
  let open Yojson.Basic.Util in
  match json |> member "v" with
    | `Int v when v > staged_version ->
        failwith (Printf.sprintf "staged manifest version %d" v)
    | _ -> ()

let staged_to_string state =
  let st = edits state in
  Yojson.Basic.to_string
    (`Assoc
       ([
          ("v", `Int staged_version);
          ("name", `String st.s_name);
          ("size", `Int (Int64.to_int st.s_size));
          ("mtime", `Float st.s_mtime);
          ("chunkSize", `Int st.s_chunk_size);
        ]
       @ (match st.s_whole with
         | Some uuid -> [("whole", `String uuid)]
         | None ->
             [
               ( "slots",
                 `List (Array.to_list (Array.map slot_to_json st.s_slots)) );
             ])
       @
         match state with
         | Owed _ -> []
         (* The published body is binary; base64 keeps it inside this JSON rather
            than in a second file that would have to move atomically with it. *)
         | Committed (_, m) ->
             [
               ( "published",
                 (* Same file, so the same name: this is the published body of
                    the very record carrying it. *)
                 `String (Base64.encode_string (to_string ~name:st.s_name m)) );
             ]))

let staged_of_string body =
  let open Yojson.Basic.Util in
  let json = Yojson.Basic.from_string body in
  staged_of_version json;
  let published =
    match json |> member "published" with
      | `String b64 -> (
          match of_string (Base64.decode_exn b64) with
            | m -> Some m
            | exception _ -> None)
      | _ -> None
  in
  let whole =
    match json |> member "whole" with `String u -> Some u | _ -> None
  in
  {
    s_name = json |> member "name" |> to_string;
    s_size = json |> member "size" |> to_int |> Int64.of_int;
    s_mtime = json |> member "mtime" |> to_float;
    s_chunk_size =
      (try json |> member "chunkSize" |> to_int
       with _ -> Conf.default_chunk_size);
    s_slots =
      (match json |> member "slots" with
        | `List l -> Array.of_list (List.map slot_of_json l)
        | _ -> [||]);
    s_whole = whole;
  }
  |> fun st ->
  match published with None -> Owed st | Some m -> Committed (st, m)

open Lwt.Syntax

let sidecar_path = Cache_layout.staged_manifest_path

module Make (C : Conf.S) = struct
  module Lk = Logical_key.Make (C)

  let rel_of = Logical_key.path

  let root () =
    Cache_layout.staged_manifests_dir ~cache_root:C.cache_root C.domain_name

  let path key =
    Cache_layout.staged_manifest_path ~cache_root:C.cache_root
      ~domain_name:C.domain_name key

  let exists key = Lwt_unix_retry.file_exists (path key)

  let read key =
    let p = path key in
    let* body = Fs_util.read_file_opt p in
    match body with
      | None -> Lwt.return_none
      | Some body -> (
          match staged_of_string body with
            | st -> Lwt.return_some st
            | exception exn ->
                (* Unsynced user data: set aside rather than dropped, so the next
                   start does not trip over it again. *)
                Log.err "staged manifest %s unreadable (%s); moving aside"
                  (Logical_key.to_string key)
                  (Printexc.to_string exn);
                let* () =
                  Lwt.catch
                    (fun () -> Lwt_unix_retry.rename p (p ^ ".bad"))
                    (fun _ -> Lwt.return_unit)
                in
                Lwt.return_none)

  (* For callers that want what the file holds, not which half of the lifecycle
     its sidecar is in. *)
  let read_edits key = Lwt.map (Option.map edits) (read key)

  (* Stamped from the key: this name is what a listing shows before an upload
     lands. *)
  let put key state =
    let p = path key in
    let name = Logical_key.leaf key in
    let state =
      match state with
        | Owed st -> Owed { st with s_name = name }
        | Committed (st, m) -> Committed ({ st with s_name = name }, m)
    in
    let* () = Fs_util.ensure_parent p in
    Fs_util.atomic_write p (staged_to_string state)

  let write key (st : staged) = put key (Owed st)

  (* The record the upload started from, now carrying what it published. Written
     before anything local moves, so a crash after it leaves only local work to
     replay. *)
  let commit key (st : staged) published = put key (Committed (st, published))
  let delete key = Fs_util.unlink_quiet (path key)

  let rename ~src_key ~dst_key =
    let src = path src_key in
    let* exists = Lwt_unix_retry.file_exists src in
    if not exists then Lwt.return_unit
    else (
      let dst = path dst_key in
      let* () = Fs_util.ensure_parent dst in
      let* () = Lwt_unix_retry.rename src dst in
      let* body = Fs_util.read_file_opt dst in
      match body with
        | None -> Lwt.return_unit
        | Some body -> (
            match staged_of_string body with
              | state -> put dst_key state
              | exception _ -> Lwt.return_unit))

  (* Walks on-disk names: a staged manifest records its leaf name, but tree
     position is what identifies the file. *)
  let fold ~rel_dir ~deep f acc =
    let start = path (Lk.dir rel_dir) in
    let rec walk dir key acc =
      let* names = Fs_util.readdir_list dir in
      Lwt_list.fold_left_s
        (fun acc name ->
          if Stored_key.internal_leaf name || Filename.check_suffix name ".bad"
          then Lwt.return acc
          else (
            let path = Filename.concat dir name in
            let* is_dir = Fs_util.is_directory path in
            if is_dir then
              if not deep then Lwt.return acc
              else
                let* real = Cache_layout.real_dir_name path name in
                walk path (Logical_key.dir_in key real) acc
            else
              let+ body = Fs_util.read_file_opt path in
              match body with
                | Some body -> (
                    match staged_of_string body |> edits with
                      | st ->
                          let leaf =
                            if Stored_key.is_escaped name then st.s_name
                            else name
                          in
                          f acc (Logical_key.file_in key leaf) st
                      | exception _ -> acc)
                | None -> acc))
        acc names
    in
    let* ok = Fs_util.is_directory start in
    if ok then walk start (Lk.dir rel_dir) acc else Lwt.return acc

  (* Logical keys owing an upload. *)
  let list () =
    fold ~rel_dir:"" ~deep:true (fun acc key (_ : staged) -> key :: acc) []

  (* Every staged body reachable from a manifest: what a sweep of the body trees
     must keep. *)
  let uuids () =
    fold ~rel_dir:"" ~deep:true
      (fun acc _ st ->
        let acc =
          match st.s_whole with Some uuid -> uuid :: acc | None -> acc
        in
        List.rev_append (body_uuids st.s_slots) acc)
      []

  (* Cutoff 0 deletes no file, only prunes what is left empty. *)
  let prune_dirs () =
    let+ (_ : bool) = Fs_util.reap_older_than ~cutoff:0. (root ()) in
    ()

  (* A locally created file has no published sidecar, so the mirror alone would
     not list it; for one that does, the staged size and mtime are current. *)
  let entries ~rel_dir ~deep =
    fold ~rel_dir ~deep (fun acc key st -> (key, st) :: acc) []
end
