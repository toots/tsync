(* Client-side folder-inode resolution.

   Every folder in the local manifest mirror carries a [.tsync-dir] marker
   holding its stable backend id and its real name (the on-disk directory name
   may be escaped). Resolving a path to a folder id — needed to build backend
   keys under the inode layout — reads these markers; a folder that has content
   but no marker yet is minted one on the spot. The marker format is the same
   {dir,name,id} JSON used for backend folder markers ({!Folder}). *)

open Lwt.Syntax

let marker_name = ".tsync-dir"

let dir_of ~cache_root ~domain_name rel =
  let base = Cache_layout.manifests_dir ~cache_root domain_name in
  if rel = "" then base else Filename.concat base (Name_escape.encode_key rel)

let marker_path ~cache_root ~domain_name rel =
  Filename.concat (dir_of ~cache_root ~domain_name rel) marker_name

let read ~cache_root ~domain_name rel =
  Lwt.catch
    (fun () ->
      let+ s =
        Lwt_unix_retry.with_file ~mode:Lwt_io.Input
          (marker_path ~cache_root ~domain_name rel)
          Lwt_io.read
      in
      Folder.marker_of_string s)
    (fun _ -> Lwt.return_none)

let write ~cache_root ~domain_name rel (m : Folder.marker) =
  let dir = dir_of ~cache_root ~domain_name rel in
  let* () = Fs_util.mkdir_p dir in
  let path = Filename.concat dir marker_name in
  let tmp = path ^ ".tmp" in
  let* () =
    Lwt_unix_retry.with_file ~mode:Lwt_io.Output tmp (fun oc ->
        Lwt_io.write oc (Folder.marker_to_string m))
  in
  Lwt_unix_retry.rename tmp path

(* Folder id of [rel] — the root when empty; minted and persisted when a folder
   has no marker yet. *)
let resolve ~cache_root ~domain_name rel =
  if rel = "" then Lwt.return Folder.root_id
  else
    let* existing = read ~cache_root ~domain_name rel in
    match existing with
      | Some m -> Lwt.return m.Folder.id
      | None ->
          let m =
            { Folder.name = Filename.basename rel; id = Folder.new_id () }
          in
          let+ () = write ~cache_root ~domain_name rel m in
          m.Folder.id
