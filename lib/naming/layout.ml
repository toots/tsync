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
      caller entitled to bring a folder into existence: the marker a mint
      persists re-creates the local directory the key names. *)
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

    let lookup_id rel =
      Folder_ids.lookup_id ~cache_root:C.cache_root ~domain_name:C.domain_name
        rel

    let rel_of = Key.strip_prefix ~domain_prefix:C.domain_prefix

    let child_key ~folder_id leaf =
      C.domain_prefix ^ Folder.child_key ~folder_id leaf

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
    let rec ensure_id rel =
      if rel = "" then Lwt.return Folder.root_id
      else
        let* known = lookup_id rel in
        match known with
          | Some id -> Lwt.return id
          | None ->
              let name = Filename.basename rel in
              (* The parent is claimed first, so the key this claim names is
                 already the agreed one. *)
              let* pid = ensure_id (Key.parent rel) in
              let candidate = { Folder.name; id = Folder.new_id () } in
              let key = child_key ~folder_id:pid name in
              let module B = (val C.store : Backend.S) in
              let* held =
                Lwt.catch
                  (fun () ->
                    B.put_if_absent ~key
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
                Folder_ids.write ~cache_root:C.cache_root
                  ~domain_name:C.domain_name rel winner
              in
              winner.Folder.id

    let ensure_manifest_key key =
      let rel = rel_of key in
      if Key.is_dir rel then
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

(* The logical key already is the backend key, so callers holding inode-space
   keys and no path (share serving walks the folder tree by id) can reuse the
   path-keyed read machinery. Read-only: there is no folder tree to record. *)
module Identity : S = struct
  let manifest_key key = Lwt.return_some key
  let ensure_manifest_key key = Lwt.return key
  let ensure_folder_marker _ = Lwt.return_none
  let folder_marker_key _ = Lwt.return_none

  (* The key already names the namespace; there is no path to resolve. *)
  let ensure_folder_id key = Lwt.return (Filename.basename (Key.chop_slash key))
end
