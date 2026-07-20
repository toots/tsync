(* Manifest-level backend access keyed by *logical* keys (domain_prefix ^ real
   path). Every operation maps the logical key to a backend key through the
   {!Layout} scheme, so callers never construct backend keys themselves. Writes
   fan out to all backends; reads use the primary. Chunk, journal and cursor I/O
   are not manifest keys and stay in {!File_store}/{!Remote}. *)

open Lwt.Syntax

module Make (C : Conf.S) (L : Layout.S) = struct
  let primary () =
    match C.backends with
      | b :: _ -> b
      | [] -> failwith "no backends configured"

  let put_manifest ~key ~data =
    let* bk = L.manifest_key key in
    Lwt_list.iter_s
      (fun (module B : Backend.S) -> B.put ~key:bk ~data ())
      C.backends

  let get_manifest ~key =
    let* bk = L.manifest_key key in
    let (module B : Backend.S) = primary () in
    B.get ~key:bk ()

  let get_manifest_opt ~key =
    let* bk = L.manifest_key key in
    let (module B : Backend.S) = primary () in
    B.get_opt ~key:bk ()

  let head_manifest ~key =
    let* bk = L.manifest_key key in
    let (module B : Backend.S) = primary () in
    B.head_opt ~key:bk ()

  let delete_manifest ~key =
    let* bk = L.manifest_key key in
    Lwt_list.iter_s
      (fun (module B : Backend.S) -> B.delete ~key:bk ())
      C.backends

  let copy_manifest ~src_key ~dst_key =
    let* src = L.manifest_key src_key in
    let* dst = L.manifest_key dst_key in
    Lwt_list.iter_s
      (fun (module B : Backend.S) ->
        let* () = B.copy ~src_key:src ~dst_key:dst () in
        B.delete ~key:src ())
      C.backends

  (* List a directory subtree by its logical prefix; returned entries carry
     backend keys (already hashed), used as-is for bulk delete/copy. *)
  let list_subtree ~prefix =
    let* bk = L.manifest_key prefix in
    let (module B : Backend.S) = primary () in
    B.list_all ~prefix:bk ()

  (* Versions mirror the manifest key under the [versions/] prefix: a file's
     versions live at [<versions>/<manifest-key-tail>/<ts>], so they share the
     manifest's identity (a stable folder id under the inode layout) and survive
     a folder rename. *)
  let version_dir ~key =
    let+ bk = L.manifest_key key in
    let tail =
      if String.starts_with ~prefix:C.domain_prefix bk then (
        let n = String.length C.domain_prefix in
        String.sub bk n (String.length bk - n))
      else bk
    in
    C.versions_prefix ^ tail ^ "/"

  (* Snapshot the current manifest object under a fresh timestamped version key,
     when it exists on the backend. *)
  let save_version ~key =
    let* bk = L.manifest_key key in
    let (module Pri : Backend.S) = primary () in
    let* head = Pri.head_opt ~key:bk () in
    match head with
      | None -> Lwt.return_unit
      | Some _ ->
          let ts = Int64.of_float (Unix.gettimeofday () *. 1e9) in
          let* dir = version_dir ~key in
          let dst = dir ^ Int64.to_string ts in
          Lwt_list.iter_s
            (fun (module B : Backend.S) -> B.copy ~src_key:bk ~dst_key:dst ())
            C.backends

  let list_versions ~key =
    let* dir = version_dir ~key in
    let (module Pri : Backend.S) = primary () in
    Pri.list_all ~prefix:dir ()

  let get_version ~vkey =
    let (module Pri : Backend.S) = primary () in
    Pri.get ~key:vkey ()

  (* Folder markers (inode layout): record a directory under its parent's
     namespace so resync can rebuild the tree. No-op for layouts without one. *)
  let put_folder_marker ~key =
    let* m = L.folder_marker key in
    match m with
      | None -> Lwt.return_unit
      | Some (bkey, data) ->
          Lwt_list.iter_s
            (fun (module B : Backend.S) -> B.put ~key:bkey ~data ())
            C.backends

  let delete_folder_marker ~key =
    let* m = L.folder_marker key in
    match m with
      | None -> Lwt.return_unit
      | Some (bkey, _) ->
          Lwt_list.iter_s
            (fun (module B : Backend.S) -> B.delete ~key:bkey ())
            C.backends

  (* Direct children (file manifests and folder markers) of a folder namespace,
     and a raw object fetch — used by resync to walk the inode tree by id. *)
  let list_namespace ~folder_id =
    let (module Pri : Backend.S) = primary () in
    Pri.list_all ~prefix:(C.domain_prefix ^ folder_id ^ "/") ()

  let get_object ~bkey =
    let (module Pri : Backend.S) = primary () in
    Pri.get ~key:bkey ()

  let delete_raw ~bkey =
    Lwt_list.iter_s
      (fun (module B : Backend.S) -> B.delete ~key:bkey ())
      C.backends

  let put_raw ~bkey ~data =
    Lwt_list.iter_s
      (fun (module B : Backend.S) -> B.put ~key:bkey ~data ())
      C.backends
end
