(* The backend naming scheme: how a logical manifest key (the in-memory
   [domain_prefix ^ real-path]) maps to the key an object actually lives under.

   Keeping this behind one module type means the scheme can change — hashed path
   today, folder-inode next — without touching the call sites, which speak only
   in logical keys through {!Store}. The mapping is [Lwt] because the inode
   scheme resolves folder ids from local state. *)
module type S = sig
  (** Logical manifest key (or directory prefix) -> backend key. *)
  val manifest_key : string -> string Lwt.t

  (** For a directory's logical key, the backend key of its folder marker (under
      the parent's namespace) and the marker's JSON body — or [None] for layouts
      with no folder tree. Lets resync reconstruct the directory structure. *)
  val folder_marker : string -> (string * string) option Lwt.t
end

(* Current scheme: replace each real path component with its dual-seed xxHash,
   so keys are fixed-length and filesystem-safe. Pure, wrapped in [Lwt]. *)
module Hashed_path = struct
  module Make (C : Conf.S) : S = struct
    let manifest_key key =
      Lwt.return (Manifest_key.of_key ~domain_prefix:C.domain_prefix key)

    let folder_marker _ = Lwt.return_none
  end
end

(* Inode scheme: [manifests/<parent_folder_id>/<hash(leaf)>]. The parent folder
   id is resolved from the local [.tsync-dir] markers, so a folder rename never
   changes its descendants' keys. A directory prefix (trailing "/") maps to the
   folder's own namespace [manifests/<id>/]. *)
module Inode = struct
  module Make (C : Conf.S) : S = struct
    open Lwt.Syntax

    let resolve rel =
      Folder_ids.resolve ~cache_root:C.cache_root ~domain_name:C.domain_name rel

    let manifest_key key =
      let rel = Manifest_key.rel ~domain_prefix:C.domain_prefix key in
      if String.ends_with ~suffix:"/" rel then (
        let dir_rel = String.sub rel 0 (String.length rel - 1) in
        let+ id = resolve dir_rel in
        C.domain_prefix ^ id ^ "/")
      else (
        let parent = match Filename.dirname rel with "." -> "" | d -> d in
        let+ pid = resolve parent in
        C.domain_prefix
        ^ Folder.child_key ~folder_id:pid (Filename.basename rel))

    let folder_marker key =
      let rel =
        let r = Manifest_key.rel ~domain_prefix:C.domain_prefix key in
        if String.ends_with ~suffix:"/" r then
          String.sub r 0 (String.length r - 1)
        else r
      in
      if rel = "" then Lwt.return_none
      else (
        let parent = match Filename.dirname rel with "." -> "" | d -> d in
        let leaf = Filename.basename rel in
        let* pid = resolve parent in
        let+ id = resolve rel in
        let bkey = C.domain_prefix ^ Folder.child_key ~folder_id:pid leaf in
        Some (bkey, Folder.marker_to_string { Folder.name = leaf; id }))
  end
end
