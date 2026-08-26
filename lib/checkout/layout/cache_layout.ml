let domain_dir ~cache_root domain_name = Filename.concat cache_root domain_name

let sub ~cache_root domain_name name =
  Filename.concat (domain_dir ~cache_root domain_name) name

let manifests_dir ~cache_root domain_name =
  sub ~cache_root domain_name "manifests"

(* Not exported: the two things under it are what a caller wants. *)
let scratch_dir ~cache_root domain_name = sub ~cache_root domain_name "scratch"

(* The [.tsync-dir] markers say what id a path has; this says where an id lives,
   and is rebuildable from them by whoever keeps both. *)
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

module type FILES = sig
  type 'a io

  val file_exists : string -> bool io
  val atomic_write : string -> string -> unit io
  val read_file_opt : string -> string option io
  val rm_rf : string -> unit io
end

module Make (Io : Io.S) (F : FILES with type 'a io := 'a Io.t) = struct
  let ( let* ) = Io.bind
  let ( let+ ) x f = Io.map f x

  let record_dir_name path name =
    let* exists = F.file_exists path in
    if exists then Io.return () else F.atomic_write path name

  let real_dir_name dir_path name =
    if Stored_key.is_escaped name then
      let+ body =
        F.read_file_opt (Filename.concat dir_path Stored_key.dir_name_leaf)
      in
      Option.value body ~default:""
    else Io.return name

  let clear ~cache_root ~domain_name =
    let* () = F.rm_rf (manifests_dir ~cache_root domain_name) in
    let* () = F.rm_rf (scratch_dir ~cache_root domain_name) in
    let* () = F.rm_rf (folders_dir ~cache_root domain_name) in
    F.rm_rf (chunks_dir ~cache_root domain_name)
end
