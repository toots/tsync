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

(* The journal entries this client has already handled, month-sharded as the
   published journal is. *)
let applied_dir ~cache_root domain_name = sub ~cache_root domain_name "applied"

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

let manifest_suffix = ".manifest"

(* Sharded by {!Chunk_layout}, like the backend chunk store. *)
let chunk_path ~cache_root ~domain_name chunk_key =
  Filename.concat
    (chunks_dir ~cache_root domain_name)
    (Chunk_layout.relative_path chunk_key)

let chunk_manifest_path ~cache_root ~domain_name chunk_key =
  chunk_path ~cache_root ~domain_name chunk_key ^ manifest_suffix

(* A component the filesystem cannot hold is stored as a handle, which is lossy,
   so a directory's real name is written beside it. A file needs no marker: its
   manifest body carries the name. *)

(** {!Fs.S} plus the two marker questions {!Make} answers, which is what a
    module of the checkout takes as its filesystem. *)
module type FS = sig
  include Fs.S

  val record_dir_name : string -> string -> unit io
  val real_dir_name : string -> string -> string io
end

module type S = sig
  type 'a io

    val record_dir_name : string -> string -> unit io

    val real_dir_name : string -> string -> string io

    val clear : cache_root:string -> domain_name:string -> unit io
end

module Make
    (Io : Io.S)
    (F : Fs.S with type 'a io := 'a Io.t)
    (Sys : Syscalls.S with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  let record_dir_name path name =
    let* exists = Sys.file_exists path in
    if exists then Io.return () else F.atomic_write path name

  let real_dir_name dir_path name =
    if Stored_key.is_escaped name then
      let+ body =
        F.read_file_opt (Filename.concat dir_path Stored_key.dir_name_leaf)
      in
      Option.value body ~default:""
    else Io.return name

  (* For a full resync that rebuilds from the backend. Staged edits are kept:
     nothing else holds those bytes.

     The applied entries go with the rest of the projection. They describe the
     mirror being replaced, and what they were for -- carrying a reader forward
     from an anchor -- a resync answers by stamping a new token, which expires
     every anchor outstanding. *)
  let clear ~cache_root ~domain_name =
    let* () = F.rm_rf (manifests_dir ~cache_root domain_name) in
    let* () = F.rm_rf (scratch_dir ~cache_root domain_name) in
    let* () = F.rm_rf (folders_dir ~cache_root domain_name) in
    let* () = F.rm_rf (applied_dir ~cache_root domain_name) in
    F.rm_rf (chunks_dir ~cache_root domain_name)
end
