(* How a logical manifest key ([domain_prefix ^ real-path]) maps to the key an
   object lives under. Behind one module type, so call sites speak only in
   logical keys through {!Store}. [Lwt] because the inode scheme resolves folder
   ids from local state. *)
module type S = sig
  (** Logical manifest key (or directory prefix) -> backend key, resolving only
      folder ids this client already holds: [None] when one is unknown.

      The plain name is the one that changes nothing, so a call site that has
      not thought about it gets the harmless behaviour. *)
  val manifest_key : Logical_key.t -> Stored_key.t option Lwt.t

  (** {!manifest_key}, minting and persisting any missing folder id. Only for a
      caller entitled to bring a folder into existence: the marker a mint
      persists re-creates the local directory the key names. *)
  val ensure_manifest_key : Logical_key.t -> Stored_key.t Lwt.t

  (** For a directory's logical key: the backend key of its folder marker (under
      the parent's namespace) and the marker's JSON body, or [None] for layouts
      with no folder tree. Mints the folder's own id — this is what records a
      directory's existence, and what lets resync rebuild the structure. *)
  val ensure_folder_marker :
    Logical_key.t -> (Stored_key.t * string) option Lwt.t

  (** Just the marker's backend key, minting nothing: a caller moving or
      removing a marker does so once the local directory is gone, and an
      unresolvable id names a marker that cannot exist. *)
  val folder_marker_key : Logical_key.t -> Stored_key.t option Lwt.t

  (** The id naming a directory's own namespace, minted if this client has none.
      For callers moving a folder around (rmdir into the trash), which need it
      without the marker body {!ensure_folder_marker} builds. *)
  val ensure_folder_id : Logical_key.t -> string Lwt.t
end

(* [manifests/<parent_folder_id>/<hash(leaf)>], the parent id resolved from the
   local [.tsync-dir] markers, so a folder rename never changes its descendants'
   keys. A directory prefix maps to [manifests/<id>/]. *)
module Inode = struct
  module Make (C : Conf.S) : S = struct
    open Lwt.Syntax

    let lookup_id key =
      Folder_ids_lwt.lookup_id ~cache_root:C.cache_root
        ~domain_name:C.domain_name key

    let rel_of = Logical_key.path

    let child_key ~folder_id leaf =
      Stored_key.child_key ~prefix:C.domain_prefix ~folder_id leaf

    (* A store that cannot arbitrate falls back to minting locally, said once
       because it is a real weakening: two clients creating one directory can
       then still strand each other. *)
    let warned_unarbitrated = ref false

    (* A folder's id is claimed from the store rather than chosen here: two
       clients that have not yet seen each other would both mint and both write
       the same marker key, the second silently taking the name and leaving the
       first's namespace unreachable. The marker {i is} the claim, so every
       client puts its children under the id the store accepted.

       Still local-first: a folder already resolved costs no round trip. *)
    let rec ensure_id key =
      if Logical_key.is_root key then Lwt.return Stored_key.root_id
      else
        let* known = lookup_id key in
        match known with
          | Some id -> Lwt.return id
          | None ->
              let name = Logical_key.leaf key in
              (* The parent is claimed first, so the key this claim names is
                 already the agreed one. *)
              let* pid = ensure_id (Logical_key.parent key) in
              let candidate = { Folder.name; id = Stored_key.new_id () } in
              let bkey = child_key ~folder_id:pid name in
              let module B = (val C.store : Backend_lwt.Store) in
              let* held =
                Lwt.catch
                  (fun () ->
                    B.put_if_absent ~key:bkey
                      ~data:
                        (Bigstring.of_string
                           (Folder.marker_to_string candidate))
                      ())
                  (fun exn ->
                    if not !warned_unarbitrated then begin
                      warned_unarbitrated := true;
                      Log.warn
                        "%s: this store cannot claim a name (%s); folder \
                         ids                          are minted locally and \
                         concurrent creation of one                          \
                         directory can strand files"
                        C.domain_name (Printexc.to_string exn)
                    end;
                    Lwt.return
                      (Bigstring.of_string (Folder.marker_to_string candidate)))
              in
              let winner =
                Option.value
                  (Folder.marker_of_string (Bigstring.to_string held))
                  ~default:candidate
              in
              let+ () =
                Folder_ids_lwt.write ~cache_root:C.cache_root
                  ~domain_name:C.domain_name key winner
              in
              winner.Folder.id

    (* A folder is not filed as a manifest — it is named by its marker under the
       parent's namespace — so this resolves a file either way. *)
    let ensure_manifest_key key =
      let+ pid = ensure_id (Logical_key.parent key) in
      child_key ~folder_id:pid (Logical_key.leaf key)

    (* Same mapping, resolving only what is already known. *)
    let manifest_key key =
      let+ pid = lookup_id (Logical_key.parent key) in
      Option.map
        (fun pid -> child_key ~folder_id:pid (Logical_key.leaf key))
        pid

    let ensure_folder_id key = ensure_id key

    let folder_marker_key key =
      if Logical_key.is_root key then Lwt.return_none
      else
        let+ pid = lookup_id (Logical_key.parent key) in
        Option.map
          (fun pid -> child_key ~folder_id:pid (Logical_key.leaf key))
          pid

    (* Both ids are minted if missing: the folder's own because the marker is
       what gives it one, the parent's because a marker must be filed under a
       namespace even on a client that has not learned the parent. *)
    let ensure_folder_marker key =
      if Logical_key.is_root key then Lwt.return_none
      else
        let* pid = ensure_id (Logical_key.parent key) in
        let+ id = ensure_id key in
        Some
          ( child_key ~folder_id:pid (Logical_key.leaf key),
            Folder.marker_to_string { Folder.name = Logical_key.leaf key; id }
          )
  end
end

(* The logical key already is the backend key, so callers holding inode-space
   keys and no path (share serving walks the folder tree by id) can reuse the
   path-keyed read machinery. Read-only: there is no folder tree to record. *)
module Identity : S = struct
  (* This layout's space is the logical spelling itself, so a key is a path
     under no prefix at all. *)
  let of_logical key =
    Stored_key.in_space ~prefix:"" (Logical_key.to_string key)

  let manifest_key key = Lwt.return_some (of_logical key)
  let ensure_manifest_key key = Lwt.return (of_logical key)
  let ensure_folder_marker _ = Lwt.return_none
  let folder_marker_key _ = Lwt.return_none

  (* The key already names the namespace; there is no path to resolve. *)
  let ensure_folder_id key = Lwt.return (Logical_key.leaf key)
end
