(* The backend naming scheme: how a logical manifest key (the in-memory
   [domain_prefix ^ real-path]) maps to the key an object actually lives under.

   Keeping it behind one module type confines the scheme to a single place — call
   sites speak only in logical keys through {!Store}. The mapping is [Lwt] because
   the inode scheme resolves folder ids from local state. *)
module type S = sig
  (** Logical manifest key (or directory prefix) -> backend key. *)
  val manifest_key : string -> string Lwt.t

  (** For a directory's logical key, the backend key of its folder marker (under
      the parent's namespace) and the marker's JSON body — or [None] for layouts
      with no folder tree. Lets resync reconstruct the directory structure. *)
  val folder_marker : string -> (string * string) option Lwt.t

  (** Just the marker's backend key. Unlike {!folder_marker} this resolves only
      the parent, never the folder's own id — the caller that moves or removes a
      marker does so once the local directory has already gone, and resolving an
      id mints and persists one, recreating it. *)
  val folder_marker_key : string -> string option Lwt.t

  (** The id naming a directory's own namespace. Callers moving a folder around
      (rmdir into the trash) need it on its own, without the marker body
      {!folder_marker} builds. *)
  val folder_id : string -> string Lwt.t
end

(* Inode scheme: [manifests/<parent_folder_id>/<hash(leaf)>]. The parent folder
   id is resolved from the local [.tsync-dir] markers, so a folder rename never
   changes its descendants' keys. A directory prefix (trailing "/") maps to the
   folder's own namespace [manifests/<id>/]. *)
module Inode = struct
  module Make (C : Conf.S) : S = struct
    open Lwt.Syntax

    (* Minting one when the folder has no marker yet — see {!Folder_ids}. *)
    let ensure_id rel =
      Folder_ids.ensure_id ~cache_root:C.cache_root ~domain_name:C.domain_name
        rel

    let rel_of = Key.strip_prefix ~domain_prefix:C.domain_prefix

    (* Backend key of [leaf] within its parent folder's namespace. *)
    let child_key ~folder_id leaf =
      C.domain_prefix ^ Folder.child_key ~folder_id leaf

    let manifest_key key =
      let rel = rel_of key in
      if Key.is_dir rel then
        (* a directory prefix maps to the folder's own namespace *)
        let+ id = ensure_id (Key.chop_slash rel) in
        C.domain_prefix ^ id ^ "/"
      else
        let+ pid = ensure_id (Key.parent rel) in
        child_key ~folder_id:pid (Filename.basename rel)

    let folder_id key = ensure_id (Key.chop_slash (rel_of key))

    (* Only the parent is resolved: a caller wanting the marker's key alone must
       not touch the folder's own id, because resolving one mints and persists
       it — recreating a local directory that has just been renamed away. *)
    let folder_marker_key key =
      let rel = Key.chop_slash (rel_of key) in
      if rel = "" then Lwt.return_none
      else
        let+ pid = ensure_id (Key.parent rel) in
        Some (child_key ~folder_id:pid (Filename.basename rel))

    let folder_marker key =
      let rel = Key.chop_slash (rel_of key) in
      let* bkey = folder_marker_key key in
      match bkey with
        | None -> Lwt.return_none
        | Some bkey ->
            let+ id = ensure_id rel in
            Some
              ( bkey,
                Folder.marker_to_string
                  { Folder.name = Filename.basename rel; id } )
  end
end

(* Identity scheme: the logical key already *is* the backend key. For callers
   that hold inode-space keys and no path (share serving walks the folder tree by
   id), so they can reuse the path-keyed read machinery unchanged. Read-only:
   there is no folder tree to record. *)
module Identity : S = struct
  let manifest_key key = Lwt.return key
  let folder_marker _ = Lwt.return_none
  let folder_marker_key _ = Lwt.return_none

  (* The key already names the namespace; there is no path to resolve. *)
  let folder_id key = Lwt.return (Filename.basename (Key.chop_slash key))
end
