type status = Exported | Exported_symlink | Missing_data
type summary = { exported : int; missing : int }

module Over
    (Io : Io.S)
    (Files : Fs.S with type 'a io := 'a Io.t)
    (Syscalls : Syscalls.S with type 'a io := 'a Io.t)
    (Tree : Inode_tree.OVER with type 'a io := 'a Io.t)
    (Checkout : Checkout.OVER with type 'a io := 'a Io.t)
    (Staged : Staged_manifest.OVER with type 'a io := 'a Io.t)
    (Remote : Remote.OVER with type 'a io := 'a Io.t)
    (Content : Data.OVER with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  module Make (C : Conf.S with type 'a io = 'a Io.t) = struct
    module Lk = Logical_key.Make (C)
    module Tree = Tree.Make (C)
    module Mf = Checkout.Make (C)
    module Mfs = Staged.Make (C)
    module D = Content.Make (C) (Remote.Make (C))

    (* Assembling through the read path covers unsynced staged edits, a partially
       cached file and a never-cached one alike. Only symlinks are special, having
       no content. *)
    let export_file ~dst rel =
      let key = Lk.file rel in
      let dst_path = Filename.concat dst rel in
      let* () = Files.ensure_parent dst_path in
      let* manifest = D.published key in
      match Option.map (fun m -> (m, Manifest.symlink m)) manifest with
        | Some (_, Some target) ->
            let* () = Files.unlink_quiet dst_path in
            let+ () = Syscalls.symlink target dst_path in
            Exported_symlink
        | Some (_, None) ->
            let+ () = D.assemble_to key ~dst_path in
            Exported
        | None ->
            (* A staged file has no published manifest yet, but its content is
               local and readable. *)
            let* staged = Mfs.exists key in
            if not staged then Io.return Missing_data
            else
              let+ () = D.assemble_to key ~dst_path in
              Exported

    (* Errors are skipped rather than fatal: one unreadable object should cost its
       own file, not the whole export. *)
    let remote_rels () =
      Tree.fold_tree
        ~on_unusable:(`Skip (fun _ _ -> ()))
        ~folder_id:Stored_key.root_id ~key:Lk.root
        (fun acc key entry ->
          match entry.Inode_tree.body with
            (* Walked by backend key, which is hashed, so the body is the only
               thing that knows the name. *)
            | Inode_tree.File m ->
                Io.return
                  (Logical_key.path
                     (Logical_key.file_in key (Manifest.recorded_name m))
                  :: acc)
            | Inode_tree.Dir _ -> Io.return acc)
        []

    let run ?(on_plan = fun ~files:_ -> ()) ?(on_start = fun ~rel:_ -> ()) ~dst
        ~on_file () =
      let* remote_rels = remote_rels () in
      let* local_rels = Mf.walk () in
      let files = List.sort_uniq compare (remote_rels @ local_rels) in
      on_plan ~files:(List.length files);
      let* () = Files.mkdir_p dst in
      let+ statuses =
        map_s
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
            (List.filter
               (function Missing_data -> false | _ -> true)
               statuses);
        missing =
          List.length
            (List.filter
               (function Missing_data -> true | _ -> false)
               statuses);
      }
  end
end
