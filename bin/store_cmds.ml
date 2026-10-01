open Cmdliner
open Tsync_core
open Tsync_gc
open Cli

(* 07 §5.1: narration goes to stderr, so stdout stays the result. *)
let narration verbose = if verbose then Narrate.stderr else Narrate.none

let store_command ~what name f =
  let config = config () in
  Tsync_owner.Owner.store_command ~what config (domain ?name config) f

let dry_note apply =
  if apply then "" else " (dry run: nothing changed; --apply to act)"

let outcome = function
  | Collector.Completed -> "completed"
  | Suspended { phase; cursor } ->
      Printf.sprintf "left open in %s after %S"
        (Gc_record.phase_name phase)
        cursor
  | Halted reason -> "stopped, left open: " ^ reason

let print_survey (s : Collector.survey) =
  say "%s: %d chunks referenced, %d reclaimable (%s)%s" s.surveyed
    s.chunks_referenced s.chunks_reclaimable
    (Narrate.size s.bytes_reclaimable)
    (dry_note false);
  Option.iter
    (fun (phase, cursor) ->
      say "  a run is open: %s after %S" (Gc_record.phase_name phase) cursor)
    s.run;
  if s.run_unreadable then say "  a run record is present but unreadable";
  List.iter
    (fun (copy, n) -> say "  %s would be told %d deletions" copy n)
    s.per_copy;
  if s.chunks_missing <> [] then (
    say "  %d referenced chunks are missing from %s:"
      (List.length s.chunks_missing)
      s.surveyed;
    List.iter
      (fun c -> say "    %s" (Chunk_key.to_string c))
      (List.filteri (fun i _ -> i < 20) s.chunks_missing));
  if s.chunks_corrupt > 0 then
    say "  %d referenced chunks misread" s.chunks_corrupt

let print_stats (s : Collector.stats) =
  say "%s: %s; %d namespaces marked, %d chunks promoted, %d reclaimed (%s)"
    s.main (outcome s.outcome) s.roots_marked s.chunks_promoted
    s.chunks_reclaimed
    (Narrate.size s.bytes_reclaimed);
  if s.chunks_verified > 0 then
    say "  verified %d: %d corrupt, %d unreadable, %d markers cleared"
      s.chunks_verified s.chunks_corrupt s.chunks_unreadable s.chunks_cleared

let failure = function
  | Collector.Busy -> fail "another collection holds this domain's run lock"
  | Unsupported reason -> fail "cannot collect: %s" reason

let print_status (s : Collector.status) =
  say "%s: %s; generation %s%s" s.collected
    (match s.record with
      | Absent -> "no run open"
      | Unreadable -> "a run record is present but unreadable"
      | Record r ->
          Printf.sprintf "run %s open in %s after %S" (Gc_record.run_name r)
            (Gc_record.phase_name r.phase)
            r.cursor)
    (match s.generation with
      | Some g ->
          string_of_int g
          ^ if g mod 2 = 1 then " (deletions on copies in flight)" else ""
      | None -> "unreadable")
    (if s.owed > 0 then
       Printf.sprintf ", %d deletion batches owed to copies" s.owed
     else "")

(* The copies' side of a collection (gc §5.7): the bucket function, and the
   discard requests it has not consumed. *)
let copies_action act (dom : Tsync_domain.Domain.t) =
  let c = dom.composite in
  match act with
    | `Probe ->
        let copies =
          List.filter
            (fun (m : Tsync_store.Composite.member) ->
              (m.role = Replica || m.role = Backfill)
              && m.store.bucket_functions)
            (Tsync_store.Composite.members c)
        in
        if copies = [] then
          say "no copy of this domain can run a bucket function";
        List.iter
          (fun (m : Tsync_store.Composite.member) ->
            say "%s: probing its bucket function (up to 3 minutes)" m.name;
            say "  %s"
              (if Tsync_store.Composite.probe c m then "confirmed"
               else "not confirmed: requests were not consumed"))
          copies;
        0
    | `Outstanding ->
        (match Tsync_store.Composite.outstanding c with
          | [] -> say "no discard request outstanding"
          | l ->
              List.iter
                (fun (o : Tsync_store.Composite.outstanding) ->
                  say "%s: %s, %d keys, %.0f min old" o.copy
                    (Key.to_string o.request) o.keys (o.age /. 60.))
                l);
        0
    | `Retry ->
        say "%d discard requests re-delivered"
          (Tsync_store.Composite.retry_outstanding c);
        0

let gc apply verify abort budget show_status copies name verbose =
  set_verbose verbose;
  run (fun () ->
      match copies with
        | Some act -> store_command ~what:"tsync gc" name (copies_action act)
        | None ->
            if show_status then (
              let config = config () in
              let dom =
                Tsync_domain.Domain.build ~owner:false config
                  (domain ?name config)
              in
              match Collector.status dom.composite with
                | [] ->
                    fail
                      "no main of this domain is a filesystem store local to \
                       this host"
                | l ->
                    List.iter print_status l;
                    0)
            else
              store_command
                ~what:(if abort then "tsync gc --abort" else "tsync gc")
                name
                (fun dom ->
                  let c = dom.composite in
                  if apply || abort then (
                    match
                      Collector.run ?budget ~narrate:(narration verbose) ~verify
                        ~keep:abort c
                    with
                      | Error f -> failure f
                      | Ok stats ->
                          List.iter print_stats stats;
                          if
                            List.for_all
                              (fun (s : Collector.stats) ->
                                s.outcome = Completed)
                              stats
                          then 0
                          else 1)
                  else (
                    match
                      Collector.dry_run ~narrate:(narration verbose) ~verify c
                    with
                      | Error f -> failure f
                      | Ok surveys ->
                          List.iter
                            (function
                              | Ok s -> print_survey s
                              | Error reason -> say "survey stopped: %s" reason)
                            surveys;
                          if List.for_all Result.is_ok surveys then 0 else 1)))

let apply_arg =
  Arg.(value & flag & info ["apply"] ~doc:"Act; without it, only report.")

let gc_cmd =
  let verify =
    Arg.(value & flag & info ["verify"] ~doc:"Re-hash the chunks examined.")
  and abort =
    Arg.(
      value & flag
      & info ["abort"] ~doc:"Abandon the open run, putting every chunk back.")
  and budget =
    Arg.(
      value
      & opt (some float) None
      & info ["budget"] ~docv:"SECONDS"
          ~doc:"Leave the run open after this long.")
  and show_status =
    Arg.(
      value & flag
      & info ["status"] ~doc:"Show the collection state; change nothing.")
  and copies =
    Arg.(
      value
      & vflag None
          [
            ( Some `Probe,
              info ["probe"]
                ~doc:"Check that each copy's bucket function is deployed." );
            ( Some `Outstanding,
              info ["outstanding"]
                ~doc:"List discard requests the copies have not consumed." );
            ( Some `Retry,
              info ["retry-outstanding"]
                ~doc:
                  "Rewrite outstanding requests with the keys still to delete, \
                   firing them again." );
          ])
  in
  cmd "gc"
    ~doc:"Collect chunks no file or version names (a dry run by default)."
    Term.(
      const gc $ apply_arg $ verify $ abort $ budget $ show_status $ copies
      $ domain_arg $ verbose)

(* 07 §5.3: a date at local midnight. *)
let cutoff_of date =
  match String.split_on_char '-' date with
    | [y; m; d] -> (
        match
          (int_of_string_opt y, int_of_string_opt m, int_of_string_opt d)
        with
          | Some y, Some m, Some d ->
              fst
                (Unix.mktime
                   {
                     Unix.tm_year = y - 1900;
                     tm_mon = m - 1;
                     tm_mday = d;
                     tm_hour = 0;
                     tm_min = 0;
                     tm_sec = 0;
                     tm_wday = 0;
                     tm_yday = 0;
                     tm_isdst = false;
                   })
          | _ -> fail "%s is not a date (YYYY-MM-DD)" date)
    | _ -> fail "%s is not a date (YYYY-MM-DD)" date

let expire apply date name verbose =
  set_verbose verbose;
  run (fun () ->
      let cutoff = cutoff_of date in
      store_command ~what:"tsync expire" name (fun dom ->
          let module R = Retention.Make ((val Tsync_domain.Domain.context dom)) in
          let r = R.expire ~narrate:(narration verbose) ~apply ~cutoff () in
          say "trash %d, versions %d, journal entries %d, shares %d%s"
            r.counts.trash_deleted r.counts.versions_deleted
            r.counts.journal_deleted r.counts.shares_deleted (dry_note apply);
          List.iter
            (fun (id, reason) ->
              say "  purge of %s stopped: %s" (Folder_id.to_string id) reason)
            r.stopped;
          List.iter
            (fun k -> say "  unparseable share left: %s" (Key.to_string k))
            r.unparseable_shares;
          if r.stopped = [] then 0 else 1))

let expire_cmd =
  let date =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"DATE" ~doc:"Remove what is older than this day.")
  in
  cmd "expire"
    ~doc:"Remove trash, versions, journal entries and shares older than DATE."
    Term.(const expire $ apply_arg $ date $ domain_arg $ verbose)

(* 07 §2.5 read class: listing the trash changes nothing, so it runs here. *)
let trash_list name verbose =
  let config = config () in
  let dom =
    Tsync_domain.Domain.build ~owner:false config (domain ?name config)
  in
  let module T = Tsync_remote.Tree.Make ((val Tsync_domain.Domain.context dom)) in
  let restorable, stale =
    List.partition (fun (f : T.trashed) -> f.state <> `Live) (T.trashed ())
  in
  Narrate.say (narration verbose)
    "%s in the trash; %s skipped (their folders are live again, and expire \
     removes the entries)"
    (Narrate.count (List.length restorable) "folder")
    (Narrate.count (List.length stale) "stale entry" ~plural:"stale entries");
  List.iter
    (fun (f : T.trashed) ->
      say "%s  %s" (Narrate.date f.latest)
        (Option.value ~default:(f.name ^ " (path not recorded)") f.path))
    (List.sort
       (fun (a : T.trashed) (b : T.trashed) -> compare b.latest a.latest)
       restorable);
  0

let trash_restore name path =
  let config = config () in
  match
    Tsync_owner.Owner.request ~bulk:true ~what:"tsync trash --restore" config
      (domain ?name config) (Tsync_owner.Protocol.Trash_restore path)
  with
    | Restored n ->
        say "%s restored: %s announced to the other clients" path
          (Narrate.count n "folder and file" ~plural:"folders and files");
        0
    | Not_in_trash ->
        say "%s is not in the trash" path;
        1
    | Name_taken ->
        say "%s already exists; restore it elsewhere or move that one first"
          path;
        1

let trash apply purge restore name verbose =
  set_verbose verbose;
  run (fun () ->
      match (purge, restore) with
        | Some _, Some _ -> fail "--purge and --restore go one at a time"
        | None, None -> trash_list name verbose
        | None, Some path -> trash_restore name path
        | Some path, None ->
            store_command ~what:"tsync trash --purge" name (fun dom ->
                let module R =
                  Retention.Make ((val Tsync_domain.Domain.context dom)) in
                match R.purge ~narrate:(narration verbose) ~apply path with
                  | Purged n ->
                      say "%s: %d objects purged%s" path n (dry_note apply);
                      0
                  | Not_in_trash ->
                      say "%s is not in the trash" path;
                      1
                  | Live_elsewhere ->
                      say "%s is live elsewhere; not purged" path;
                      1))

let trash_cmd =
  let purge =
    Arg.(
      value
      & opt (some string) None
      & info ["purge"] ~docv:"PATH" ~doc:"Purge this trashed folder now.")
  and restore =
    Arg.(
      value
      & opt (some string) None
      & info ["restore"] ~docv:"PATH"
          ~doc:"Bring this trashed folder back where it was.")
  in
  cmd "trash" ~doc:"List the trash, or restore or purge a trashed folder."
    Term.(const trash $ apply_arg $ purge $ restore $ domain_arg $ verbose)

let cmds = [gc_cmd; expire_cmd; trash_cmd]
