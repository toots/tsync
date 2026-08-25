let domain_dir ~cache_root domain_name = Filename.concat cache_root domain_name

let sub ~cache_root domain_name name =
  Filename.concat (domain_dir ~cache_root domain_name) name

let manifests_dir ~cache_root domain_name =
  sub ~cache_root domain_name "manifests"

let scratch_dir ~cache_root domain_name = sub ~cache_root domain_name "scratch"

(* The [.tsync-dir] markers say what id a path has; this says where an id lives,
   and is rebuildable from them — see {!Folder_ids.rebuild}. *)
let folders_dir ~cache_root domain_name = sub ~cache_root domain_name "folders"
let chunks_dir ~cache_root domain_name = sub ~cache_root domain_name "chunks"

let staged_manifests_dir ~cache_root domain_name =
  sub ~cache_root domain_name "staged/manifests"

let staged_chunks_dir ~cache_root domain_name =
  sub ~cache_root domain_name "staged/chunks"

let staged_whole_dir ~cache_root domain_name =
  sub ~cache_root domain_name "staged/whole"

(* A tree that mirrors real paths hands every component to a filesystem, so the
   escaping is {!Stored_key}'s and is applied here rather than by each caller.
   The domain root is the tree itself. *)
let under dir key =
  match Stored_key.escape_path (Logical_key.path key) with
    | "" -> dir
    | rel -> Filename.concat dir rel

let manifest_path ~cache_root ~domain_name key =
  under (manifests_dir ~cache_root domain_name) key

let staged_manifest_path ~cache_root ~domain_name key =
  under (staged_manifests_dir ~cache_root domain_name) key

let scratch_path ~cache_root ~domain_name key =
  under (scratch_dir ~cache_root domain_name) key

(* Sharded by {!Chunk_layout}, like the backend chunk store. *)
let chunk_path ~cache_root ~domain_name chunk_key =
  Filename.concat
    (chunks_dir ~cache_root domain_name)
    (Chunk_layout.relative_path chunk_key)

(* For a full resync that rebuilds from the backend. Staged edits are kept:
   nothing else holds those bytes. *)
(* A component the filesystem cannot hold is stored as a handle, which is lossy,
   so a directory's real name is written beside it. A file needs no marker: its
   manifest body carries the name. *)
let record_dir_name path name =
  let open Lwt.Syntax in
  let* exists = Io_lwt.Retry.file_exists path in
  if exists then Lwt.return_unit else Io_lwt.Fs.atomic_write path name

let real_dir_name dir_path name =
  let open Lwt.Syntax in
  if Stored_key.is_escaped name then
    let+ body =
      Io_lwt.Fs.read_file_opt
        (Filename.concat dir_path Stored_key.dir_name_leaf)
    in
    Option.value body ~default:""
  else Lwt.return name

let clear ~cache_root ~domain_name =
  let open Lwt.Syntax in
  let* () = Io_lwt.Fs.rm_rf (manifests_dir ~cache_root domain_name) in
  let* () = Io_lwt.Fs.rm_rf (scratch_dir ~cache_root domain_name) in
  let* () = Io_lwt.Fs.rm_rf (folders_dir ~cache_root domain_name) in
  Io_lwt.Fs.rm_rf (chunks_dir ~cache_root domain_name)
