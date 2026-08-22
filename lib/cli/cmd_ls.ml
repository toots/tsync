open Cmdliner
open Common

let cmd : unit Cmd.t =
  let path_arg =
    Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH")
  in
  let deleted_arg =
    Arg.(
      value & flag
      & info ["deleted"; "d"] ~doc:"Also list deleted files in the directory")
  in
  let frontend_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["frontend"] ~docv:"NAME"
          ~doc:
            "Frontend to report cache status for (default: the domain's first).")
  in
  let run path show_deleted domain frontend =
    run_lwt
      (let open Lwt.Syntax in
       let cfg = load_config () in
       let domain =
         match domain with Some _ -> domain | None -> read_default_domain ()
       in
       let (module C : Conf.S) = make_conf ?domain cfg in
       let (module F : Frontend.S) =
         resolve_frontend ?frontend (Conf_parsing.pick_domain ?domain cfg)
       in
       let module Fs = File_store.Make (C) in
       let mount_point =
         mount_point_of (Conf_parsing.pick_domain ?domain cfg)
       in
       let prefix =
         let dp = C.domain_prefix in
         match path with
           | None -> dp
           | Some p ->
               (* Accepts a domain-relative path or an absolute one under the
                  mount point. *)
               let rel =
                 let mp = mount_point ^ "/" in
                 if
                   String.length p >= String.length mp
                   && String.sub p 0 (String.length mp) = mp
                 then
                   String.sub p (String.length mp)
                     (String.length p - String.length mp)
                 else p
               in
               let rel =
                 if rel = "" || rel.[String.length rel - 1] = '/' then rel
                 else rel ^ "/"
               in
               dp ^ rel
       in
       let module Mf = Manifest.Make (C) in
       let module B = (val C.store : Backend.S) in
       let* files, subdirs = Mf.list_children ~prefix () in
       let file_name (e : Backend.file_entry) =
         Key.strip_prefix ~domain_prefix:C.domain_prefix e.key
       in
       let items =
         List.map (fun d -> (d, `Dir d)) subdirs
         @ List.map (fun e -> (file_name e, `File e)) files
       in
       let items =
         List.sort
           (fun (a, _) (b, _) ->
             String.compare (String.lowercase_ascii a)
               (String.lowercase_ascii b))
           items
       in
       List.iter
         (fun (name, item) ->
           match item with
             | `Dir _ -> Printf.printf "dir    %s/\n" name
             | `File (e : Backend.file_entry) ->
                 let cached = F.is_local (Conf.locality (module C)) e.key in
                 Printf.printf "%s  %s  %d bytes\n"
                   (if cached then "local" else "cloud")
                   name e.size)
         items;
       if show_deleted then begin
         let module D = Deleted.Make (C) in
         let reldir =
           Key.chop_slash
             (Key.strip_prefix ~domain_prefix:C.domain_prefix prefix)
         in
         let+ names = D.in_folder reldir in
         List.iter (Printf.printf "deleted  %s\n") names
       end
       else Lwt.return_unit)
  in
  Cmd.v
    (Cmd.info "ls" ~doc:"List files with cache status")
    Term.(const run $ path_arg $ deleted_arg $ domain_arg $ frontend_arg)
