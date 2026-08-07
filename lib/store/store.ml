(* Manifest-level backend access keyed by logical keys, mapped to backend keys
   through the {!Layout} scheme so callers never construct one. Writes fan out to
   all backends; reads use the primary. Chunk, journal and cursor I/O are not
   manifest keys and stay in {!File_store}/{!Remote}. *)

open Lwt.Syntax

module Make (C : Conf.S) (L : Layout.S) = struct
  module Bk = Backends.Make (C)

  let primary = Bk.primary

  (* Publishing may bring the folder into existence; every other operation
     resolves what is already there and treats an unknown folder as absent. *)
  let put_manifest ~key ~data =
    let* bk = L.ensure_manifest_key key in
    Bk.put ~key:bk ~data

  let get_manifest ~key =
    let* bk = L.manifest_key key in
    match bk with
      | None -> Lwt.fail Not_found
      | Some bk ->
          let (module B : Backend.S) = primary () in
          B.get ~key:bk ()

  let get_manifest_opt ~key =
    let* bk = L.manifest_key key in
    match bk with
      | None -> Lwt.return_none
      | Some bk ->
          let (module B : Backend.S) = primary () in
          B.get_opt ~key:bk ()

  let head_manifest ~key =
    let* bk = L.manifest_key key in
    match bk with
      | None -> Lwt.return_none
      | Some bk ->
          let (module B : Backend.S) = primary () in
          B.head_opt ~key:bk ()

  let delete_manifest ~key =
    let* bk = L.manifest_key key in
    match bk with None -> Lwt.return_unit | Some bk -> Bk.delete ~key:bk

  (* The destination may be brought into existence; the source has to be there
     already or there is nothing to move. *)
  let copy_manifest ~src_key ~dst_key =
    let* src = L.manifest_key src_key in
    match src with
      | None -> Lwt.return_unit
      | Some src ->
          let* dst = L.ensure_manifest_key dst_key in
          Bk.all (fun (module B : Backend.S) ->
              let* () = B.copy ~src_key:src ~dst_key:dst () in
              B.delete ~key:src ())

  (* [<versions>/<manifest-key-tail>/<ts>], so versions share the manifest's
     identity — a stable folder id — and survive a folder rename. *)
  let version_dir ~key =
    let+ bk = L.manifest_key key in
    Option.map
      (fun bk ->
        C.versions_prefix
        ^ Key.strip_prefix ~domain_prefix:C.domain_prefix bk
        ^ "/")
      bk

  (* Snapshot the current manifest object under a fresh timestamped version key,
     when it exists on the backend. Best-effort: the source is only checked on
     the primary, so a replica that never got it fails the copy — and a lost
     snapshot must not wedge the write it precedes. *)
  let save_version ~key =
    let* bk = L.manifest_key key in
    match bk with
      | None -> Lwt.return_unit
      | Some bk -> (
          let (module Pri : Backend.S) = primary () in
          let* head = Pri.head_opt ~key:bk () in
          match head with
            | None -> Lwt.return_unit
            | Some _ -> (
                let ts = Int64.of_float (Unix.gettimeofday () *. 1e9) in
                let* dir = version_dir ~key in
                match dir with
                  | None -> Lwt.return_unit
                  | Some dir ->
                      Lwt.catch
                        (fun () ->
                          Bk.copy ~src_key:bk ~dst_key:(dir ^ Int64.to_string ts))
                        (fun exn ->
                          Log.warn "save_version %s: %s" key
                            (Printexc.to_string exn);
                          Lwt.return_unit)))

  let list_versions ~key =
    let* dir = version_dir ~key in
    match dir with
      | None -> Lwt.return_nil
      | Some dir ->
          let (module Pri : Backend.S) = primary () in
          Pri.list_prefix ~prefix:dir ()

  let get_version ~vkey =
    let (module Pri : Backend.S) = primary () in
    Pri.get ~key:vkey ()

  (* Records a directory under its parent's namespace so resync can rebuild the
     tree. No-op for layouts with no folder tree. *)
  let put_folder_marker ~key =
    let* m = L.ensure_folder_marker key in
    match m with
      | None -> Lwt.return_unit
      | Some (bkey, data) -> Bk.put ~key:bkey ~data

  let delete_folder_marker ~key =
    let* bkey = L.folder_marker_key key in
    match bkey with None -> Lwt.return_unit | Some bkey -> Bk.delete ~key:bkey

  (* Direct children (file manifests and folder markers) of a folder namespace,
     and a raw object fetch — used by resync to walk the inode tree by id. *)
  let list_namespace ~folder_id =
    let (module Pri : Backend.S) = primary () in
    Pri.list_prefix ~prefix:(C.domain_prefix ^ folder_id ^ "/") ()

  let get_object ~bkey =
    let (module Pri : Backend.S) = primary () in
    Pri.get ~key:bkey ()

  let delete_raw ~bkey = Bk.delete ~key:bkey
  let put_raw ~bkey ~data = Bk.put ~key:bkey ~data
end
