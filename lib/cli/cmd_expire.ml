open Cmdliner
open Common

let cmd : unit Cmd.t =
  let date_arg =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"DATE"
          ~doc:"Cutoff date YYYY-MM-DD; versions older than this are removed")
  in
  let parse_date s =
    try
      Scanf.sscanf s "%d-%d-%d" (fun year mon day ->
          fst
            (Unix.mktime
               {
                 Unix.tm_year = year - 1900;
                 tm_mon = mon - 1;
                 tm_mday = day;
                 tm_hour = 0;
                 tm_min = 0;
                 tm_sec = 0;
                 tm_wday = 0;
                 tm_yday = 0;
                 tm_isdst = false;
               }))
    with _ -> failwith ("invalid date (expected YYYY-MM-DD): " ^ s)
  in
  let run date domain =
    (* Carriage-return progress belongs on a terminal, where one line rewrites
       itself; down a pipe it is padding in front of the summary. *)
    let watching = Unix.isatty Unix.stderr in
    let s =
      run_lwt
        (let cutoff = parse_date date in
         let (module C : Conf_lwt.S) = load_conf ?domain () in
         let module E = Expire_lwt.Make (C) in
         (* A domain with a long history spends minutes listing before it deletes
            anything, so say what is happening rather than sit silent. Progress
            goes to stderr, leaving stdout to the one summary line a script would
            read. *)
         E.expire
           ~on_list:(fun ~name -> Printf.eprintf "Listing %s...\n%!" name)
           ~on_scan:(fun ~name ~objects ->
             Printf.eprintf "  %s: %d object(s)\n%!" name objects)
           ~on_delete:(fun ~name ~deleted ->
             if watching then Printf.eprintf "  %s: %d deleted\r%!" name deleted)
           ~cutoff ())
    in
    (* The last progress line is still sitting on the terminal's current line,
       and the summary below would land on top of it. *)
    if watching then Printf.eprintf "\r%*s\r%!" 72 "";
    (* [Failure] is left to the top level, which prints it as a sentence and
       exits nonzero: a run that could not reach a backend must not tell a
       script it expired anything. *)
    Printf.printf "Removed %d version(s), %d journal entr(ies)\n"
      s.Expire.versions_deleted s.journal_deleted
  in
  Cmd.v
    (Cmd.info "expire"
       ~doc:
         "Remove trashed folders, versions and journal entries older than DATE \
          (then: tsync gc)")
    Term.(const run $ date_arg $ domain_arg)
