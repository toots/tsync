(* Single source of truth for the local cache directory layout, per domain:
     <cache_root>/<domain>/manifests/<real path>   — published manifest mirror
                                                     (+ .tsync-dir / .tsync-name markers)
     <cache_root>/<domain>/scratch/<real path>     — .fuse_hidden* scratch files
     <cache_root>/<domain>/chunks/<xxx>/<key>      — content-addressed cache-chunk store
                                                     (one file per {!Chunk_group})
     <cache_root>/<domain>/staged/manifests/<path> — staged manifests (unsynced edits)
     <cache_root>/<domain>/staged/chunks/<uuid>    — staged chunk bodies
     <cache_root>/<domain>/staged/whole/<uuid>     — whole files handed back by a frontend
     <cache_root>/<domain>/folders/<folder id>     — {parent,name}: the folder tree
                                                     read the other way round
   The manifest and scratch trees mirror each other by real path; both [Local]
   and [Folder_ids] derive their paths from here, so that mirror has exactly one
   definition. Everything under chunks/ and staged/ is keyed by content or by an
   opaque id, so it is independent of any path. *)

let domain_dir ~cache_root domain_name = Filename.concat cache_root domain_name

let sub ~cache_root domain_name name =
  Filename.concat (domain_dir ~cache_root domain_name) name

let manifests_dir ~cache_root domain_name =
  sub ~cache_root domain_name "manifests"

let scratch_dir ~cache_root domain_name = sub ~cache_root domain_name "scratch"

(* The [.tsync-dir] markers say what id a path has. This says where an id lives,
   which is the question an item identifier asks. Derived from the markers and
   rebuildable from them at any time — see {!Folder_ids.rebuild}. *)
let folders_dir ~cache_root domain_name = sub ~cache_root domain_name "folders"
let chunks_dir ~cache_root domain_name = sub ~cache_root domain_name "chunks"

let staged_manifests_dir ~cache_root domain_name =
  sub ~cache_root domain_name "staged/manifests"

let staged_chunks_dir ~cache_root domain_name =
  sub ~cache_root domain_name "staged/chunks"

let staged_whole_dir ~cache_root domain_name =
  sub ~cache_root domain_name "staged/whole"

(* Sharded by {!Chunk_layout}, the same way the backend chunk store is: both are
   keyed by the same fixed-length hex, and neither wants one huge directory. *)
let chunk_path ~cache_root ~domain_name chunk_key =
  Filename.concat
    (chunks_dir ~cache_root domain_name)
    (Chunk_layout.relative_path chunk_key)

(* Remove the domain's local cache — manifest mirror, chunk store and scratch
   tree — for a full resync that rebuilds it from the backend. Staged edits are
   deliberately kept: nothing else holds those bytes. *)
let clear ~cache_root ~domain_name =
  let open Lwt.Syntax in
  let* () = Fs_util.rm_rf (manifests_dir ~cache_root domain_name) in
  let* () = Fs_util.rm_rf (scratch_dir ~cache_root domain_name) in
  let* () = Fs_util.rm_rf (folders_dir ~cache_root domain_name) in
  Fs_util.rm_rf (chunks_dir ~cache_root domain_name)
