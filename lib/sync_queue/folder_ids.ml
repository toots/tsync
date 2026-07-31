(* Client-side folder-inode resolution, both ways round.

   Every folder in the local manifest mirror carries a [.tsync-dir] marker
   holding its stable backend id and its real name (the on-disk directory name
   may be escaped). Resolving a path to a folder id — needed to build backend
   keys under the inode layout — reads these markers; a folder that has content
   but no marker yet is minted one on the spot. The marker format is the same
   {dir,name,id} JSON used for backend folder markers ({!Folder}).

   The other direction — id to path — is what an item identifier asks, since an
   id is the only name for a folder that a rename does not change. The markers
   cannot answer it: they are filed under the path. So each one is mirrored by an
   entry under {!Cache_layout.folders_dir} recording the folder's parent id and
   its real name, and a path is read back by climbing those to the root. The
   entries hold nothing the markers do not; they can be rebuilt from them at any
   time, which is what {!rebuild} does when one is found missing or wrong. *)

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

(* ── The id → path index ──────────────────────────────────────────────────── *)

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

(* Ids that no folder has any more. A miss is the ordinary answer for a deleted
   folder, and the caller asking is fileproviderd, which will ask again and
   again; an id still missing after a rebuild is remembered as gone rather than
   costing a walk every time. Ids are random and minted once, so the only things
   that can bring one back — a peer's folder adopted here, a full resync — go
   through [write_entry], which is where the memo is cleared.

   ponytail: one walk per distinct missing id, so deleting a great many folders
   costs a walk each, once. Add a time floor if that is ever felt. *)
let absent : (string, unit) Hashtbl.t = Hashtbl.create 64

let absent_key ~cache_root ~domain_name id =
  String.concat "\000" [cache_root; domain_name; id]

let write_entry ~cache_root ~domain_name ~id entry =
  Hashtbl.remove absent (absent_key ~cache_root ~domain_name id);
  let path = index_path ~cache_root ~domain_name id in
  let* () = Fs_util.ensure_parent path in
  Fs_util.atomic_write path (entry_to_string entry)

(* ── Markers ──────────────────────────────────────────────────────────────── *)

(* Recorded with the folder's real name taken from where it actually sits, not
   from the marker being written: a marker that travelled with a renamed
   directory still carries the old leaf, and the index has to be able to spell
   the path back out. *)
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

(* Folder id of [rel] — the root when empty; minted and persisted when a folder
   has no marker yet. For the write paths, which are entitled to bring a folder
   into existence. *)
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

(* Folder id of [rel] as already recorded, without minting one: [None] when this
   client has no marker for it. What a read must use — a minted id is a fresh
   random one, so it names a namespace the backend has never heard of and the
   read misses anyway, while the marker it persists on the way re-creates the
   local directory. That is how a deleted folder comes back from a stat. *)
let lookup_id ~cache_root ~domain_name rel =
  if rel = "" then Lwt.return_some Folder.root_id
  else
    let+ existing = read ~cache_root ~domain_name rel in
    Option.map (fun m -> m.Folder.id) existing

(* ── Rebuilding the index ─────────────────────────────────────────────────── *)

(* The markers are the truth; this restates them the other way round. Reached
   when a lookup finds an entry missing or disagreeing — the mirror is written by
   other processes too ([tsync import], [tsync sync --full]), whose journal
   entries this client skips as its own, so no amount of care at the mutation
   sites makes an in-process view sufficient. *)
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
              (* No marker means no id, so nothing below can be reached by one
                 either. Descend without a parent rather than filing children
                 under the nearest marked ancestor, which would name a path they
                 are not at. Minting ids for every folder on the way is what
                 keeps this from arising. *)
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
  (* Entries for folders that no longer exist. Leaving them would not give a
     wrong answer — a resolved path is verified against the markers before it is
     believed — but it would leave the directory growing forever. *)
  let dir = Cache_layout.folders_dir ~cache_root domain_name in
  let* ids = Fs_util.readdir_list dir in
  Lwt_list.iter_s
    (fun id ->
      if Hashtbl.mem seen id then Lwt.return_unit
      else Fs_util.unlink_quiet (Filename.concat dir id))
    ids

(* One walk at a time per domain: concurrent lookups join the one in flight
   rather than each starting their own. *)
let rebuilds : (string, unit Lwt.t) Hashtbl.t = Hashtbl.create 4

let rebuild_once ~cache_root ~domain_name =
  let key = cache_root ^ "\000" ^ domain_name in
  match Hashtbl.find_opt rebuilds key with
    | Some running when Lwt.state running = Lwt.Sleep -> running
    | _ ->
        let running = rebuild ~cache_root ~domain_name in
        Hashtbl.replace rebuilds key running;
        running

(* ── Reading a path back out of an id ─────────────────────────────────────── *)

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

(* Where the folder with this id lives, relative to the domain root; [None] when
   no folder has it any more, which is what tells a caller a directory is gone
   rather than leaving it to linger.

   The climbed path is checked against the markers before it is believed, so a
   stale entry can only ever cost an answer — never hand back a path that is now
   some other folder. A failed check is also the signal to rebuild, after which
   the question is asked once more. *)
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

(* Re-file a folder's index entry after it moved. The name is taken from the new
   path and written back to the marker too: a marker travels with its directory,
   so after a rename it still spells the old leaf, and it is what {!rebuild}
   reads. *)
let reparent ~cache_root ~domain_name rel =
  if rel = "" then Lwt.return_unit
  else
    let* marker = read ~cache_root ~domain_name rel in
    match marker with
      | None -> Lwt.return_unit
      | Some m ->
          write ~cache_root ~domain_name rel
            { m with Folder.name = Filename.basename rel }
