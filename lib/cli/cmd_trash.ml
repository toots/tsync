open Cmdliner
open Common

(* An empty trash lists as its own directory key, which holds no marker and
   cannot be fetched on a filesystem store. Dropped here rather than in each
   reader: every one of them goes on to [get] what this returns. *)
let trash_list domain =
  run_lwt
    (let open Lwt.Syntax in
     let (module C : Conf.S) = load_conf ?domain () in
     let module T = Trash.Make (C) in
     let+ paths = T.list () in
     List.iter (Printf.printf "%s\n") paths)

let trash_restore path domain =
  let code =
    run_lwt
      (let open Lwt.Syntax in
       let (module C : Conf.S) = load_conf ?domain () in
       let module T = Trash.Make (C) in
       let+ outcome = T.restore path in
       match outcome with
         | Trash.Restored ->
             Printf.printf
               "restored %s — run 'tsync sync' to rebuild it locally\n" path;
             0
         | Trash.Not_in_trash ->
             Printf.eprintf "not in trash: %s\n" path;
             0
         | Trash.Parent_unknown ->
             Printf.eprintf
               "cannot restore %s: this client has no record of the folder it \
                belongs under — run 'tsync sync' first\n"
               path;
             1)
  in
  (* Outside {!run_lwt}: exiting from inside its promise would skip the
     deferred drain it exists for. *)
  if code <> 0 then exit code

let cmd : unit Cmd.t =
  let path_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let restore_arg =
    Arg.(
      value & flag
      & info ["restore"]
          ~doc:
            "Put $(i,PATH) back where it was. The subtree is untouched, so \
             this is O(1); run $(b,tsync sync) to rebuild it locally.")
  in
  let purge_arg =
    Arg.(
      value & flag
      & info ["purge"] ~doc:"Delete every version of $(i,PATH) from the trash.")
  in
  let purge path domain =
    let code =
      run_lwt
        (let open Lwt.Syntax in
         let (module C : Conf.S) = load_conf ?domain () in
         let module E = Expire.Make (C) in
         let+ outcome = E.purge_trashed ~path () in
         match outcome with
           | `Not_in_trash ->
               Printf.eprintf "not in trash: %s\n" path;
               1
           | `Purged n ->
               Printf.printf
                 "purged %s (%d object%s) — run tsync gc to reclaim\n" path n
                 (if n = 1 then "" else "s");
               0)
    in
    (* Outside {!run_lwt}: exiting from inside its promise would skip the
       deferred drain it exists for. *)
    if code <> 0 then exit code
  in
  let run path domain restore do_purge =
    match (path, restore, do_purge) with
      | None, false, false -> trash_list domain
      | Some path, true, false -> trash_restore path domain
      | Some path, false, true -> purge path domain
      | None, _, _ -> failwith "--restore and --purge each need a PATH."
      | Some _, true, true ->
          failwith "--restore and --purge do opposite things; run one."
      | Some _, false, false ->
          failwith
            "naming a path needs --restore or --purge; trash alone lists."
  in
  Cmd.v
    (Cmd.info "trash"
       ~doc:
         "List trashed folders, or act on one: $(b,--restore) puts it back, \
          $(b,--purge) deletes its versions for good.")
    Term.(const run $ path_arg $ domain_arg $ restore_arg $ purge_arg)
