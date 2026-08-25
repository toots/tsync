open Cmdliner
open Common

let cmd : unit Cmd.t =
  let budget_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["budget"] ~docv:"DUR"
          ~doc:
            "Spend at most this long, then stop and leave the collection open \
             where it is; the next $(b,tsync gc) continues from there. Checked \
             between batches, so a batch already running is not cut short. An \
             open collection is safe to leave indefinitely. One count and one \
             unit: $(b,30s), $(b,10m), $(b,2h), $(b,1d).")
  in
  let pause_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["pause"] ~docv:"DUR"
          ~doc:
            "Idle this long between batches. Where $(b,--budget) bounds how \
             long the whole thing takes, this bounds how hard it pushes while \
             it runs.")
  in
  let concurrency_arg =
    Arg.(
      value
      & opt (some int) None
      & info ["concurrency"] ~docv:"N"
          ~doc:
            "Operations in flight (default: what the device says). $(b,1) is \
             as gentle as it gets.")
  in
  let delete_batch_arg =
    Arg.(
      value
      & opt (some int) None
      & info ["delete-batch"] ~docv:"N"
          ~doc:
            "Chunks per delete request against a replica or backfill target \
             (default: 1000, which is what S3 and GCS both cap a bulk delete \
             at). Raise it for a store that takes more, lower it for one that \
             chokes.")
  in
  let abort_arg =
    Arg.(
      value & flag
      & info ["abort"]
          ~doc:
            "Abandon an open collection, keeping every chunk it still holds. \
             Takes $(b,--budget), $(b,--pause) and $(b,--concurrency) like a \
             collection does, and resumes the same way — a second $(b,--abort) \
             continues abandoning rather than starting over.")
  in
  let retry_arg =
    Arg.(
      value & flag
      & info ["retry-jobs"]
          ~doc:
            "Deliver outstanding delete requests again. A request is handed to \
             a copy's bucket once, by the notification its own write fires; a \
             function that was absent or broken then does not pick one up by \
             being fixed. Safe to repeat.")
  in
  let status_arg =
    Arg.(
      value & flag
      & info ["status"] ~doc:"Report an open collection without continuing it.")
  in
  let verify_arg =
    Arg.(
      value & flag
      & info ["verify"]
          ~doc:
            "Also hold each live chunk against its own name as it is kept, and \
             record what fails for $(b,tsync data-integrity --repair). Reads \
             every live byte, where a collection otherwise touches only \
             metadata — minutes become hours on a large store. A chunk that \
             fails is kept and marked, never discarded.")
  in
  let verified_line (s : Gc.stats) =
    if s.Gc.chunks_verified = 0 && s.Gc.chunks_unreadable = 0 then ""
    else
      Printf.sprintf
        "\n\
         %d chunk(s) checked: %d corrupt, %d unreadable, %d marker(s) \
         cleared.%s"
        s.Gc.chunks_verified s.Gc.chunks_corrupt s.Gc.chunks_unreadable
        s.Gc.chunks_cleared
        (if s.Gc.chunks_corrupt + s.Gc.chunks_unreadable > 0 then
           " Run tsync data-integrity --repair."
         else "")
  in
  (* [was_open] is read before the abandonment rather than inferred from its
     counts: what it moves back is what marking had not reached yet, so a run
     abandoned after a finished mark moves nothing and a count of zero says
     nothing about whether there was a run at all. *)
  let report ~abort ~was_open ~domain (s : Gc.stats) =
    match s.Gc.outcome with
      | Gc.Completed when abort && not was_open ->
          Printf.printf "No collection was open for %s; nothing to abandon.\n"
            domain
      | Gc.Completed when abort ->
          (* Moved back, not kept: everything marking had already moved across is
             kept too, and was never at risk. *)
          Printf.printf
            "Collection abandoned; %d chunk(s) moved back, none discarded.\n"
            s.chunks_promoted
      | Gc.Completed ->
          Printf.printf "Reclaimed %d chunk(s), %s. Kept %d.%s\n"
            s.chunks_reclaimed
            (human_bytes s.bytes_reclaimed)
            s.chunks_promoted (verified_line s)
      (* Each phase fills in different fields, so one fixed set of them would
         print zeroes that read as "nothing happened" rather than as "this phase
         does not count that".

         The continue line names the command that continues *this*: a plain
         [tsync gc] over an abandoned collection would go back to collecting it. *)
      | Gc.Suspended { phase; _ } when abort ->
          Printf.printf
            "Stopped while %s: %d chunk(s) moved back so far.\n\
             Still open; rerun tsync gc --abort to continue.\n"
            phase s.chunks_promoted
      | Gc.Suspended { phase; _ } ->
          Printf.printf
            "Stopped while %s: %d file(s) marked, %d chunk(s) kept, %d \
             reclaimed.%s\n\
             Still open; rerun tsync gc to continue.\n"
            phase s.roots_marked s.chunks_promoted s.chunks_reclaimed
            (verified_line s)
  in
  let run budget pause concurrency delete_batch abort status retry verify
      verbose domain =
    set_verbose verbose;
    (* Reported as [Failure], which the top level prints as "tsync: <sentence>"
       and exits nonzero on. Both carry prose written for whoever typed this. *)
    let translate f =
      try f () with
        | Gc.Unsupported msg | Gc.Busy msg -> failwith msg
        | Failure msg -> failwith msg
    in
    let (module C : Conf.S) = load_conf ?domain () in
    let module G = Gc.Make (C) in
    if retry then (
      (* Re-delivery, not a fresh decision: what each request names is in the
         request, the space those keys came from having been discarded. *)
      let sent = run_lwt (G.retry_outstanding ()) in
      let total = List.fold_left (fun n (_, c) -> n + c) 0 sent in
      if total = 0 then
        Printf.printf "No delete request is outstanding for %s.\n" C.domain_name
      else
        List.iter
          (fun (name, n) ->
            if n > 0 then
              Printf.printf
                "%s: %d delete request(s) sent again. Watch tsync gc --status: \
                 they clear as the function consumes them.\n"
                name n)
          sent)
    else if status then (
      (match run_lwt (G.status ()) with
        | None -> Printf.printf "No collection is open for %s.\n" C.domain_name
        | Some r ->
            Printf.printf "Collection of %s open: %s, %.0fs so far.\n"
              C.domain_name
              (Collection.string_of_phase r.Collection.phase)
              (Unix.gettimeofday () -. r.Collection.started));
      (* Printed whether or not one is open: a request outlives the collection
         that queued it, and a copy sitting on one is the case this exists to
         show. *)
      List.iter
        (fun (name, count, oldest) ->
          Printf.printf
            "  %s: %d delete request(s) outstanding, oldest %s.\n\
            \    Nothing has picked them up — check the bucket's notification \
             and the function's logs.\n"
            name count (G.show_age oldest))
        (run_lwt (G.outstanding ())))
    else (
      (* Abandoning is the same machinery with everything treated as live, so it
         takes the same pacing and reports the same way — whoever reaches for
         --abort is getting out of a collection that is already going badly.

         Progress to stderr, so stdout carries only the summary a script would
         read. *)
      let budget = Option.map parse_duration budget
      and pause = Option.map parse_duration pause in
      (* Carriage-return progress belongs on a terminal, where one line rewrites
         itself; down a pipe it is padding in front of the summary. The same
         text goes to the log there instead, which is what [-v] reaches -- a
         collection run under screen and teed to a file is the case that wants
         it, and the one where stderr is not a terminal. *)
      let watching = Unix.isatty Unix.stderr in
      (* Spelled as {!Collection.string_of_phase} does, so a phase named here
         and one read off an open run are the same word. *)
      let phase = ref (Collection.string_of_phase Collection.Opening) in
      let at_ = ref "" in
      let marked = ref [] and closed = ref [] in
      let emit ending line =
        if watching then Printf.eprintf "%s%s%!" line ending
        else vprintf "%s" line
      in
      let header fmt = Printf.ksprintf (emit "\n") fmt in
      let progress fmt = Printf.ksprintf (emit "\r") fmt in
      let on_open () =
        phase := Collection.string_of_phase Collection.Opening;
        header "%s %s..."
          (if abort then "Abandoning the collection of" else "Collecting")
          C.domain_name
      in
      (* Abandoning walks shards and has no notion of a file; marking walks
         folders and counts the files in them, so the two get different lines
         rather than one with a field that means nothing in half the runs. *)
      let on_mark ~namespaces ~total ~roots ~promoted ~at =
        phase :=
          Collection.string_of_phase
            (if abort then Collection.Abandoning else Collection.Marking);
        at_ := at;
        marked :=
          if abort then
            [("shards", namespaces); ("planned", total); ("kept", promoted)]
          else
            [
              ("folders", namespaces);
              ("planned", total);
              ("files", roots);
              ("kept", promoted);
            ];
        if abort then
          progress "  kept %d/%d shard(s), %d chunk(s)" namespaces total
            promoted
        else
          progress "  marked %d/%d folder(s), %d file(s), %d chunk(s) kept"
            namespaces total roots promoted
      in
      (* Added to rather than replacing what marking counted: a job whose set of
         counters changes halfway through reads as one that lost them. *)
      let on_close ~shards ~reclaimed ~at =
        phase := Collection.string_of_phase Collection.Closing;
        at_ := at;
        closed := [("closed", shards); ("reclaimed", reclaimed)];
        progress "  closed %d shard(s), %d chunk(s) reclaimed" shards reclaimed
      in
      translate (fun () ->
          let was_open = abort && run_lwt (G.status ()) <> None in
          let s =
            run_lwt
              ~report:(fun () ->
                report_job
                  (module C)
                  ~kind:(if abort then "gc --abort" else "gc")
                  ~current:(fun () ->
                    Some (if !at_ = "" then !phase else doing !phase !at_))
                  ~counters:(fun () -> !marked @ !closed)
                  ())
              (if abort then
                 G.abort ?budget ?pause ?concurrency ~on_open ~on_mark ~on_close
                   ()
               else
                 G.run ?budget ?pause ?concurrency ?delete_batch ~verify
                   ~on_open ~on_mark ~on_close ())
          in
          (* The progress lines above end in a carriage return, so the last one is
             still sitting on the terminal's current line. Cleared before the
             summary goes to stdout, or the two land on top of each other. *)
          if watching then Printf.eprintf "\r%*s\r%!" 72 "";
          report ~abort ~was_open ~domain:C.domain_name s))
  in
  Cmd.v
    (Cmd.info "gc"
       ~doc:
         "Reclaim chunks nothing references any more (run tsync expire first). \
          Local main stores only. Deletes the same chunks off the replicas and \
          backfill targets; filling a copy that has fallen behind is tsync \
          mirror's job, not this one's.")
    Term.(
      const run $ budget_arg $ pause_arg $ concurrency_arg $ delete_batch_arg
      $ abort_arg $ status_arg $ retry_arg $ verify_arg $ verbose_arg
      $ domain_arg)
