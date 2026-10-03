open Tsync_core

type t = {
  root : string;
  manifests : string;
  folders : string;
  by_path : string;
  key_prefix : string;
  by_fid : (string, string) Hashtbl.t option ref;
      (** file id → path, built on first use and kept by every marker write *)
  by_fid_m : Mutex.t;
}

let create ~cache_root domain =
  let root = Filename.concat cache_root (Domain_name.to_string domain) in
  {
    root;
    manifests = Filename.concat root "manifests";
    folders = Filename.concat root "folders";
    by_path = Filename.concat (Filename.concat root "folders") "by-path";
    key_prefix = Key.prefix_to_string (Key.manifests domain);
    by_fid = ref None;
    by_fid_m = Mutex.create ();
  }

(* An index not built yet needs no upkeep: its first walk sees the markers. *)
let with_fid_index t f =
  Mutex.protect t.by_fid_m (fun () -> Option.iter f !(t.by_fid))

let root t = t.root

let path t rel =
  if rel = "" then t.manifests
  else Filename.concat t.manifests (Names.escape_path rel)

let dir_marker dir = Filename.concat dir ".tsync-dir"
let name_marker dir = Filename.concat dir ".tsync-name"

let own_marker dir leaf =
  Filename.concat dir (".tsync-own-" ^ Xxh.hex16 (Xxh.string leaf))

(* 04 §2.3: the file-id marker of a file entry with leaf [leaf]. *)
let fid_marker dir leaf =
  Filename.concat dir (".tsync-fid-" ^ Xxh.hex16 (Xxh.string leaf))

(* A non-durable write still fsyncs its data, so it is never torn; only its
   directory entry waits for the caller's flush (pitfall B-1.12: syncfs is no barrier
   on macOS). *)
let write ?(durable = true) p data =
  if durable then Fs.durable_replace p data else Fs.replace p data

(* Skip the write when the file already holds these bytes, so a directory's
   mtime moves only when its set of children changes. *)
let write_if_changed ?durable p data =
  if Fs.read_file_opt p <> Some data then write ?durable p data

type file = [ `File of Manifest.t | `Corrupt | `Dir | `Absent ]

let file t rel : file =
  let p = path t rel in
  match Fs.lstat_opt p with
    | None -> `Absent
    | Some { st_kind = S_DIR; _ } -> `Dir
    | Some _ -> (
        match Manifest.decode (Fs.read_file p) with
          | Some m -> `File m
          | None -> `Corrupt)

let manifest t rel = match file t rel with `File m -> Some m | _ -> None

let kind t rel =
  if rel = "" then `Dir
  else (
    match Fs.lstat_opt (path t rel) with
      | Some { st_kind = S_DIR; _ } -> `Dir
      | Some _ -> `File
      | None -> `Absent)

let parse_marker body =
  match Folder.classify_marker body with `Marker (m, _) -> Some m | _ -> None

let folder_id t rel =
  if rel = "" then Some Folder_id.root
  else
    Option.bind
      (Fs.read_file_opt (dir_marker (path t rel)))
      (fun b -> Option.map (fun (m : Folder.marker) -> m.id) (parse_marker b))

(* The real leaf held by the local name [local] in [dir]. *)
let real_name dir local =
  if String.starts_with ~prefix:Names.escape_prefix local then (
    let p = Filename.concat dir local in
    match Fs.lstat_opt p with
      | Some { st_kind = S_DIR; _ } -> Fs.read_file_opt (name_marker p)
      | Some _ ->
          Option.map
            (fun (m : Manifest.t) -> m.name)
            (Option.bind (Fs.read_file_opt p) Manifest.decode)
      | None -> None)
  else Some local

(* 01 §2.8: an escape handle already held by another real name refuses the
   second item as EXISTS. *)
let check_handle t rel =
  let leaf = Names.leaf_of rel in
  let local = Names.escape leaf in
  if local <> leaf then (
    let dir = path t (Names.parent_of rel) in
    match real_name dir local with
      | Some other when other <> leaf ->
          Fail.raise_ Fail.Exists "%s: its local name is held by %S" rel other
      | _ -> ())

let ensure_dirs t rel =
  let rec go rel =
    if rel <> "" then (
      go (Names.parent_of rel);
      let p = path t rel in
      match Fs.lstat_opt p with
        | Some { st_kind = S_DIR; _ } -> ()
        | Some _ -> Fail.raise_ Fail.Exists "%s is a file" rel
        | None ->
            check_handle t rel;
            Fs.mkdir_p p;
            let leaf = Names.leaf_of rel in
            if Names.escape leaf <> leaf then write (name_marker p) leaf)
  in
  Fs.mkdir_p t.manifests;
  go rel

let is_own t rel =
  let leaf = Names.leaf_of rel in
  Fs.read_file_opt (own_marker (path t (Names.parent_of rel)) leaf) = Some leaf

let clear_own t rel =
  let dir = path t (Names.parent_of rel) in
  if Fs.release (own_marker dir (Names.leaf_of rel)) then Fs.fsync_dir dir

let set_own t rel =
  let leaf = Names.leaf_of rel in
  write (own_marker (path t (Names.parent_of rel)) leaf) leaf

(* The marker belongs to the entry only when it records the entry's leaf. *)
let file_id t rel =
  let leaf = Names.leaf_of rel in
  match Fs.read_file_opt (fid_marker (path t (Names.parent_of rel)) leaf) with
    | Some body
      when String.length body = 33 + String.length leaf
           && body.[32] = '\n'
           && String.sub body 33 (String.length leaf) = leaf ->
        let id = String.sub body 0 32 in
        if Names.valid_file_id id then Some id else None
    | _ -> None

let set_file_id ?durable t rel id =
  let leaf = Names.leaf_of rel in
  write ?durable
    (fid_marker (path t (Names.parent_of rel)) leaf)
    (id ^ "\n" ^ leaf);
  with_fid_index t (fun h -> Hashtbl.replace h id rel)

let ensure_file_id ?durable t rel =
  match file_id t rel with
    | Some id -> id
    | None ->
        let id = Ids.token () in
        set_file_id ?durable t rel id;
        id

let clear_file_id t rel =
  Option.iter
    (fun id ->
      with_fid_index t (fun h ->
          if Hashtbl.find_opt h id = Some rel then Hashtbl.remove h id))
    (file_id t rel);
  let dir = path t (Names.parent_of rel) in
  if Fs.release (fid_marker dir (Names.leaf_of rel)) then Fs.fsync_dir dir

(* Index paths under [src] move to [dst], or go when [dst] is [None]. *)
let move_fid_subtree t ~src ~dst =
  with_fid_index t (fun h ->
      let under =
        Hashtbl.fold
          (fun id p acc ->
            if Names.is_under ~dir:src p then (id, p) :: acc else acc)
          h []
      in
      List.iter
        (fun (id, p) ->
          match dst with
            | Some dst ->
                Hashtbl.replace h id
                  (dst
                  ^ String.sub p (String.length src)
                      (String.length p - String.length src))
            | None -> Hashtbl.remove h id)
        under)

(* Every write stamps the recorded name, and replaces the entry whole; a path
   keeps its file id across replacements. *)
let write_file ?durable ?(own = false) t rel (m : Manifest.t) =
  ensure_dirs t (Names.parent_of rel);
  check_handle t rel;
  let m = Manifest.rename m (Names.leaf_of rel) in
  if not own then clear_own t rel;
  write ?durable (path t rel) m.body;
  ignore (ensure_file_id ?durable t rel);
  if own then set_own t rel

let remove_file t rel =
  clear_own t rel;
  let p = path t rel in
  if Fs.release p then Fs.fsync_dir (Filename.dirname p);
  clear_file_id t rel

let md5_hex s = Digest.to_hex (Digest.string s)

let removed_record t rel =
  Filename.concat t.by_path (md5_hex (t.key_prefix ^ rel))

let reverse_entry t id = Filename.concat t.folders (Folder_id.to_string id)

let write_reverse ?durable t rel id =
  match if rel = "" then None else folder_id t (Names.parent_of rel) with
    | Some parent when not (Folder_id.is_root id) ->
        Fs.mkdir_p t.folders;
        write_if_changed ?durable (reverse_entry t id)
          (Yojson.Safe.to_string
             (`Assoc
                [
                  ("parent", `String (Folder_id.to_string parent));
                  ("name", `String (Names.leaf_of rel));
                ]))
    | _ -> ()

let write_removed ?durable t rel id =
  Fs.mkdir_p t.by_path;
  write_if_changed ?durable (removed_record t rel) (Folder_id.to_string id)

(* 04 §4.9 [replace]: the directory chain, the name marker, the folder marker,
   the removed-id record, and the reverse entry with the leaf of [rel]. *)
let replace_folder ?durable t rel id =
  if rel <> "" then (
    ensure_dirs t rel;
    let p = path t rel in
    let leaf = Names.leaf_of rel in
    if Names.escape leaf <> leaf then
      write_if_changed ?durable (name_marker p) leaf;
    write_if_changed ?durable (dir_marker p)
      (Folder.marker_body { name = leaf; id });
    write_removed ?durable t rel id;
    write_reverse ?durable t rel id)

(* A lookup never mints; [record] answers what changed. *)
let record_folder ?durable ?(on_other = `Replace) t rel id =
  match (Fs.lstat_opt (path t rel), folder_id t rel) with
    | Some { st_kind = S_DIR; _ }, Some held when Folder_id.equal held id ->
        replace_folder ?durable t rel id;
        `Same
    | Some { st_kind = S_DIR; _ }, Some held -> (
        match on_other with
          | `Keep -> `Held held
          | `Replace ->
              replace_folder ?durable t rel id;
              `Replaced held)
    | _ ->
        replace_folder ?durable t rel id;
        `Changed

let mkdir_without_id t rel = ensure_dirs t rel

let remove_folder t rel =
  move_fid_subtree t ~src:rel ~dst:None;
  let p = path t rel in
  Fs.rm_rf p;
  Fs.fsync_dir (Filename.dirname p)

let lookup_id_removed t rel =
  match folder_id t rel with
    | Some id -> Some id
    | None ->
        Option.bind
          (Fs.read_file_opt (removed_record t rel))
          (fun s -> Folder_id.of_string (String.trim s))

let key_of_id t id =
  if Folder_id.is_root id then Some ""
  else (
    let rec climb id seen acc =
      if Folder_id.is_root id then Some (String.concat "/" acc)
      else if List.exists (Folder_id.equal id) seen then None
      else (
        match
          Option.bind
            (Fs.read_file_opt (reverse_entry t id))
            (fun b -> try Some (Yojson.Safe.from_string b) with _ -> None)
        with
          | Some (`Assoc f) -> (
              match (List.assoc_opt "parent" f, List.assoc_opt "name" f) with
                | Some (`String p), Some (`String n) -> (
                    match Folder_id.of_string p with
                      | Some pid -> climb pid (id :: seen) (n :: acc)
                      | None -> None)
                | _ -> None)
          | _ -> None)
    in
    match climb id [] [] with
      | Some path
        when match folder_id t path with
               | Some x -> Folder_id.equal x id
               | None -> false ->
          Some path
      | _ -> None)

let whereabouts t rel =
  match folder_id t rel with
    | Some id -> `Live id
    | None -> (
        match lookup_id_removed t rel with
          | Some id -> (
              match key_of_id t id with
                | Some at -> `Moved (id, at)
                | None -> `Removed id)
          | None -> `Unknown)

(* The one routine that moves a folder: directory, name marker, folder
   marker's name, removed-id record and reverse entry together. *)
let move_folder t ~src ~dst =
  ensure_dirs t (Names.parent_of dst);
  check_handle t dst;
  let id = folder_id t src in
  Fs.rename (path t src) (path t dst);
  move_fid_subtree t ~src ~dst:(Some dst);
  Fs.fsync_dir (Filename.dirname (path t src));
  Fs.fsync_dir (Filename.dirname (path t dst));
  let p = path t dst and leaf = Names.leaf_of dst in
  if Names.escape leaf <> leaf then write (name_marker p) leaf
  else Fs.unlink_quiet (name_marker p);
  Option.iter (fun id -> replace_folder t dst id) id

(* The file id goes first, so the destination entry is never written under
   another id; a staged-only file has a marker and no entry. *)
let move_file t ~src ~dst =
  let fid = file_id t src in
  ensure_dirs t (Names.parent_of dst);
  (match fid with
    | Some id -> set_file_id t dst id
    | None -> clear_file_id t dst);
  (match manifest t src with
    | Some m ->
        let own = is_own t src in
        write_file ~own t dst m;
        remove_file t src
    | None -> (
        match Fs.lstat_opt (path t src) with
          | Some _ -> Fs.rename (path t src) (path t dst)
          | None -> ()));
  clear_file_id t src

type child = {
  name : string;
  kind : [ `Dir of Folder_id.t option | `File of Manifest.t ];
}

let list t rel =
  let dir = path t rel in
  match Fs.readdir_opt dir with
    | None -> []
    | Some names ->
        List.filter_map
          (fun local ->
            if Names.is_internal_local local || Names.is_temp_name local then
              None
            else (
              let p = Filename.concat dir local in
              match Fs.lstat_opt p with
                | Some { st_kind = S_DIR; _ } ->
                    Option.map
                      (fun name ->
                        {
                          name;
                          kind = `Dir (folder_id t (Names.join rel name));
                        })
                      (real_name dir local)
                | Some { st_kind = S_REG; _ } -> (
                    match Option.bind (Fs.read_file_opt p) Manifest.decode with
                      | Some m ->
                          Some
                            {
                              name =
                                (if
                                   String.starts_with
                                     ~prefix:Names.escape_prefix local
                                 then m.name
                                 else local);
                              kind = `File m;
                            }
                      | None -> None)
                | _ -> None))
          names

let dir_mtime t rel =
  match Fs.lstat_opt (path t rel) with Some st -> st.st_mtime | None -> 0.

(* 04 §4.9 [rebuild]: re-derive every reverse entry from the markers; a folder
   without a marker cuts its subtree's chain. *)
let rebuild_index t =
  let written = Hashtbl.create 1024 in
  let rec walk rel =
    List.iter
      (fun c ->
        match c.kind with
          | `Dir (Some id) ->
              let r = Names.join rel c.name in
              write_reverse ~durable:false t r id;
              Hashtbl.replace written (Folder_id.to_string id) ();
              walk r
          | `Dir None | `File _ -> ())
      (list t rel)
  in
  walk "";
  List.iter
    (fun n ->
      if
        n <> "by-path"
        && (not (Names.is_temp_name n))
        && not (Hashtbl.mem written n)
      then ignore (Fs.release (Filename.concat t.folders n)))
    (Fs.readdir t.folders)

let forget_subtree t rel =
  let rec walk rel =
    List.iter
      (fun c ->
        match c.kind with
          | `Dir _ -> walk (Names.join rel c.name)
          | `File _ -> ())
      (list t rel);
    Fs.unlink_quiet (dir_marker (path t rel))
  in
  walk rel;
  Fs.unlink_quiet (removed_record t rel)

let sweep_removed_records t ~older_than =
  List.iter
    (fun n ->
      let p = Filename.concat t.by_path n in
      match
        ( Fs.lstat_opt p,
          Option.bind (Fs.read_file_opt p) (fun s ->
              Folder_id.of_string (String.trim s)) )
      with
        | Some st, Some id
          when Unix.gettimeofday () -. st.st_mtime > older_than
               && key_of_id t id = None ->
            ignore (Fs.release p)
        | _ -> ())
    (Fs.readdir t.by_path)

(* 04 §4.10 step 8: one flush instead of a fsync per marker. *)
let file_ids_record t = Filename.concat t.root "file-ids-complete"

(* Names come from the directory, not from decoding every manifest: only an
   escaped name is read back from its entry. Once a pass completed, every write
   path gives an id, so later starts skip it (04 §4.10 step 8). *)
let backfill_file_ids t =
  if Fs.exists (file_ids_record t) then 0
  else begin
    let minted = ref 0 and touched = Hashtbl.create 64 in
    let rec walk rel =
      let dir = path t rel in
      List.iter
        (fun local ->
          if not (Names.is_internal_local local || Names.is_temp_name local)
          then (
            match
              (Fs.lstat_opt (Filename.concat dir local), real_name dir local)
            with
              | Some { st_kind = S_DIR; _ }, Some name ->
                  walk (Names.join rel name)
              | Some { st_kind = S_REG; _ }, Some leaf ->
                  let r = Names.join rel leaf in
                  if file_id t r = None then (
                    set_file_id ~durable:false t r (Ids.token ());
                    Hashtbl.replace touched dir ();
                    incr minted)
              | _ -> ()))
        (Option.value ~default:[] (Fs.readdir_opt dir))
    in
    walk "";
    (* Every marker is on disk before the record says the pass completed. *)
    Hashtbl.iter (fun dir () -> Fs.fsync_dir dir) touched;
    Fs.durable_replace (file_ids_record t) "";
    !minted
  end

(* Every marker, a staged-only file's included: those have no entry to list. *)
let scan_file_ids t =
  let h = Hashtbl.create 4096 in
  let rec walk rel =
    let dir = path t rel in
    List.iter
      (fun local ->
        if String.starts_with ~prefix:".tsync-fid-" local then (
          match Fs.read_file_opt (Filename.concat dir local) with
            | Some body when String.length body > 33 && body.[32] = '\n' ->
                let id = String.sub body 0 32 in
                let leaf = String.sub body 33 (String.length body - 33) in
                if Names.valid_file_id id && Names.valid_leaf leaf then
                  Hashtbl.replace h id (Names.join rel leaf)
            | _ -> ()))
      (Option.value ~default:[] (Fs.readdir_opt dir));
    List.iter
      (fun c ->
        match c.kind with
          | `Dir _ -> walk (Names.join rel c.name)
          | `File _ -> ())
      (list t rel)
  in
  walk "";
  h

let path_of_file_id t id =
  let lookup () =
    Mutex.protect t.by_fid_m (fun () ->
        let h =
          match !(t.by_fid) with
            | Some h -> h
            | None ->
                let h = scan_file_ids t in
                t.by_fid := Some h;
                h
        in
        Hashtbl.find_opt h id)
  in
  match lookup () with Some p when file_id t p = Some id -> Some p | _ -> None
