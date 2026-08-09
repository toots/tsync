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

(* Sharded by {!Chunk_layout}, like the backend chunk store. *)
let chunk_path ~cache_root ~domain_name chunk_key =
  Filename.concat
    (chunks_dir ~cache_root domain_name)
    (Chunk_layout.relative_path chunk_key)

(* For a full resync that rebuilds from the backend. Staged edits are kept:
   nothing else holds those bytes. *)
let clear ~cache_root ~domain_name =
  let open Lwt.Syntax in
  let* () = Fs_util.rm_rf (manifests_dir ~cache_root domain_name) in
  let* () = Fs_util.rm_rf (scratch_dir ~cache_root domain_name) in
  let* () = Fs_util.rm_rf (folders_dir ~cache_root domain_name) in
  Fs_util.rm_rf (chunks_dir ~cache_root domain_name)
