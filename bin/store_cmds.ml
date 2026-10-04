open Cmdliner
open Tsync_core
open Tsync_gc
open Cli

(* 07 §2.5: the owner runs the job and streams its lines; Ctrl-C asks it to
   stop at its next unit boundary. *)
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
  early (fun () ->
      let name, paths =
        paths_in_domain ?name (Option.to_list purge @ Option.to_list restore)
      in
      match (purge, restore, paths) with
        | Some _, None, [path] -> run_job ?name verbose (Purge { apply; path })
        | _ ->
            set_verbose verbose;
            run (fun () ->
                match (purge, restore, paths) with
                  | Some _, Some _, _ ->
                      fail "--purge and --restore go one at a time"
                  | None, Some _, [path] -> trash_restore name path
                  | _ -> trash_list name))

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

(* 07 §5.2: a side is in a domain or local. *)
let rsync src dst move dry_run name verbose =
  early (fun () ->
      let config = config () in
      let side token =
        match Tsync_config.Domain_path.parse config token with
          | In_domain { domain; rel } -> (domain, true, rel)
          | Local path -> (None, false, path)
      in
      let sd, src_in_domain, src = side src
      and dd, dst_in_domain, dst = side dst in
      if not (src_in_domain || dst_in_domain) then
        refuse "one side must be in a domain (DOMAIN:PATH or :PATH)";
      match Tsync_config.Domain_path.agree ?name [sd; dd] with
        | Error e -> refuse "%s" e
        | Ok name ->
            run_job ?name verbose
              (Rsync { src; src_in_domain; dst; dst_in_domain; move; dry_run }))

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
        early @@ fun () ->
        let name, paths =
          match paths_in_domain ?name (List.rev rpaths) with
            | name, [] -> (name, [""])
            | named -> named
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

let mirror source skip_chunks path name verbose =
  if skip_chunks && path <> None then (
    prerr_endline "tsync: --skip-chunks and --path go one at a time";
    2)
  else
    early (fun () ->
        let name, paths = paths_in_domain ?name (Option.to_list path) in
        run_job ?name verbose
          (Mirror { source; skip_chunks; path = List.nth_opt paths 0 }))

let mirror_cmd =
  let source =
    Arg.(
      value
      & opt (some string) None
      & info ["source"] ~docv:"MEMBER"
          ~doc:"Copy from this member; the first in role order by default.")
  and skip_chunks =
    Arg.(
      value & flag
      & info ["skip-chunks"]
          ~doc:
            "Everything but the chunks: manifests, folder markers, versions, \
             journal entries and the cursor. Allowed while a collection is \
             open.")
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
    Term.(const mirror $ source $ skip_chunks $ path $ domain_arg $ verbose)

let share path expires token revoke clear name verbose =
  set_verbose verbose;
  early @@ fun () ->
  let name, paths = paths_in_domain ?name (Option.to_list path) in
  run (fun () ->
      let config = config () in
      let dom = domain ?name config in
      let ask req =
        Tsync_owner.Owner.request ~what:"tsync share" config dom req
      in
      match (revoke, clear, path) with
        | Some _, true, _ | Some _, _, Some _ | _, true, Some _ ->
            fail "--revoke, --clear-cache and a path go one at a time"
        | Some s, false, None ->
            if ask (Tsync_owner.Protocol.Share_revoke s) then (
              say "revoked";
              0)
            else (
              say "no share of %s holds that token"
                (Domain_name.to_string dom.name);
              1)
        | None, true, None ->
            let n, bytes = ask Tsync_owner.Protocol.Share_clear_cache in
            say "%d cached share objects deleted (%s)" n (Narrate.size bytes);
            0
        | None, false, _ ->
            let rel = Option.value ~default:"" (List.nth_opt paths 0) in
            let r =
              ask
                (Tsync_owner.Protocol.Share { item = Rel rel; expires; token })
            in
            say "%s" r.url;
            prerr_endline ("expires " ^ Narrate.date r.expires);
            0)

let share_cmd =
  let path =
    Arg.(
      value
      & pos 0 (some string) None
      & info [] ~docv:"PATH"
          ~doc:"The file or folder to share; the whole domain when none.")
  and expires =
    Arg.(
      value
      & opt (some duration) None
      & info ["expires"] ~docv:"DUR"
          ~doc:"How long the link lives (7d by default).")
  and token =
    Arg.(
      value
      & opt (some string) None
      & info ["token"] ~docv:"HEX"
          ~doc:"Use this token, 32 to 128 lowercase hex characters.")
  and revoke =
    Arg.(
      value
      & opt (some string) None
      & info ["revoke"] ~docv:"TOKEN|URL" ~doc:"Revoke a link of this domain.")
  and clear =
    Arg.(
      value & flag
      & info ["clear-cache"]
          ~doc:"Delete cached share downloads; links keep working.")
  in
  cmd "share"
    ~doc:"Create a public, expiring link to a file or folder (URL on stdout)."
    Term.(
      const share $ path $ expires $ token $ revoke $ clear $ domain_arg
      $ verbose)

(* 07 §5.6 [versions]: a read command, from the store; [--revert] goes through
   the owner. *)
module Versions (C : Tsync_remote.Context.S) = struct
  module R = Tsync_remote.Remote.Make (C)
  module T = Tsync_remote.Tree.Make (C)

  let manifest e = Manifest.decode (R.get_version e)

  (* A folder's path, climbed through its anchors; none for a folder in the
     trash or without an anchor. *)
  let folder_path id =
    let rec climb id acc depth =
      if Folder_id.is_root id then Some (String.concat "/" acc)
      else if depth > 256 then None
      else (
        match T.anchor id with
          | Some a when not (Folder.in_trash a) ->
              climb a.parent (a.aname :: acc) (depth + 1)
          | _ -> None)
    in
    climb id [] 0

  let line ns size what =
    say "%Ld  %s  %s%s" ns
      (Narrate.date (Int64.to_float ns /. 1e9))
      (Narrate.size size)
      (if what = "" then "" else "  " ^ what)

  let of_file path =
    let parent = Names.parent_of path and leaf = Names.leaf_of path in
    let parts = List.filter (( <> ) "") (String.split_on_char '/' parent) in
    let folder =
      if parts = [] then Some Folder_id.root
      else (
        match T.find Folder_id.root parts with
          | `Folder id -> Some id
          | _ -> None)
    in
    match folder with
      | None -> fail "%s: no such folder" parent
      | Some id ->
          let versions = R.list_versions id leaf in
          if versions = [] then say "%s has no saved versions" path;
          List.iter
            (fun (ns, e) ->
              match manifest e with
                | Some m -> line ns m.size ""
                | None -> line ns 0 "(unreadable)")
            versions;
          0

  let deleted () =
    let found =
      List.filter_map
        (fun (group, versions) ->
          match (String.index_opt group '/', versions) with
            | Some i, (ns, e) :: _ -> (
                match
                  (Folder_id.of_string (String.sub group 0 i), manifest e)
                with
                  | Some id, Some m when R.head_slot id m.name = None ->
                      Some
                        ( ns,
                          m.size,
                          match folder_path id with
                            | Some dir -> Names.join dir m.name
                            | None -> m.name ^ " (folder gone)" )
                  | _ -> None)
            | _ -> None)
        (R.all_versions ())
    in
    say "%s with saved versions"
      (Narrate.count (List.length found) "deleted file");
    List.iter
      (fun (ns, size, path) -> line ns size path)
      (List.sort (fun (a, _, _) (b, _, _) -> compare b a) found);
    0
end

let versions path revert version name verbose =
  set_verbose verbose;
  early @@ fun () ->
  let name, paths = paths_in_domain ?name (Option.to_list path) in
  let path = List.nth_opt paths 0 in
  run (fun () ->
      let config = config () in
      match (revert, path) with
        | true, None -> fail "--revert needs the PATH of a file"
        | true, Some path ->
            Tsync_owner.Owner.request ~what:"tsync versions --revert" config
              (domain ?name config)
              (Tsync_owner.Protocol.Revert { item = Rel path; version });
            say "%s is back at %s" path
              (match version with
                | Some ns -> Narrate.date (Int64.to_float ns /. 1e9)
                | None -> "its latest saved version");
            0
        | false, _ -> (
            let dom =
              Tsync_domain.Domain.build ~owner:false config
                (domain ?name config)
            in
            let module V = Versions ((val Tsync_domain.Domain.context dom)) in
            match path with Some p -> V.of_file p | None -> V.deleted ()))

let versions_cmd =
  let path = Arg.(value & pos 0 (some string) None & info [] ~docv:"PATH")
  and revert =
    Arg.(
      value & flag & info ["revert"] ~doc:"Put a saved version of PATH back.")
  and version =
    Arg.(
      value
      & opt (some int64) None
      & info ["version"] ~docv:"TS"
          ~doc:"The version to put back, as listed; the latest by default.")
  in
  cmd "versions"
    ~doc:
      "List a file's saved versions, or every deleted file; --revert puts one \
       back."
    Term.(const versions $ path $ revert $ version $ domain_arg $ verbose)

(* 07 §5.3: each path is one bulk request to the owner; a failed path does not
   stop the others. *)
let cache evict fetch keep paths name verbose =
  set_verbose verbose;
  match (evict, fetch) with
    | true, true | false, false ->
        prerr_endline "tsync: cache needs one of --evict and --fetch";
        2
    | _ when keep <> None && evict ->
        prerr_endline "tsync: --keep goes with --fetch";
        2
    | _ ->
        early @@ fun () ->
        let name, rels = paths_in_domain ?name paths in
        run (fun () ->
            let config = config () in
            let dom = domain ?name config in
            let shown rel =
              if rel = "" then Domain_name.to_string dom.name else rel
            in
            let one rel =
              match
                Tsync_owner.Owner.request ~bulk:true ~what:"tsync cache" config
                  dom
                  (if evict then Tsync_owner.Protocol.Evict (Rel rel)
                   else Restore { item = Rel rel; keep })
              with
                | (r : Tsync_owner.Protocol.counted) ->
                    say "%s: %s %s%s" (shown rel)
                      (Narrate.count r.succeeded "file")
                      (if evict then "online only" else "available offline")
                      (if r.failed > 0 then
                         Printf.sprintf ", %d failed" r.failed
                       else "");
                    r.failed = 0
                | exception (Fail.E _ as e) ->
                    prerr_endline
                      ("tsync: " ^ shown rel ^ ": " ^ (Fail.classify e).reason);
                    false
            in
            if List.for_all Fun.id (List.map one rels) then 0 else 1)

let cache_cmd =
  let evict =
    Arg.(
      value & flag
      & info ["evict"]
          ~doc:
            "Make the paths online only: drop their content from this machine.")
  and fetch =
    Arg.(
      value & flag
      & info ["fetch"]
          ~doc:
            "Make the paths available offline: download and keep their content.")
  and keep =
    Arg.(
      value
      & opt (some duration) None
      & info ["keep"] ~docv:"DUR"
          ~doc:"With --fetch, how long the content is kept (10d by default).")
  and paths =
    Arg.(
      non_empty & pos_all string []
      & info [] ~docv:"PATH"
          ~doc:"Files or folders of the domain; a folder covers its subtree.")
  in
  cmd "cache"
    ~doc:
      "Make files online only or available offline on this machine (exit 1 if \
       any failed)."
    Term.(const cache $ evict $ fetch $ keep $ paths $ domain_arg $ verbose)

let cmds =
  [
    cache_cmd;
    versions_cmd;
    gc_cmd;
    expire_cmd;
    trash_cmd;
    data_integrity_cmd;
    import_cmd;
    rsync_cmd;
    export_cmd;
    mirror_cmd;
    share_cmd;
  ]
