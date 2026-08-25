open Lwt.Syntax

let marker_name = Stored_key.folder_marker_leaf

(* Keyed by the folder itself: where its marker sits, what it is called and
   which folder holds it are all questions the key answers. *)
let dir_of = Cache_layout.manifest_path

let marker_path ~cache_root ~domain_name key =
  Filename.concat (dir_of ~cache_root ~domain_name key) marker_name

let read ~cache_root ~domain_name key =
  let+ s = Io_lwt.Fs.read_file_opt (marker_path ~cache_root ~domain_name key) in
  Option.bind s Folder.marker_of_string

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
  let+ s = Io_lwt.Fs.read_file_opt (index_path ~cache_root ~domain_name id) in
  Option.bind s entry_of_string

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
  let* () = Io_lwt.Fs.ensure_parent path in
  Io_lwt.Fs.atomic_write path (entry_to_string entry)

(* The name comes from where the folder actually sits, not from the marker being
   written: a marker that travelled with a renamed directory still carries the old
   leaf, and the index has to spell the path back out. *)
let rec write ~cache_root ~domain_name key (m : Folder.marker) =
  let dir = dir_of ~cache_root ~domain_name key in
  let* () = Io_lwt.Fs.mkdir_p dir in
  let path = Filename.concat dir marker_name in
  let* () = Io_lwt.Fs.atomic_write path (Folder.marker_to_string m) in
  if Logical_key.is_root key then Lwt.return_unit
  else
    let* parent = ensure_id ~cache_root ~domain_name (Logical_key.parent key) in
    write_entry ~cache_root ~domain_name ~id:m.Folder.id
      { parent; name = Logical_key.leaf key }

(* Mints and persists a marker, so this is for the write paths only. *)
and ensure_id ~cache_root ~domain_name key =
  if Logical_key.is_root key then Lwt.return Stored_key.root_id
  else
    let* existing = read ~cache_root ~domain_name key in
    match existing with
      | Some m -> Lwt.return m.Folder.id
      | None ->
          let m =
            { Folder.name = Logical_key.leaf key; id = Stored_key.new_id () }
          in
          let+ () = write ~cache_root ~domain_name key m in
          m.Folder.id

(* What a read must use: minting here would persist a marker that re-creates the
   local directory, which is how a deleted folder comes back from a stat. *)
let lookup_id ~cache_root ~domain_name key =
  if Logical_key.is_root key then Lwt.return_some Stored_key.root_id
  else
    let+ existing = read ~cache_root ~domain_name key in
    Option.map (fun m -> m.Folder.id) existing

(* Only a directory has a marker, so finding one is what says the key names a
   folder rather than a file — no stat, and no caller left to guess the kind.

   The empty path is the domain root whichever kind it was built as, which is
   what lets a caller holding a path build the key without deciding first. *)
let ref_of_key ~cache_root ~domain_name key =
  if Logical_key.path key = "" then Lwt.return_some `Root
  else
    let* own = lookup_id ~cache_root ~domain_name key in
    match own with
      | Some id -> Lwt.return_some (`Dir id)
      | None ->
          let+ parent =
            lookup_id ~cache_root ~domain_name (Logical_key.parent key)
          in
          Option.map (fun id -> `File (id, Logical_key.leaf key)) parent

(* The markers are the truth; this restates them the other way round. The mirror
   is written by other processes too ([tsync import], [tsync sync --full]), so no
   care at the mutation sites would make an in-process view sufficient. *)
let rebuild ~cache_root ~domain_name =
  let base = Cache_layout.manifests_dir ~cache_root domain_name in
  let seen = Hashtbl.create 64 in
  let rec walk dir ~parent_id =
    let* names = Io_lwt.Fs.readdir_list_quiet dir in
    Lwt_list.iter_s
      (fun name ->
        if Stored_key.internal_leaf name then Lwt.return_unit
        else (
          let path = Filename.concat dir name in
          let* is_dir = Io_lwt.Fs.is_directory path in
          if not is_dir then Lwt.return_unit
          else
            let* marker =
              let+ s =
                Io_lwt.Fs.read_file_opt (Filename.concat path marker_name)
              in
              Option.bind s Folder.marker_of_string
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
      (fun () -> walk base ~parent_id:(Some Stored_key.root_id))
      (fun _ -> Lwt.return_unit)
  in
  (* A stale entry gives no wrong answer, a resolved path being verified against
     the markers, but leaving them grows the directory forever. Neither tree
     exists on a domain nobody has written to, which reads as empty. *)
  let dir = Cache_layout.folders_dir ~cache_root domain_name in
  let* ids = Io_lwt.Fs.readdir_list_quiet dir in
  Lwt_list.iter_s
    (fun id ->
      if Hashtbl.mem seen id then Lwt.return_unit
      else Io_lwt.Fs.unlink_quiet (Filename.concat dir id))
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
    else if id = Stored_key.root_id then Lwt.return_some names
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
let key_of_id ~cache_root ~domain_name ~root id =
  if id = Stored_key.root_id then Lwt.return_some root
  else (
    let verified key =
      let+ actual = lookup_id ~cache_root ~domain_name key in
      if actual = Some id then Some key else None
    in
    let attempt () =
      let* candidate = climb ~cache_root ~domain_name id in
      match candidate with
        | None -> Lwt.return_none
        | Some names -> verified (List.fold_left Logical_key.dir_in root names)
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
let reparent ~cache_root ~domain_name key =
  if Logical_key.is_root key then Lwt.return_unit
  else
    let* marker = read ~cache_root ~domain_name key in
    match marker with
      | None -> Lwt.return_unit
      | Some m ->
          write ~cache_root ~domain_name key
            { m with Folder.name = Logical_key.leaf key }
