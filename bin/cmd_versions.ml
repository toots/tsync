open Cmdliner
open Cli

let cmd : unit Cmd.t =
  let path_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let revert_arg =
    Arg.(
      value & flag
      & info ["revert"]
          ~doc:
            "Restore a previous version of $(i,PATH) instead of listing them. \
             Metadata only, nothing is downloaded.")
  in
  let version_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["version"] ~docv:"TS"
          ~doc:
            "With $(b,--revert): the version timestamp to restore (default: \
             most recent).")
  in
  (* The path names its own domain by sitting under that domain's mount, so
     [--domain] is only consulted when it was given. *)
  let revert path version domain =
    let socket_path =
      match domain with
        | Some _ -> domain_socket ?domain ()
        | None -> domain_socket_for_path path
    in
    match Ipc.action ~socket_path ~path ?arg:version "revert" with
      | _ -> Printf.printf "Reverted: %s\n" path
      | exception Failure msg -> Printf.eprintf "Error: %s\n" msg
  in
  let list path domain =
    run_lwt
      (let open Lwt.Syntax in
       let (module C : Conf.S) = load_conf ?domain () in
       let module St = Store.Make (C) (Layout.Inode.Make (C)) in
       let module B = (val C.store : Backend.S) in
       let parse = Versioning.parse ~versions_prefix:C.versions_prefix in
       match path with
         | Some rel ->
             let* dir = St.version_dir ~key:(C.domain_prefix ^ rel) in
             let+ entries =
               match dir with
                 | None -> Lwt.return_nil
                 | Some dir -> B.list_prefix ~prefix:dir ()
             in
             let versions =
               entries
               |> List.filter_map (fun (e : Backend.file_entry) ->
                   match parse e.key with
                     | Some (_, ts) -> Some (Int64.of_string ts, e.size)
                     | None -> None)
               |> List.sort (fun (a, _) (b, _) -> Int64.compare b a)
             in
             if versions = [] then Printf.printf "No versions for %s\n" rel
             else
               List.iter
                 (fun (ts, size) ->
                   Printf.printf "%Ld  %s  %d bytes\n" ts (human_ts ts) size)
                 versions
         | None ->
             let module D = Deleted.Make (C) in
             let+ deleted = D.in_domain () in
             let deleted = List.sort compare deleted in
             if deleted = [] then print_endline "No deleted files"
             else
               List.iter
                 (fun (e : Deleted.entry) ->
                   Printf.printf "%s  (deleted %s, %d version%s)\n"
                     e.Deleted.path (human_ts e.Deleted.latest) e.Deleted.versions
                     (if e.Deleted.versions = 1 then "" else "s"))
                 deleted)
  in
  let run path domain do_revert version =
    match (path, do_revert) with
      | Some path, true -> revert path version domain
      | _, false -> list path domain
      | None, true -> failwith "--revert needs the PATH to restore."
  in
  Cmd.v
    (Cmd.info "versions"
       ~doc:
         "List a file's versions, or all deleted files when no PATH is given. \
          With $(b,--revert), restore one instead.")
    Term.(const run $ path_arg $ domain_arg $ revert_arg $ version_arg)
