open Lwt.Syntax

type status = Exported | Exported_symlink | Missing_data
type summary = { exported : int; missing : int }

module Make (C : Conf.S) = struct
  module Lk = Logical_key.Make (C)
  module R = Remote.Make (C)
  module Tree = Inode_tree.Make (C)
  module Mf = Checkout.Make (C)
  module Mfs = Staged_manifest.Make (C)
  module D = Data.Make (C) (R)

  (* Assembling through the read path covers unsynced staged edits, a partially
     cached file and a never-cached one alike. Only symlinks are special, having
     no content. *)
  let export_file ~dst rel =
    let key = Lk.file rel in
    let dst_path = Filename.concat dst rel in
    let* () = Fs_util.ensure_parent dst_path in
    let* manifest = D.published key in
    match Option.map (fun m -> (m, Manifest.symlink m)) manifest with
      | Some (_, Some target) ->
          let* () = Fs_util.unlink_quiet dst_path in
          let+ () = Lwt_unix_retry.symlink target dst_path in
          Exported_symlink
      | Some (_, None) ->
          let+ () = D.assemble_to key ~dst_path in
          Exported
      | None ->
          (* A staged file has no published manifest yet, but its content is
             local and readable. *)
          let* staged = Mfs.exists key in
          if not staged then Lwt.return Missing_data
          else
            let+ () = D.assemble_to key ~dst_path in
            Exported

  (* Errors are skipped rather than fatal: one unreadable object should cost its
     own file, not the whole export. *)
  let remote_rels () =
    Tree.fold_tree
      ~on_unusable:(`Skip (fun _ _ -> ()))
      ~folder_id:Stored_key.root_id ~rel:""
      (fun acc rel entry ->
        match entry.Inode_tree.body with
          (* Walked by backend key, which is hashed, so the body is the only
             thing that knows the name. *)
          | Inode_tree.File m ->
              Lwt.return (Key.join rel (Manifest.recorded_name m) :: acc)
          | Inode_tree.Dir _ -> Lwt.return acc)
      []

  let run ?(on_plan = fun ~files:_ -> ()) ?(on_start = fun ~rel:_ -> ()) ~dst
      ~on_file () =
    let* remote_rels = remote_rels () in
    let* local_rels = Mf.walk () in
    let files = List.sort_uniq compare (remote_rels @ local_rels) in
    on_plan ~files:(List.length files);
    let* () = Fs_util.mkdir_p dst in
    let+ statuses =
      Lwt_list.map_s
        (fun rel ->
          on_start ~rel;
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
