open Manifest

(* The tree mirrors real paths: directories are real directories, and a name the
   filesystem cannot hold verbatim becomes an escaped handle plus a marker file
   carrying the real one. *)

open Lwt.Syntax

type listed = { key : Logical_key.t; size : int; mtime : float }

let dir ~cache_root domain_name =
  Cache_layout.manifests_dir ~cache_root domain_name

let sidecar_path = Cache_layout.manifest_path

(* Synchronous, for the CLI listing (plain non-Lwt code).

   ponytail: a bool, so a partly cached file reads as remote. Return the chunk
   counts here if `tsync ls` should distinguish "partial n/m". *)
let is_local
    ({ Conf.cache_root; domain_name; cache_chunk_size } : Conf.locality) key =
  Sys.file_exists (Staged_manifest.sidecar_path ~cache_root ~domain_name key)
  ||
    match of_file (sidecar_path ~cache_root ~domain_name key) with
    | m ->
        List.for_all
          (fun g ->
            Sys.file_exists
              (Cache_layout.chunk_path ~cache_root ~domain_name
                 (Manifest.Group.key g)))
          (Manifest.Group.all ~table:m
             ~per:
               (Conf.chunks_per_group ~chunk_size:(chunk_size m)
                  ~cache_chunk_size))
    | exception _ -> false

(* Mapped, not read: a listing wants name, size and mtime, and never touches the
   chunk keys. *)
let read_clean path =
  Lwt.return (match of_file path with m -> Some m | exception _ -> None)

(* Escaped names are resolved through their markers, so the [rel] a walk hands
   out is always real-path shaped. *)
let real_file_name name m =
  if Stored_key.is_escaped name then recorded_name m else name

let rec clean_tmp dir =
  let* is_dir = Io_lwt.Fs.is_directory dir in
  if not is_dir then Lwt.return_unit
  else
    let* names = Io_lwt.Fs.readdir_list dir in
    Lwt_list.iter_s
      (fun name ->
        let path = Filename.concat dir name in
        let* is_dir = Io_lwt.Fs.is_directory path in
        if is_dir then clean_tmp path
        else if Filename.is_temp_name name then Io_lwt.Fs.unlink_quiet path
        else Lwt.return_unit)
      names

(* The store, per domain: manifests keyed by logical key and nothing else. *)
module Make (C : Conf.S) = struct
  module Lk = Logical_key.Make (C)
  module Sm = Staged_lwt.Manifest.Make (C)
  module Mf = Manifests_lwt.Make (C)

  let rel_of = Logical_key.path

  (* A directory keeps its real name in a marker beside it, for the same reason
     a manifest keeps one in its body: an escaped on-disk name is a hash. *)
  let refresh_dir_marker key =
    let leaf = Logical_key.leaf key in
    if leaf = "" || not (Stored_key.is_escaped (Stored_key.escape leaf)) then
      Lwt.return_unit
    else
      Io_lwt.Fs.atomic_write
        (Filename.concat (Mf.path key) Stored_key.dir_name_leaf)
        leaf

  (* Moving is half of a rename: whatever records the name — a manifest's body
     for a file, and for a directory both the marker beside it and the folder's
     own — has to be brought to the destination's, and all of it is done here so
     no caller need know which it moved, nor remember that a folder unreparented
     is a folder unreachable by id. *)
  let rename ~src_key ~dst_key =
    Mf.forget src_key;
    Mf.forget dst_key;
    let src = Mf.path src_key in
    let* exists = Io_lwt.Retry.file_exists src in
    if not exists then Lwt.return_unit
    else (
      let dst = Mf.path dst_key in
      let* () = Mf.ensure_parent dst_key in
      let* () = Io_lwt.Retry.rename src dst in
      let* is_dir = Io_lwt.Fs.is_directory dst in
      if is_dir then
        let* () = refresh_dir_marker dst_key in
        Folder_ids_lwt.reparent ~cache_root:C.cache_root
          ~domain_name:C.domain_name dst_key
      else (
        match of_file dst with
          | m -> Mf.write dst_key m
          | exception _ -> Lwt.return_unit))

  (* The mirror is the directory structure: directories exist only here. *)
  let create_dir key = Manifests_lwt.ensure_dirs (Mf.root ()) (rel_of key)
  let delete_dir key = Io_lwt.Fs.rm_rf (Mf.path key)

  (* Staged entries win for the same key.
     ponytail: quadratic in (staged × published); staged files are the handful
     currently being written, so make it a table only if that stops being true. *)
  let staged_listed ~rel_dir ~deep =
    let+ staged = Sm.entries ~rel_dir ~deep in
    List.map
      (fun (key, (st : Staged_manifest.staged)) ->
        {
          key;
          size = Int64.to_int st.Staged_manifest.s_size;
          mtime = st.Staged_manifest.s_mtime;
        })
      staged

  (* Staged wins: what is owed is what a reader will get next. *)
  let merge_entries published staged =
    staged
    @ List.filter
        (fun p ->
          not (List.exists (fun s -> Logical_key.equal s.key p.key) staged))
        published

  (* Either tree may be missing: the published one right after a full resync
     clears it, the staged one whenever nothing is being written. *)
  let readdir_opt dir =
    let* is_dir = Io_lwt.Fs.is_directory dir in
    if is_dir then Io_lwt.Fs.readdir_list dir else Lwt.return_nil

  let dir_of_prefix prefix = (rel_of prefix, Mf.path prefix)

  let list_children ~prefix () =
    let rel, dir = dir_of_prefix prefix in
    let* staged = staged_listed ~rel_dir:rel ~deep:false in
    let child_dir = Lk.dir rel in
    let* names = readdir_opt dir in
    let+ files, dirs =
      Lwt_list.fold_left_s
        (fun (files, dirs) name ->
          if Stored_key.internal_leaf name then Lwt.return (files, dirs)
          else (
            let path = Filename.concat dir name in
            let* is_dir = Io_lwt.Fs.is_directory path in
            if is_dir then
              let+ real = Cache_layout_lwt.real_dir_name path name in
              (files, real :: dirs)
            else
              let+ m = read_clean path in
              match m with
                | Some m ->
                    ( {
                        key =
                          Logical_key.file_in child_dir (real_file_name name m);
                        size = Int64.to_int (size m);
                        mtime = mtime m;
                      }
                      :: files,
                      dirs )
                | None -> (files, dirs)))
        ([], []) names
    in
    (merge_entries files staged, dirs)

  (* Backend keys are hashed, so only the mirror can answer this. *)
  (* Inside the functor because it hands back the key each file is filed under,
     which needs the domain the walk belongs to. *)
  let fold_files ~start ~key f acc =
    let rec walk dir key acc =
      let* names = Io_lwt.Fs.readdir_list dir in
      Lwt_list.fold_left_s
        (fun acc name ->
          if Stored_key.internal_leaf name then Lwt.return acc
          else (
            let path = Filename.concat dir name in
            let* is_dir = Io_lwt.Fs.is_directory path in
            if is_dir then
              let* real = Cache_layout_lwt.real_dir_name path name in
              walk path (Logical_key.dir_in key real) acc
            else
              let+ m = read_clean path in
              match m with
                | Some m ->
                    f acc (Logical_key.file_in key (real_file_name name m)) m
                | None -> acc))
        acc names
    in
    let* ok = Io_lwt.Fs.is_directory start in
    if ok then walk start key acc else Lwt.return acc

  let list_tree ~prefix () =
    let rel, start = dir_of_prefix prefix in
    let* published =
      fold_files ~start ~key:(Lk.dir rel)
        (fun acc key m ->
          { key; size = Int64.to_int (size m); mtime = mtime m } :: acc)
        []
    in
    let+ staged = staged_listed ~rel_dir:rel ~deep:true in
    merge_entries published staged

  (* Published or only staged, unsorted. *)
  let walk () =
    let* published =
      fold_files ~start:(Mf.root ()) ~key:Lk.root
        (fun acc key (_ : t) -> Logical_key.path key :: acc)
        []
    in
    let+ staged =
      Sm.fold ~rel_dir:"" ~deep:true
        (fun acc key (_ : Staged_manifest.staged) ->
          Logical_key.path key :: acc)
        []
    in
    List.sort_uniq compare (published @ staged)

  let ensure_root () = Io_lwt.Fs.mkdir_p (Mf.root ())

  let reap_leftovers () =
    let* () = ensure_root () in
    clean_tmp (Mf.root ())
end
