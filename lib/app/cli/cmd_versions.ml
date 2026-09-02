open Cmdliner
open Common

let cmd : unit Cmd.t =
  let path_arg =
    Arg.(
      value
      & pos 0 (some (Location.conv `In_domain)) None
      & info [] ~docv:"PATH"
          ~doc:"A file, domain-relative or as $(b,DOMAIN:/path).")
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
  (* The path names its own domain by sitting under one of that domain's roots,
     so [--domain] is only consulted when it was given. *)
  let revert path version domain =
    match Location.item ?domain path with
      | Error msg ->
          Printf.eprintf "Error: %s\n" msg;
          exit 1
      | Ok (domain, item) -> (
          match
            Ipc.action ~socket_path:(domain_socket ~domain ()) ~domain ~item
              ?arg:version "revert"
          with
            | _ -> Printf.printf "Reverted: %s\n" (Location.typed path)
            | exception Failure msg ->
                Printf.eprintf "Error: %s\n" msg;
                exit 1)
  in
  let list path domain =
    run_lwt
      (let open Lwt.Syntax in
       let cfg = load_config () in
       let (module C : Conf_lwt.S) = make_conf ?domain cfg in
       let module L = Layout_lwt.Inode.Make (C) in
       let module St = Store_lwt.Make (C) (L) in
       let module Hs = History_lwt.Make (C) (L) in
       let module Lk = Logical_key.Make (C) in
       let module B = (val C.store : C.Store) in
       let parse = History.parse ~versions_prefix:C.versions_prefix in
       match Option.map (fun a -> Location.place ?domain cfg a) path with
         | Some (Error msg) -> failwith msg
         | Some (Ok p) ->
             let rel = p.Location.rel in
             let* dir = Hs.version_dir ~key:(Lk.file rel) in
             let+ entries =
               match dir with
                 | None -> Lwt.return_nil
                 | Some dir ->
                     B.list_prefix ~prefix:(Stored_key.to_string dir) ()
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
             let module D = Retention_lwt.Make (C) in
             let+ deleted = D.deleted_in_domain () in
             let deleted = List.sort compare deleted in
             if deleted = [] then print_endline "No deleted files"
             else
               List.iter
                 (fun (e : Retention.deleted) ->
                   Printf.printf "%s  (deleted %s, %d version%s)\n"
                     e.Retention.path
                     (human_ts e.Retention.latest)
                     e.Retention.versions
                     (if e.Retention.versions = 1 then "" else "s"))
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
