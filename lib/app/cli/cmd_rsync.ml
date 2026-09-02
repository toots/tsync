open Cmdliner
open Common

let cmd : unit Cmd.t =
  let src_arg =
    Arg.(
      required
      & pos 0 (some (Location.conv `Either)) None
      & info [] ~docv:"SRC"
          ~doc:
            "Source, as a path or as $(b,DOMAIN:/path). A path in a mounted \
             domain names that domain.")
  in
  let dst_arg =
    Arg.(
      required
      & pos 1 (some (Location.conv `Either)) None
      & info [] ~docv:"DST" ~doc:"Destination, named the same way as $(i,SRC).")
  in
  let move_arg =
    Arg.(
      value & flag
      & info ["move"]
          ~doc:
            "Remove each source once its destination is published. Within one \
             domain and onto nothing, this is a rename and costs one journal \
             entry.")
  in
  let dry_run_arg =
    Arg.(
      value & flag
      & info ["dry-run"; "n"] ~doc:"Print what would be done and do nothing.")
  in
  let run domain src dst move dry_run v =
    set_verbose v;
    let cfg = load_config () in
    let src_end = Location.resolve ?domain cfg src
    and dst_end = Location.resolve ?domain cfg dst in
    let domain_name, src_e, dst_e =
      match (src_end, dst_end) with
        | `Local _, `Local _ ->
            failwith
              "neither path is under a tsync domain -- use rsync(1) for that"
        | `Domain a, `Domain b when a.Location.name <> b.Location.name ->
            failwith
              (Printf.sprintf
                 "%s and %s are in different domains, which is a chunk copy \
                  rather than a manifest one -- see tsync mirror"
                 a.Location.name b.Location.name)
        | `Domain a, `Domain b ->
            ( a.Location.name,
              Rsync.Domain a.Location.rel,
              Rsync.Domain b.Location.rel )
        | `Domain a, `Local p ->
            (a.Location.name, Rsync.Domain a.Location.rel, Rsync.Local p)
        | `Local p, `Domain b ->
            (b.Location.name, Rsync.Local p, Rsync.Domain b.Location.rel)
    in
    let (module C : Conf_lwt.S) = make_conf ~domain:domain_name cfg in
    let current = ref None and copied = ref 0 and skipped = ref 0 in
    let code =
      run_lwt
        ~report:(fun () ->
          report_job
            (module C)
            ~kind:"rsync" ~target:(Location.typed dst)
            ~current:(fun () -> !current)
            ~counters:(fun () -> [("copied", !copied); ("skipped", !skipped)])
            ())
        (let open Lwt.Syntax in
         let module Rs = Rsync_lwt.Make (C) in
         let+ summary =
           Rs.run ~move ~dry_run
             ~on_entry:(fun ~rel decision ->
               (* A source naming one file reports no relative path, that file
                  being the whole of what was asked for. *)
               let rel =
                 if rel = "" then Filename.basename (Location.typed src)
                 else rel
               in
               current := Some rel;
               (match decision with
                 | Rsync.Skip _ -> incr skipped
                 | _ -> incr copied);
               if dry_run || !verbose then
                 Printf.printf "%-12s %s\n%!" (Rsync.describe decision) rel)
             ~src:src_e ~dst:dst_e ()
         in
         Printf.printf
           "\n%d copied, %d skipped, %d director%s, %d failed (%s moved)\n"
           summary.Rsync.copied summary.Rsync.skipped summary.Rsync.dirs
           (if summary.Rsync.dirs = 1 then "y" else "ies")
           summary.Rsync.failed
           (human_bytes (Int64.to_int summary.Rsync.bytes_moved));
         if summary.Rsync.failed > 0 then 1 else 0)
    in
    if code <> 0 then exit code
  in
  Cmd.v
    (Cmd.info "rsync"
       ~doc:
         "Copy files by content rather than by bytes. Within one domain the \
          chunks are already stored, so a copy publishes a manifest and moves \
          nothing; to or from this machine, only what differs is transferred.")
    Term.(
      const run $ domain_arg $ src_arg $ dst_arg $ move_arg $ dry_run_arg
      $ verbose_arg)
