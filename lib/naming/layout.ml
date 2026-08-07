(* How a logical manifest key ([domain_prefix ^ real-path]) maps to the key an
   object lives under. Behind one module type, so call sites speak only in
   logical keys through {!Store}. [Lwt] because the inode scheme resolves folder
   ids from local state. *)
module type S = sig
  (** Logical manifest key (or directory prefix) -> backend key, resolving only
      folder ids this client already holds: [None] when one is unknown.

      The plain name is the one that changes nothing, so a call site that has
      not thought about it gets the harmless behaviour. *)
  val manifest_key : string -> string option Lwt.t

  (** {!manifest_key}, minting and persisting any missing folder id. Only for a
      caller entitled to bring a folder into existence. A minted id is fresh and
      random, naming a namespace the backend never heard of, so a reader gains
      nothing and pays for the marker — which re-creates the local directory the
      key names. *)
  val ensure_manifest_key : string -> string Lwt.t

  (** For a directory's logical key: the backend key of its folder marker (under
      the parent's namespace) and the marker's JSON body, or [None] for layouts
      with no folder tree. Mints the folder's own id — this is what records a
      directory's existence, and what lets resync rebuild the structure. *)
  val ensure_folder_marker : string -> (string * string) option Lwt.t

  (** Just the marker's backend key, minting nothing: a caller moving or
      removing a marker does so once the local directory is gone, and an
      unresolvable id names a marker that cannot exist. *)
  val folder_marker_key : string -> string option Lwt.t

  (** The id naming a directory's own namespace, minted if this client has none.
      For callers moving a folder around (rmdir into the trash), which need it
      without the marker body {!ensure_folder_marker} builds. *)
  val ensure_folder_id : string -> string Lwt.t
end

(* [manifests/<parent_folder_id>/<hash(leaf)>], the parent id resolved from the
   local [.tsync-dir] markers, so a folder rename never changes its descendants'
   keys. A directory prefix maps to [manifests/<id>/]. *)
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
        (* A directory prefix maps to the folder's own namespace. *)
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

    (* Both ids are minted if missing: the folder's own because the marker is
       what gives it one, the parent's because a marker must be filed under a
       namespace even on a client that has not learned the parent. *)
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

(* The logical key already is the backend key, for callers holding inode-space
   keys and no path (share serving walks the folder tree by id) so they can reuse
   the path-keyed read machinery. Read-only: there is no folder tree to
   record. *)
module Identity : S = struct
  let manifest_key key = Lwt.return_some key
  let ensure_manifest_key key = Lwt.return key
  let ensure_folder_marker _ = Lwt.return_none
  let folder_marker_key _ = Lwt.return_none

  (* The key already names the namespace; there is no path to resolve. *)
  let ensure_folder_id key = Lwt.return (Filename.basename (Key.chop_slash key))
end
