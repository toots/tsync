open Cmdliner
open Common

(* One command for the three things anyone does about a chunk that is not what
   its name says: ask for a check, read what was found, put it right.

   The stores are what it walks, not this machine's manifests: a chunk is
   checkable wherever it sits, and what a client happens to have cached says
   nothing about the copy a store is keeping. *)
let cmd : unit Cmd.t =
  let current = ref None and planned = ref 0 in
  let checked = ref 0 and unrepairable = ref 0 and corrupt = ref 0 in
  (* [--verify] polls every store at once, so what a reader wants is the run's
     totals rather than whichever member answered last. *)
  let per_store : (string, int * int) Hashtbl.t = Hashtbl.create 4 in
  let sum_stores which =
    Hashtbl.fold (fun _ v acc -> acc + which v) per_store 0
  in
  let report (module C : Conf_lwt.S) detail =
    let open Lwt.Syntax in
    let module Cor = Corruption_lwt.Make (C) in
    let* r = Cor.list () in
    let entries =
      List.sort
        (fun (a : Corruption.entry) b ->
          compare
            (a.Corruption.store, a.Corruption.chunk_key)
            (b.Corruption.store, b.Corruption.chunk_key))
        r.Corruption.entries
    in
    corrupt := List.length entries;
    let* () =
      Lwt_list.iter_s
        (fun (e : Corruption.entry) ->
          if not detail then (
            Printf.printf "CORRUPT %s on %s\n%!" e.Corruption.chunk_key
              e.Corruption.store;
            Lwt.return_unit)
          else
            let+ found = Cor.detail e in
            let extra =
              match found with
                | Some { Corruption_marker.computed = Some c; size; _ } ->
                    Printf.sprintf " (hashed to %s%s)" c
                      (match size with
                        | Some n -> Printf.sprintf ", %d bytes" n
                        | None -> "")
                | Some { Corruption_marker.reason = Some why; _ } ->
                    Printf.sprintf " (%s)" why
                | _ -> ""
            in
            Printf.printf "CORRUPT %s on %s%s\n%!" e.Corruption.chunk_key
              e.Corruption.store extra)
        entries
    in
    List.iter
      (fun (name, why) -> Printf.printf "UNREACHABLE %s (%s)\n%!" name why)
      r.Corruption.unreachable;
    List.iter
      (fun name -> Printf.printf "NOT CHECKED %s — no verifier\n%!" name)
      r.Corruption.unverified;
    let n = List.length entries in
    let silent =
      r.Corruption.unverified @ List.map fst r.Corruption.unreachable
    in
    (* Never a bare "0 corrupt chunks" while some store has said nothing: that
       line is the one a reader takes away, and alone it reads as a clean bill
       of health for the whole domain. *)
    Printf.printf "%d corrupt chunk%s%s\n" n
      (if n = 1 then "" else "s")
      (match silent with
        | [] -> ""
        | names ->
            Printf.sprintf ", and nothing checked %s" (String.concat ", " names));
    Lwt.return (if Integrity.unhealthy r then 1 else 0)
  in
  (* What the sweep is doing, from outside it. The requests delete themselves as
     each shard finishes, so counting what is left is the progress bar — and
     markers accumulate as they are found, so a run that is turning things up
     says so while it runs rather than at the end.

     Both are plain listings of prefixes the client already reads. Nothing here
     talks to a function. *)
  let watchers =
    let on_progress ~store ~left ~found =
      Hashtbl.replace per_store store (left, found);
      current := Some (doing store "waiting on the bucket");
      if left > 0 then
        Printf.eprintf "%s: %d shard request(s) left, %d corrupt so far\n%!"
          store left found
    in
    let on_done ~store ~found =
      Printf.eprintf "%s: done — %d corrupt chunk(s)\n%!" store found
    in
    let on_stalled ~store =
      Printf.eprintf
        "%s: nothing has been picked up in a while — check the bucket's \
         notification and the function's logs\n\
         %!"
        store
    in
    (on_progress, on_done, on_stalled)
  in
  (* Fails rather than reporting a check that did not happen: a store with
     nothing on its side to run one says so, and saying "queued" anyway would be
     the same lie as printing zero for a store nobody looks at. *)
  let verify (module C : Conf_lwt.S) =
    let open Lwt.Syntax in
    let module I = Integrity.Make (C) in
    let on_progress, on_done, on_stalled = watchers in
    let on_answers answers =
      List.iter
        (fun (a : Integrity.answer) ->
          match a.Integrity.queued with
            | Some n ->
                Printf.eprintf "%s: queued %d shard request(s)\n%!"
                  a.Integrity.store n
            | None -> ())
        answers;
      List.iter
        (fun (a : Integrity.answer) ->
          match a.Integrity.queued with
            | None ->
                Printf.eprintf
                  "%s: cannot check itself — no verifier runs on that store\n"
                  a.Integrity.store
            | Some _ -> ())
        answers
    in
    let+ outcome = I.verify ~on_answers ~on_progress ~on_done ~on_stalled () in
    match outcome with
      | `Nothing_queued ->
          Printf.eprintf
            "Nothing was asked to check anything. A local store is swept by \
             tsync gc --verify instead.\n";
          1
      | `Watched -> 0
  in
  let repair (module C : Conf_lwt.S) source dry_run verbose =
    let open Lwt.Syntax in
    let module Rp = Repair_lwt.Make (C) in
    (* Verbose says every chunk and where it has got to; quiet says only what it
       changed. A stale marker is the one outcome quiet leaves out: it is the
       common case on a store whose events arrived out of order, and it means
       nothing was wrong. *)
    let+ s =
      Rp.run ?source ~dry_run
        ~on_start:(fun ~total ->
          planned := total;
          if verbose then
            Printf.eprintf "%d marked chunk%s to work through\n%!" total
              (if total = 1 then "" else "s"))
        ~on_chunk:(fun ~done_ ~total ~chunk_key ~store outcome ->
          checked := done_;
          if outcome = Repair.Unrepairable then incr unrepairable;
          current := Some (doing store chunk_key);
          let line = Repair.describe ~chunk_key ~store outcome in
          if verbose then
            Printf.printf "[%*d/%d] %s\n%!"
              (String.length (string_of_int total))
              done_ total line
          else if outcome <> Repair.Cleared then Printf.printf "%s\n%!" line)
        ()
    in
    Printf.printf
      "%d chunk%s: %d repaired, %d stale marker%s cleared, %d unrepairable%s\n"
      s.Repair.checked
      (if s.Repair.checked = 1 then "" else "s")
      s.Repair.repaired s.Repair.cleared
      (if s.Repair.cleared = 1 then "" else "s")
      s.Repair.unrepairable
      (if dry_run then " (dry run, nothing written)" else "");
    if s.Repair.unrepairable > 0 then (
      Printf.eprintf
        "\nNo copy of these chunks hashes to its own key anywhere:\n";
      List.iter (fun k -> Printf.eprintf "  %s\n" k) s.Repair.lost;
      Printf.eprintf
        "Nothing here can supply them: re-upload the files that use them, or \
         fill this backend from one that still has them (tsync mirror).\n";
      1)
    else 0
  in
  let run domain do_verify do_repair detail source dry_run verbose =
    set_verbose verbose;
    let (module C : Conf_lwt.S) = load_conf ?domain () in
    if do_verify && do_repair then
      failwith "--verify and --repair are separate steps; run one.";
    let code =
      run_lwt
        ~report:(fun () ->
          report_job
            (module C)
            ~kind:
              (if do_verify then "data-integrity --verify"
               else if do_repair then "data-integrity --repair"
               else "data-integrity")
            ~current:(fun () -> !current)
            ~counters:(fun () ->
              if do_verify then
                [("requests left", sum_stores fst); ("corrupt", sum_stores snd)]
              else if do_repair then
                [
                  ("chunks", !checked);
                  ("planned", !planned);
                  ("unrepairable", !unrepairable);
                ]
              else [("corrupt", !corrupt)])
            ())
        (if do_verify then verify (module C)
         else if do_repair then repair (module C) source dry_run verbose
         else report (module C) detail)
    in
    if code <> 0 then exit code
  in
  let verify_arg =
    Arg.(
      value & flag
      & info ["verify"]
          ~doc:
            "Ask every store that can to check all of its chunks, then follow \
             it: one request per shard is queued, and the count left is \
             reported as the store works through them. Interrupting stops the \
             watching, not the checking. Fails if no store can — a local store \
             is swept by $(b,tsync gc --verify) instead. Reads every byte, on \
             the store's side.")
  in
  let repair_arg =
    Arg.(
      value & flag
      & info ["repair"]
          ~doc:
            "Rewrite what was found, from a copy that hashes to the right key. \
             With $(b,--verbose), every chunk is reported as it is done, with \
             its position in the total.")
  in
  let detail_arg =
    Arg.(
      value & flag
      & info ["detail"]
          ~doc:"With no other flag: also say what each bad chunk hashed to.")
  in
  let source_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["source"] ~docv:"NAME"
          ~doc:
            "With $(b,--repair): take replacement bytes only from this store.")
  in
  let dry_run_arg =
    Arg.(
      value & flag
      & info ["dry-run"]
          ~doc:
            "With $(b,--repair): report what would be rewritten, write nothing.")
  in
  Cmd.v
    (Cmd.info "data-integrity"
       ~doc:
         "Chunks that are not what their names say: ask for a check \
          ($(b,--verify)), list what was found (the default), or put it right \
          ($(b,--repair)).")
    Term.(
      const run $ domain_arg $ verify_arg $ repair_arg $ detail_arg $ source_arg
      $ dry_run_arg $ verbose_arg)
