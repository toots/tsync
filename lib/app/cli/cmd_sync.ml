open Cmdliner
open Common

let cmd : unit Cmd.t =
  let source_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["source"] ~docv:"NAME"
          ~doc:
            "Backend to sync from, by its configured name. Default: the \
             primary backend.")
  in
  let full_arg =
    Arg.(
      value & flag
      & info ["full"]
          ~doc:
            "Force a full resync: re-read every manifest from the backend, \
             rewriting the local mirror in place and dropping what the backend \
             no longer has")
  in
  let parallelism_arg =
    Arg.(
      value & opt int 32
      & info ["parallelism"; "j"] ~docv:"N"
          ~doc:
            "Max concurrent backend operations during a full resync (default \
             32). Lower it if you hit DNS or open-file limits.")
  in
  (* Asked of the frontends rather than of their names: what makes a resync
     wrong here is that nothing keeps a replica, which is theirs to declare. *)
  let refuse_if_pulled cfg domain =
    let d = Conf_parsing.pick_domain ?domain cfg in
    List.iter
      (fun name ->
        match Frontend.find name with
          | Some (module F : Frontend.S) -> (
              match F.tree with
                | `Replicated -> ()
                | `Pulled why ->
                    prerr_endline ("tsync sync: " ^ why);
                    exit 2)
          | None -> ())
      (frontend_names d)
  in
  let run domain source full parallelism v =
    set_verbose v;
    let cfg = load_config () in
    refuse_if_pulled cfg domain;
    let (module C : Conf_lwt.S) =
      let conf = make_conf ?domain cfg in
      match source with Some name -> reading_from name conf | None -> conf
    in
    let module R = Resync_lwt.Make (C) in
    let phase = ref "starting" and current = ref None in
    let manifests = ref 0 and failures = ref 0 in
    (* An incremental pass counts no manifests, and a fixed set of counters
       would print zeroes reading as "nothing happened" rather than as "this
       pass does not count that". *)
    let rebuilding = ref false in
    let started = Unix.gettimeofday () in
    let phase_started = ref started in
    (* Where a slow run spends its time is the number every change to it is
       judged by, so each phase reports its own duration as it ends. *)
    let end_phase () =
      let now = Unix.gettimeofday () in
      if !verbose && !phase <> "starting" then
        Log.info "%s: %.1fs" !phase (now -. !phase_started);
      phase_started := now
    in
    let progress =
      {
        Resync.on_phase =
          (fun p ->
            end_phase ();
            phase := p;
            if p = "rebuilding" then rebuilding := true;
            if p = "draining uploads" && !verbose then
              Log.info "draining upload queue");
        on_current = (fun c -> current := c);
      }
    in
    let summary () =
      end_phase ();
      if !verbose then
        Log.info
          "%.1fs total: %d manifests, %d failed; %d requests, %d retries, %d \
           timeouts, %d failures"
          (Unix.gettimeofday () -. started)
          !manifests !failures (Metrics.requests ()) (Metrics.retries ())
          (Metrics.timeouts ()) (Metrics.failures ())
    in
    let notify () =
      try
        if !verbose then Log.info "notifying daemon of completed resync";
        ignore
          (Ipc.action ~socket_path:C.socket_path ~domain:C.domain_name
             "full_resync")
      with
        | Failure msg -> Printf.eprintf "Warning: full_resync: %s\n" msg
        | _ -> ()
    in
    let code =
      run_lwt
        ~report:(fun () ->
          report_job
            (module C)
            ~kind:(if full then "sync --full" else "sync")
            ~current:(fun () ->
              match !current with
                | Some at -> Some (doing !phase at)
                | None -> Some !phase)
              (* No total for a resync: the inode tree is discovered as it is
               walked, so a denominator here would be one this cannot know. *)
            ~counters:(fun () ->
              if !rebuilding then
                [("manifests", !manifests); ("failed", !failures)]
              else [])
            ())
        (let open Lwt.Syntax in
         if !verbose then
           Log.info "syncing domain %s (client %s, uuid %s)" C.domain_name
             C.client_name (R.client_uuid ());
         let on_decision last all_keys reason =
           if !verbose then begin
             Log.info "last sync bookmark: %s"
               (match last with
                 | None -> "none (first run)"
                 | Some k -> Journal.Entry_key.to_string k);
             Log.info "journal: %d entr%s" (List.length all_keys)
               (if List.length all_keys = 1 then "y" else "ies");
             Option.iter (Log.info "full resync: %s") reason
           end
         in
         (* A line per thousand rather than per manifest: a large domain is
            hundreds of thousands, and the live report carries the rest. *)
         let on_manifest _ =
           incr manifests;
           if !verbose && !manifests mod 1000 = 0 then
             Log.info "%d manifests, %d failed; at %s" !manifests !failures
               (Option.value !current ~default:"/")
         in
         let+ outcome =
           R.run ~full ~progress ~on_manifest ~on_decision ~parallelism ~notify
             ()
         in
         match outcome with
           | Resync.Full { manifests = n; failed; reason = _ } ->
               failures := failed;
               summary ();
               Printf.printf "full resync: %d manifest%s downloaded%s\n" n
                 (if n = 1 then "" else "s")
                 (if failed > 0 then
                    Printf.sprintf
                      " (%d failed — re-run 'tsync sync --full' to complete)"
                      failed
                  else "");
               if failed > 0 then 1 else 0
           | Resync.Incremental { applied } ->
               summary ();
               (match R.bookmark () with
                 | Some k when !verbose ->
                     Log.info "applied through %s"
                       (Journal.Entry_key.to_string k)
                 | _ -> ());
               Printf.printf "%d journal entr%s from other clients\n" applied
                 (if applied = 1 then "y" else "ies");
               0)
    in
    (* Outside {!run_lwt}: exiting from inside its promise would skip the
       deferred drain it exists for, and a resync that failed part way is
       exactly the run with copies still queued. *)
    if code <> 0 then exit code
  in
  Cmd.v
    (Cmd.info "sync"
       ~doc:
         "Sync local cache with remote changes. Replays pending local journal \
          entries, then applies new journal entries from other clients. A full \
          resync (triggered by --full or when the local bookmark is stale) \
          re-reads every manifest from the backend. Pass --verbose to see a \
          step-by-step breakdown.")
    Term.(
      const run $ domain_arg $ source_arg $ full_arg $ parallelism_arg
      $ verbose_arg)
