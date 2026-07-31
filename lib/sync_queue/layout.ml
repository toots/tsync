(* The backend naming scheme: how a logical manifest key (the in-memory
   [domain_prefix ^ real-path]) maps to the key an object actually lives under.

   Keeping it behind one module type confines the scheme to a single place — call
   sites speak only in logical keys through {!Store}. The mapping is [Lwt] because
   the inode scheme resolves folder ids from local state. *)
module type S = sig
  (** Logical manifest key (or directory prefix) -> backend key, resolving only
      folder ids this client already holds: [None] when one is unknown.

      The plain name is the one that changes nothing, so a call site that has
      not thought about it gets the harmless behaviour. *)
  val manifest_key : string -> string option Lwt.t

  (** {!manifest_key}, minting and persisting any folder id it is missing. Only
      for a caller entitled to bring a folder into existence — publishing into
      one. A minted id is fresh and random, so it names a namespace the backend
      has never heard of: a reader gains nothing by it and pays for the marker,
      which re-creates the local directory the key names. That is how a stat of
      a deleted folder used to put it back. *)
  val ensure_manifest_key : string -> string Lwt.t

  (** For a directory's logical key, the backend key of its folder marker (under
      the parent's namespace) and the marker's JSON body — or [None] for layouts
      with no folder tree. Lets resync reconstruct the directory structure.
      Mints the folder's own id, which is the point: this is what records a
      directory's existence. *)
  val ensure_folder_marker : string -> (string * string) option Lwt.t

  (** Just the marker's backend key, minting nothing: the caller that moves or
      removes a marker does so once the local directory has already gone, and an
      id it cannot resolve names a marker that cannot exist. *)
  val folder_marker_key : string -> string option Lwt.t

  (** The id naming a directory's own namespace, minted if this client has none.
      Callers moving a folder around (rmdir into the trash) need it on its own,
      without the marker body {!ensure_folder_marker} builds. *)
  val ensure_folder_id : string -> string Lwt.t
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

    let lookup_id rel =
      Folder_ids.lookup_id ~cache_root:C.cache_root ~domain_name:C.domain_name
        rel

    let rel_of = Key.strip_prefix ~domain_prefix:C.domain_prefix

    (* Backend key of [leaf] within its parent folder's namespace. *)
    let child_key ~folder_id leaf =
      C.domain_prefix ^ Folder.child_key ~folder_id leaf

    let ensure_manifest_key key =
      let rel = rel_of key in
      if Key.is_dir rel then
        (* a directory prefix maps to the folder's own namespace *)
        let+ id = ensure_id (Key.chop_slash rel) in
        C.domain_prefix ^ id ^ "/"
      else
        let+ pid = ensure_id (Key.parent rel) in
        child_key ~folder_id:pid (Filename.basename rel)

    (* Same mapping, resolving only what is already known. *)
    let manifest_key key =
      let rel = rel_of key in
      if Key.is_dir rel then
        let+ id = lookup_id (Key.chop_slash rel) in
        Option.map (fun id -> C.domain_prefix ^ id ^ "/") id
      else
        let+ pid = lookup_id (Key.parent rel) in
        Option.map
          (fun pid -> child_key ~folder_id:pid (Filename.basename rel))
          pid

    let ensure_folder_id key = ensure_id (Key.chop_slash (rel_of key))

    let folder_marker_key key =
      let rel = Key.chop_slash (rel_of key) in
      if rel = "" then Lwt.return_none
      else
        let+ pid = lookup_id (Key.parent rel) in
        Option.map
          (fun pid -> child_key ~folder_id:pid (Filename.basename rel))
          pid

    (* Recording a directory: both ids are minted if missing, the folder's own
       because the marker is what gives it one, the parent's because a marker
       has to be filed under a namespace even on a client that has not learned
       the parent yet. *)
    let ensure_folder_marker key =
      let rel = Key.chop_slash (rel_of key) in
      if rel = "" then Lwt.return_none
      else
        let* pid = ensure_id (Key.parent rel) in
        let+ id = ensure_id rel in
        Some
          ( child_key ~folder_id:pid (Filename.basename rel),
            Folder.marker_to_string { Folder.name = Filename.basename rel; id }
          )
  end
end

(* Identity scheme: the logical key already *is* the backend key. For callers
   that hold inode-space keys and no path (share serving walks the folder tree by
   id), so they can reuse the path-keyed read machinery unchanged. Read-only:
   there is no folder tree to record. *)
module Identity : S = struct
  let manifest_key key = Lwt.return_some key
  let ensure_manifest_key key = Lwt.return key
  let ensure_folder_marker _ = Lwt.return_none
  let folder_marker_key _ = Lwt.return_none

  (* The key already names the namespace; there is no path to resolve. *)
  let ensure_folder_id key = Lwt.return (Filename.basename (Key.chop_slash key))
end
