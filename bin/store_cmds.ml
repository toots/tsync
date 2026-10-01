open Cmdliner
open Tsync_core
open Tsync_gc
open Cli

(* 07 §2.5: the owner runs the job and streams its lines; Ctrl-C asks it to
   stop at its next unit boundary. *)
let job ?name verbose job =
  let config = config () in
  let dom = domain ?name config in
  let socket = Tsync_config.Paths.owner_socket dom.name in
  Tsync_owner.Owner.request
    ~what:("tsync " ^ Tsync_owner.Jobs.kind job)
    config dom
    ~on_line:(function
      | Started id ->
          Rt.spawn ~name:"cancel" (fun () ->
              Stop.wait ();
              prerr_endline
                "tsync: cancelling; the job stops at its next unit boundary";
              try
                ignore
                  (Tsync_owner.Protocol.call socket
                     (Tsync_owner.Protocol.Cancel id))
              with e -> Log.warn "cannot cancel: %s" (Printexc.to_string e))
      | line -> Tsync_owner.Handler.print_line line)
    (Tsync_owner.Protocol.Job { job; narrate = verbose })

(* Before the runtime starts, so every thread inherits the mask. *)
let run_job ?name verbose j =
  set_verbose verbose;
  Tsync_owner.Owner.stop_on_signals
    ~second:(fun () ->
      prerr_endline "tsync: interrupted again; exiting now";
      Unix._exit 130)
    ();
  run (fun () -> job ?name verbose j)

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

let gc apply verify abort budget show_status copies name verbose =
  match copies with
    | Some act -> run_job ?name verbose (Gc_copies act)
    | None when show_status ->
        set_verbose verbose;
        run (fun () ->
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
    | None -> run_job ?name verbose (Gc { apply; verify; abort; budget })

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
            ( Some Tsync_owner.Jobs.Probe,
              info ["probe"]
                ~doc:"Check that each copy's bucket function is deployed." );
            ( Some Tsync_owner.Jobs.Outstanding,
              info ["outstanding"]
                ~doc:"List discard requests the copies have not consumed." );
            ( Some Tsync_owner.Jobs.Retry_outstanding,
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
  run_job ?name verbose (Expire { apply; cutoff = cutoff_of date })

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
let trash_list name =
  let config = config () in
  let dom =
    Tsync_domain.Domain.build ~owner:false config (domain ?name config)
  in
  let module T = Tsync_remote.Tree.Make ((val Tsync_domain.Domain.context dom)) in
  let restorable, stale =
    List.partition (fun (f : T.trashed) -> f.state <> `Live) (T.trashed ())
  in
  Narrate.say (Display.narrate ())
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
  match (purge, restore) with
    | Some path, None -> run_job ?name verbose (Purge { apply; path })
    | _ ->
        set_verbose verbose;
        run (fun () ->
            match (purge, restore) with
              | Some _, Some _ -> fail "--purge and --restore go one at a time"
              | Some _, None | None, None -> trash_list name
              | None, Some path -> trash_restore name path)

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

let data_integrity verify repair dry_run detail source name verbose =
  if verify && repair then (
    prerr_endline "tsync: --verify and --repair go one at a time";
    2)
  else
    run_job ?name verbose
      (Integrity
         { verify; repair; apply = repair && not dry_run; detail; source })

let data_integrity_cmd =
  let verify =
    Arg.(
      value & flag
      & info ["verify"]
          ~doc:
            "Have each copy's bucket function re-check every chunk, and follow \
             it until done.")
  and repair =
    Arg.(
      value & flag
      & info ["repair"]
          ~doc:
            "Repair what can be: delete stale markers and trash entries, \
             anchor folders, adopt unreachable folders into the trash, rewrite \
             corrupt chunks from a sound copy.")
  and dry_run =
    Arg.(
      value & flag
      & info ["dry-run"] ~doc:"With --repair, report what it would do.")
  and detail = Arg.(value & flag & info ["detail"] ~doc:"List every finding.")
  and source =
    Arg.(
      value
      & opt (some string) None
      & info ["source"] ~docv:"MEMBER"
          ~doc:"Read sound copies of corrupt chunks from this member only.")
  in
  cmd "data-integrity"
    ~doc:"Check the domain's folder tree and chunks (exit 1 if unhealthy)."
    Term.(
      const data_integrity $ verify $ repair $ dry_run $ detail $ source
      $ domain_arg $ verbose)

(* The owner's working directory is not ours: the source goes absolute. *)
let import src only exclude force_rehash name verbose =
  let src =
    if Filename.is_relative src then Filename.concat (Sys.getcwd ()) src
    else src
  in
  if not (Sys.file_exists src && Sys.is_directory src) then (
    prerr_endline ("tsync: " ^ src ^ " is not a directory");
    2)
  else run_job ?name verbose (Import { src; only; exclude; force_rehash })

let import_cmd =
  let src =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"DIR" ~doc:"The directory whose content is imported.")
  and only =
    Arg.(
      value & opt_all string []
      & info ["only"] ~docv:"GLOB"
          ~doc:
            "Import only what matches, and everything under a matching folder.")
  and exclude =
    Arg.(
      value & opt_all string []
      & info ["exclude"] ~docv:"GLOB"
          ~doc:"Leave out what matches, by path or by name, at any depth.")
  and force_rehash =
    Arg.(
      value & flag
      & info ["force-rehash"]
          ~doc:"Upload and announce files the domain already has.")
  in
  cmd "import"
    ~doc:
      "Bring a local directory's content into the domain at the same relative \
       paths (exit 1 if any file failed)."
    Term.(
      const import $ src $ only $ exclude $ force_rehash $ domain_arg $ verbose)

(* [DOMAIN:PATH] names the domain side, [:PATH] the default domain's; anything
   else is a local path, made absolute since the owner's directory is not
   ours. *)
let endpoint arg =
  match String.index_opt arg ':' with
    | Some i when not (String.contains (String.sub arg 0 i) '/') ->
        let domain = String.sub arg 0 i
        and path = String.sub arg (i + 1) (String.length arg - i - 1) in
        let path =
          String.concat "/"
            (List.filter (( <> ) "") (String.split_on_char '/' path))
        in
        `Domain ((if domain = "" then None else Some domain), path)
    | _ ->
        `Local
          (if Filename.is_relative arg then Filename.concat (Sys.getcwd ()) arg
           else arg)

let rsync src dst move dry_run name verbose =
  let refuse msg =
    prerr_endline ("tsync: " ^ msg);
    2
  in
  let side = function
    | `Domain (d, p) -> (d, true, p)
    | `Local p -> (None, false, p)
  in
  let sd, src_in_domain, src = side (endpoint src)
  and dd, dst_in_domain, dst = side (endpoint dst) in
  match (sd, dd) with
    | _ when not (src_in_domain || dst_in_domain) ->
        refuse "one side must be in a domain (DOMAIN:PATH or :PATH)"
    | Some a, Some b when a <> b ->
        refuse "both sides must be in the same domain"
    | Some d, _ | None, Some d ->
        if name <> None && name <> Some d then
          refuse "the domain named in a path differs from --domain"
        else
          run_job ~name:d verbose
            (Rsync { src; src_in_domain; dst; dst_in_domain; move; dry_run })
    | None, None ->
        run_job ?name verbose
          (Rsync { src; src_in_domain; dst; dst_in_domain; move; dry_run })

let rsync_cmd =
  let src =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"SRC" ~doc:"A local path, or DOMAIN:PATH in a domain.")
  and dst =
    Arg.(
      required
      & pos 1 (some string) None
      & info [] ~docv:"DST" ~doc:"A local path, or DOMAIN:PATH in a domain.")
  and move =
    Arg.(
      value & flag & info ["move"] ~doc:"Drop each source once it is copied.")
  and dry_run =
    Arg.(
      value & flag
      & info ["n"; "dry-run"] ~doc:"Print each decision; change nothing.")
  in
  cmd "rsync"
    ~doc:
      "Copy or move between a local path and a domain, or within a domain, \
       sending only what differs (exit 1 if anything failed)."
    Term.(const rsync $ src $ dst $ move $ dry_run $ domain_arg $ verbose)

(* 07 §2.5 read class: export changes no domain state, so it runs here,
   reading the stores. *)
let export args source jobs name verbose =
  match List.rev args with
    | [] ->
        prerr_endline "tsync: export needs a destination directory";
        2
    | dir :: rpaths ->
        set_verbose verbose;
        Tsync_owner.Owner.stop_on_signals
          ~second:(fun () ->
            prerr_endline "tsync: interrupted again; exiting now";
            Unix._exit 130)
          ();
        let dst =
          if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir
          else dir
        in
        let paths =
          match List.rev rpaths with
            | [] -> [""]
            | l ->
                List.map
                  (fun p ->
                    String.concat "/"
                      (List.filter (( <> ) "") (String.split_on_char '/' p)))
                  l
        in
        run (fun () ->
            let config = config () in
            let dom =
              Tsync_domain.Domain.build ~owner:false config
                (domain ?name config)
            in
            let module X =
              Tsync_sync.Export.Make
                ((val Tsync_domain.Domain.context ?reading_from:source
                        ?reading_at_most:jobs dom)) in
            let r =
              X.export ~narrate:(Display.narrate ()) ~cancelled:Stop.requested
                ~cache_root:dom.cache_root ~dst paths
            in
            Display.clear ();
            say "exported %s (%s written), %d already there, %d failed%s"
              (Narrate.count r.exported "file")
              (Narrate.size r.bytes) r.already_there (List.length r.failed)
              (if r.cancelled then "; cancelled before the end" else "");
            List.iter (fun (d, why) -> say "  %s: %s" d why) r.failed;
            List.iter
              (fun p ->
                prerr_endline
                  ("tsync: " ^ p
                 ^ " has local changes not yet published; its published \
                    version was exported"))
              r.pending;
            if r.failed = [] && r.pending = [] && not r.cancelled then 0 else 1)

let export_cmd =
  let args =
    Arg.(
      non_empty & pos_all string []
      & info [] ~docv:"PATH... DIR"
          ~doc:
            "Domain paths to export (the whole domain when none), then the \
             directory.")
  and source =
    Arg.(
      value
      & opt (some string) None
      & info ["source"] ~docv:"MEMBER" ~doc:"Read from this member only.")
  and jobs =
    Arg.(
      value
      & opt (some int) None
      & info ["j"] ~docv:"N" ~doc:"Read at most N files at once.")
  in
  cmd "export"
    ~doc:
      "Write a domain's files to a local directory from the stores, resuming \
       an interrupted file (exit 1 on failures or on unpublished local \
       changes)."
    Term.(const export $ args $ source $ jobs $ domain_arg $ verbose)

let mirror source manifests path name verbose =
  if manifests && path <> None then (
    prerr_endline "tsync: --manifests and --path go one at a time";
    2)
  else (
    let path =
      Option.map
        (fun p ->
          String.concat "/"
            (List.filter (( <> ) "") (String.split_on_char '/' p)))
        path
    in
    run_job ?name verbose (Mirror { source; manifests; path }))

let mirror_cmd =
  let source =
    Arg.(
      value
      & opt (some string) None
      & info ["source"] ~docv:"MEMBER"
          ~doc:"Copy from this member; the first in role order by default.")
  and manifests =
    Arg.(
      value & flag
      & info ["manifests"] ~doc:"Only manifests and folder markers.")
  and path =
    Arg.(
      value
      & opt (some string) None
      & info ["path"] ~docv:"P"
          ~doc:"Only this file or folder, with every chunk it names.")
  in
  cmd "mirror"
    ~doc:
      "Copy what one member holds to the others; nothing is deleted on a \
       destination."
    Term.(const mirror $ source $ manifests $ path $ domain_arg $ verbose)

let cmds =
  [
    gc_cmd;
    expire_cmd;
    trash_cmd;
    data_integrity_cmd;
    import_cmd;
    rsync_cmd;
    export_cmd;
    mirror_cmd;
  ]
