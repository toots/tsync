open Cmdliner
open Cli

let cmd : unit Cmd.t =
  let src_arg =
    Arg.(
      required
      & pos 0 (some dir) None
      & info [] ~docv:"DIR" ~doc:"Folder whose contents to import")
  in
  let only_arg =
    Arg.(
      value & opt_all string []
      & info ["only"] ~docv:"GLOB"
          ~doc:
            "Import only files matching GLOB (shell glob syntax; matched \
             against each entry's relative path and its basename). May be \
             repeated. --exclude is applied on top of the selected set.")
  in
  let exclude_arg =
    Arg.(
      value & opt_all string []
      & info ["exclude"] ~docv:"GLOB"
          ~doc:
            "Exclude files and directories matching GLOB (shell glob syntax; \
             matched against each entry's relative path and its basename). May \
             be repeated.")
  in
  let force_rehash_arg =
    Arg.(
      value & flag
      & info ["force-rehash"]
          ~doc:
            "Re-hash and re-upload every file even if already present in the \
             domain. Only changed or missing chunks are actually uploaded; the \
             manifest is always recomputed and republished.")
  in
  let run domain src only exclude force_rehash v =
    set_verbose v;
    let (module C : Conf.S) = load_conf ?domain () in
    let current = ref None and planned = ref 0 in
    (* The same buckets {!Import.tally} keeps, so the row in [tsync status] and
       the summary this prints cannot disagree about one run. *)
    let imported = ref 0
    and skipped = ref 0
    and symlinks = ref 0
    and failed = ref 0 in
    let failures =
      run_lwt
        ~report:(fun () ->
          report_job
            (module C)
            ~kind:"import" ~target:src
            ~current:(fun () -> !current)
            ~counters:(fun () ->
              [
                ("files", !imported);
                ("planned", !planned);
                ("skipped", !skipped);
                ("symlinks", !symlinks);
                ("failed", !failed);
              ])
            ())
        (let open Lwt.Syntax in
         let module I = Import.Make (C) in
         vprintf "importing from %s into domain %s" src C.domain_name;
         let+ summary =
           I.run ~only ~exclude ~force_rehash ~src
             ~on_dir:(fun ~rel ->
               current := Some rel;
               Printf.printf "mkdir    %s\n%!" rel)
             ~on_plan:(fun ~files ~bytes ->
               planned := files;
               (* An import is transfer-bound: what is left is uploads, and the
                  rate that predicts them is the one they ran at. *)
               Job.Progress.plan ~basis:`Sent ~bytes)
             ~on_start:(fun ~rel ~size ->
               current := Some rel;
               Job.Progress.start_entry ~size)
             ~on_progress:(fun ~bytes ~sent ->
               Job.Progress.advance ~bytes ~sent)
             ~on_file:(fun ~rel status ->
               match status with
                 | Import.Imported size ->
                     Job.Progress.finish_entry (`Done size);
                     incr imported;
                     Printf.printf "imported %s (%Ld bytes)\n%!" rel size
                 | Import.Skipped_exists ->
                     Job.Progress.finish_entry `Skipped;
                     incr skipped;
                     Printf.printf "skip     %s (already in domain)\n%!" rel
                 | Import.Skipped_symlink ->
                     Job.Progress.finish_entry `Skipped;
                     incr symlinks;
                     Printf.printf "skip     %s (symlink)\n%!" rel
                 | Import.Failed msg ->
                     Job.Progress.finish_entry `Failed;
                     incr failed;
                     Printf.printf "failed   %s: %s\n%!" rel msg)
             ()
         in
         Printf.printf
           "\n%d file%s imported, %d skipped, %d symlinks skipped, %d failed\n"
           summary.Import.imported
           (if summary.Import.imported = 1 then "" else "s")
           summary.Import.skipped summary.Import.skipped_symlinks
           summary.Import.failed;
         summary.Import.failed)
    in
    (* Outside {!run_lwt}: exiting from inside its promise would skip both the
       deferred drain it exists for and the job's own last report. *)
    if failures > 0 then exit 1
  in
  Cmd.v
    (Cmd.info "import"
       ~doc:
         "Import a folder into the domain: upload its files to all backends \
          and create manifest sidecars in the local cache. Data is not copied \
          — the cache links to the source files. Keys already in the domain \
          are skipped.")
    Term.(
      const run $ domain_arg $ src_arg $ only_arg $ exclude_arg
      $ force_rehash_arg $ verbose_arg)
