open Lwt.Syntax

let marker_name = ".tsync-dir"

let dir_of ~cache_root ~domain_name rel =
  let base = Cache_layout.manifests_dir ~cache_root domain_name in
  if rel = "" then base else Filename.concat base (Name_escape.encode_key rel)

let marker_path ~cache_root ~domain_name rel =
  Filename.concat (dir_of ~cache_root ~domain_name rel) marker_name

let read ~cache_root ~domain_name rel =
  Lwt.catch
    (fun () ->
      let+ s =
        Lwt_unix_retry.with_file ~mode:Lwt_io.Input
          (marker_path ~cache_root ~domain_name rel)
          Lwt_io.read
      in
      Folder.marker_of_string s)
    (fun _ -> Lwt.return_none)

let index_path ~cache_root ~domain_name id =
  Filename.concat (Cache_layout.folders_dir ~cache_root domain_name) id

type entry = { parent : string; name : string }

let entry_to_string { parent; name } =
  Yojson.Basic.to_string
    (`Assoc [("parent", `String parent); ("name", `String name)])

let entry_of_string data =
  match Yojson.Basic.from_string data with
    | `Assoc fields -> (
        match
          (List.assoc_opt "parent" fields, List.assoc_opt "name" fields)
        with
          | Some (`String parent), Some (`String name) -> Some { parent; name }
          | _ -> None)
    | _ | (exception _) -> None

let read_entry ~cache_root ~domain_name id =
  Lwt.catch
    (fun () ->
      let+ s =
        Lwt_unix_retry.with_file ~mode:Lwt_io.Input
          (index_path ~cache_root ~domain_name id)
          Lwt_io.read
      in
      entry_of_string s)
    (fun _ -> Lwt.return_none)

(* Ids no folder has any more, so the repeated lookups fileproviderd makes for a
   deleted folder do not each cost a walk. Ids are random and minted once, so
   anything that brings one back goes through [write_entry], which clears the
   memo.

   ponytail: one walk per distinct missing id; add a time floor if that is ever
   felt. *)
let absent : (string, unit) Hashtbl.t = Hashtbl.create 64

let absent_key ~cache_root ~domain_name id =
  String.concat "\000" [cache_root; domain_name; id]

let write_entry ~cache_root ~domain_name ~id entry =
  Hashtbl.remove absent (absent_key ~cache_root ~domain_name id);
  let path = index_path ~cache_root ~domain_name id in
  let* () = Fs_util.ensure_parent path in
  Fs_util.atomic_write path (entry_to_string entry)

(* The name comes from where the folder actually sits, not from the marker being
   written: a marker that travelled with a renamed directory still carries the old
   leaf, and the index has to spell the path back out. *)
let rec write ~cache_root ~domain_name rel (m : Folder.marker) =
  let dir = dir_of ~cache_root ~domain_name rel in
  let* () = Fs_util.mkdir_p dir in
  let path = Filename.concat dir marker_name in
  let* () = Fs_util.atomic_write path (Folder.marker_to_string m) in
  if rel = "" then Lwt.return_unit
  else
    let* parent = ensure_id ~cache_root ~domain_name (Key.parent rel) in
    write_entry ~cache_root ~domain_name ~id:m.Folder.id
      { parent; name = Filename.basename rel }

(* Mints and persists a marker, so this is for the write paths only. *)
and ensure_id ~cache_root ~domain_name rel =
  if rel = "" then Lwt.return Folder.root_id
  else
    let* existing = read ~cache_root ~domain_name rel in
    match existing with
      | Some m -> Lwt.return m.Folder.id
      | None ->
          let m =
            { Folder.name = Filename.basename rel; id = Folder.new_id () }
          in
          let+ () = write ~cache_root ~domain_name rel m in
          m.Folder.id

(* What a read must use: minting here would persist a marker that re-creates the
   local directory, which is how a deleted folder comes back from a stat. *)
let lookup_id ~cache_root ~domain_name rel =
  if rel = "" then Lwt.return_some Folder.root_id
  else
    let+ existing = read ~cache_root ~domain_name rel in
    Option.map (fun m -> m.Folder.id) existing

(* The markers are the truth; this restates them the other way round. The mirror
   is written by other processes too ([tsync import], [tsync sync --full]), so no
   care at the mutation sites would make an in-process view sufficient. *)
let rebuild ~cache_root ~domain_name =
  let base = Cache_layout.manifests_dir ~cache_root domain_name in
  let seen = Hashtbl.create 64 in
  let rec walk dir ~parent_id =
    let* names = Fs_util.readdir_list dir in
    Lwt_list.iter_s
      (fun name ->
        if name = marker_name || name = Name_escape.dir_marker then
          Lwt.return_unit
        else (
          let path = Filename.concat dir name in
          let* is_dir = Fs_util.is_directory path in
          if not is_dir then Lwt.return_unit
          else
            let* marker =
              Lwt.catch
                (fun () ->
                  let+ s =
                    Lwt_unix_retry.with_file ~mode:Lwt_io.Input
                      (Filename.concat path marker_name)
                      Lwt_io.read
                  in
                  Folder.marker_of_string s)
                (fun _ -> Lwt.return_none)
            in
            match (marker, parent_id) with
              (* No marker means no id, and filing children under the nearest
                 marked ancestor would name a path they are not at. *)
              | None, _ -> walk path ~parent_id:None
              | Some m, None -> walk path ~parent_id:(Some m.Folder.id)
              | Some m, Some parent ->
                  Hashtbl.replace seen m.Folder.id ();
                  let* () =
                    write_entry ~cache_root ~domain_name ~id:m.Folder.id
                      { parent; name = m.Folder.name }
                  in
                  walk path ~parent_id:(Some m.Folder.id)))
      names
  in
  let* () =
    Lwt.catch
      (fun () -> walk base ~parent_id:(Some Folder.root_id))
      (fun _ -> Lwt.return_unit)
  in
  (* A stale entry gives no wrong answer, a resolved path being verified against
     the markers, but leaving them grows the directory forever. *)
  let dir = Cache_layout.folders_dir ~cache_root domain_name in
  let* ids = Fs_util.readdir_list dir in
  Lwt_list.iter_s
    (fun id ->
      if Hashtbl.mem seen id then Lwt.return_unit
      else Fs_util.unlink_quiet (Filename.concat dir id))
    ids

(* One walk at a time per domain; concurrent lookups join the one in flight. *)
let rebuilds : (string, unit Lwt.t) Hashtbl.t = Hashtbl.create 4

let rebuild_once ~cache_root ~domain_name =
  let key = cache_root ^ "\000" ^ domain_name in
  match Hashtbl.find_opt rebuilds key with
    | Some running when Lwt.state running = Lwt.Sleep -> running
    | _ ->
        let running = rebuild ~cache_root ~domain_name in
        Hashtbl.replace rebuilds key running;
        running

(* A cycle in a corrupted index would otherwise climb forever. *)
let max_depth = 256

let climb ~cache_root ~domain_name id =
  let rec go id names depth =
    if depth > max_depth then Lwt.return_none
    else if id = Folder.root_id then
      Lwt.return_some (List.fold_left Key.join "" names)
    else
      let* entry = read_entry ~cache_root ~domain_name id in
      match entry with
        | None -> Lwt.return_none
        | Some { parent; name } -> go parent (name :: names) (depth + 1)
  in
  go id [] 0

(* The climbed path is checked against the markers before it is believed, so a
   stale entry costs an answer rather than naming some other folder, and a failed
   check is the signal to rebuild and ask once more. *)
let rel_of_id ~cache_root ~domain_name id =
  if id = Folder.root_id then Lwt.return_some ""
  else (
    let verified rel =
      let+ actual = lookup_id ~cache_root ~domain_name rel in
      if actual = Some id then Some rel else None
    in
    let attempt () =
      let* candidate = climb ~cache_root ~domain_name id in
      match candidate with None -> Lwt.return_none | Some rel -> verified rel
    in
    let* first = attempt () in
    match first with
      | Some _ -> Lwt.return first
      | None when Hashtbl.mem absent (absent_key ~cache_root ~domain_name id) ->
          Lwt.return_none
      | None ->
          let* () = rebuild_once ~cache_root ~domain_name in
          let+ second = attempt () in
          if second = None then
            Hashtbl.replace absent (absent_key ~cache_root ~domain_name id) ();
          second)

(* A marker travels with its directory and so still spells the old leaf after a
   rename; {!rebuild} reads it, so the new name is written back. *)
let reparent ~cache_root ~domain_name rel =
  if rel = "" then Lwt.return_unit
  else
    let* marker = read ~cache_root ~domain_name rel in
    match marker with
      | None -> Lwt.return_unit
      | Some m ->
          write ~cache_root ~domain_name rel
            { m with Folder.name = Filename.basename rel }
