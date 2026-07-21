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

    (* Logical key -> domain-relative real path. *)
    let rel_of key =
      if String.starts_with ~prefix:C.domain_prefix key then (
        let n = String.length C.domain_prefix in
        String.sub key n (String.length key - n))
      else key

    let chop_slash s =
      if String.ends_with ~suffix:"/" s then String.sub s 0 (String.length s - 1)
      else s

    let parent rel = match Filename.dirname rel with "." -> "" | d -> d

    let manifest_key key =
      let rel = rel_of key in
      if String.ends_with ~suffix:"/" rel then
        (* a directory prefix maps to the folder's own namespace *)
        let+ id = resolve (chop_slash rel) in
        C.domain_prefix ^ id ^ "/"
      else
        let+ pid = resolve (parent rel) in
        C.domain_prefix
        ^ Folder.child_key ~folder_id:pid (Filename.basename rel)

    let folder_marker key =
      let rel = chop_slash (rel_of key) in
      if rel = "" then Lwt.return_none
      else (
        let leaf = Filename.basename rel in
        let* pid = resolve (parent rel) in
        let+ id = resolve rel in
        let bkey = C.domain_prefix ^ Folder.child_key ~folder_id:pid leaf in
        Some (bkey, Folder.marker_to_string { Folder.name = leaf; id }))
  end
end
