open Cmdliner
open Cli

let cmd : unit Cmd.t =
  let dst_arg =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"DIR" ~doc:"Destination folder (created if needed)")
  in
  let run domain dst v =
    set_verbose v;
    let (module C : Conf.S) = load_conf ?domain () in
    let current = ref None and planned = ref 0 in
    (* The same buckets the summary below prints, so the row in [tsync status]
       and that line cannot disagree about one run. *)
    let exported = ref 0 and symlinks = ref 0 and missing = ref 0 in
    let code =
      run_lwt
        ~report:(fun () ->
          report_job
            (module C)
            ~kind:"export" ~target:dst
            ~current:(fun () -> !current)
            ~counters:(fun () ->
              [
                ("files", !exported);
                ("planned", !planned);
                ("symlinks", !symlinks);
                ("missing", !missing);
              ])
            ())
        (let open Lwt.Syntax in
         let module E = Export.Make (C) in
         vprintf "exporting domain %s to %s" C.domain_name dst;
         let+ summary =
           E.run ~dst
             ~on_plan:(fun ~files -> planned := files)
             ~on_start:(fun ~rel -> current := Some rel)
             ~on_file:(fun ~rel status ->
               match status with
                 | Export.Exported ->
                     incr exported;
                     Printf.printf "exported %s\n%!" rel
                 | Export.Exported_symlink ->
                     incr exported;
                     incr symlinks;
                     Printf.printf "exported %s (symlink)\n%!" rel
                 | Export.Missing_data ->
                     incr missing;
                     Printf.printf
                       "MISSING  %s (no local data or remote manifest)\n%!" rel)
             ()
         in
         Printf.printf "\n%d file%s exported, %d missing\n"
           summary.Export.exported
           (if summary.Export.exported = 1 then "" else "s")
           summary.Export.missing;
         if summary.Export.missing > 0 then 1 else 0)
    in
    if code <> 0 then exit code
  in
  Cmd.v
    (Cmd.info "export"
       ~doc:
         "Export every file of the domain to a folder. Cached files are copied \
          locally; evicted files are recomposed from remote chunks without \
          populating the cache.")
    Term.(const run $ domain_arg $ dst_arg $ verbose_arg)
