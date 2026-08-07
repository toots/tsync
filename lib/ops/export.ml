open Lwt.Syntax

type status = Exported | Exported_symlink | Missing_data
type summary = { exported : int; missing : int }

module Make (C : Conf.S) = struct
  module R = Remote.Make (C)
  module Tree = Inode_tree.Make (C)
  module Mf = Manifest.Make (C)
  module D = Data.Make (C) (R)

  (* Assembling through the read path covers unsynced staged edits, a partially
     cached file and a never-cached one alike. Only symlinks are special, having
     no content. *)
  let export_file ~dst rel =
    let key = C.domain_prefix ^ rel in
    let dst_path = Filename.concat dst rel in
    let* () = Fs_util.ensure_parent dst_path in
    let* manifest = D.resolved_manifest key in
    match manifest with
      | Some { symlink = Some target; _ } ->
          let* () = Fs_util.unlink_quiet dst_path in
          let+ () = Lwt_unix_retry.symlink target dst_path in
          Exported_symlink
      | Some _ ->
          let+ () = D.assemble_to key ~dst_path in
          Exported
      | None ->
          (* A staged file has no published manifest yet, but its content is
             local and readable. *)
          let* staged = Mf.staged_exists key in
          if not staged then Lwt.return Missing_data
          else
            let+ () = D.assemble_to key ~dst_path in
            Exported

  (* Files are the union of the backend listing and the local sidecar tree, which
     adds local-only files whose upload is still pending. *)
  (* Errors are skipped rather than fatal: one unreadable object should cost its
     own file, not the whole export. *)
  let remote_rels () =
    Tree.fold_tree ~skip_errors:true ~folder_id:Folder.root_id ~rel:""
      (fun acc rel entry ->
        match entry.Inode_tree.body with
          | Inode_tree.File m -> Lwt.return (Key.join rel m.Manifest.name :: acc)
          | Inode_tree.Dir _ -> Lwt.return acc)
      []

  let run ~dst ~on_file () =
    let* remote_rels = remote_rels () in
    let* local_rels = Mf.walk () in
    let files = List.sort_uniq compare (remote_rels @ local_rels) in
    let* () = Fs_util.mkdir_p dst in
    let+ statuses =
      Lwt_list.map_s
        (fun rel ->
          let+ status = export_file ~dst rel in
          on_file ~rel status;
          status)
        files
    in
    {
      exported =
        List.length
          (List.filter (function Missing_data -> false | _ -> true) statuses);
      missing =
        List.length
          (List.filter (function Missing_data -> true | _ -> false) statuses);
    }
end
