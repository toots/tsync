open Cmdliner
open Common

type progress = { size : int64; mutable moved : int64; rate : Metrics.counter }

let cmd : unit Cmd.t =
  let paths_arg =
    Arg.(
      value
      & pos_left ~rev:true 0 (Location.conv `In_domain) []
      & info [] ~docv:"PATH"
          ~doc:
            "Files or folders to export, domain-relative or as \
             $(b,DOMAIN:/path). With none, the whole domain.")
  in
  let dst_arg =
    Arg.(
      required
      & pos ~rev:true 0 (some string) None
      & info [] ~docv:"DIR" ~doc:"Destination folder (created if needed)")
  in
  let source_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["source"] ~docv:"NAME"
          ~doc:
            "Backend to read from, by its configured name. Default: the \
             domain's own order, the primary first.")
  in
  let parallelism_arg =
    Arg.(
      value
      & opt (some int) None
      & info ["parallelism"; "j"] ~docv:"N"
          ~doc:
            "Chunks fetched at once, each held in memory while it is. Default: \
             the domain's $(b,maxDownloads). Lower it on a slow link, where \
             more of them at once is each of them timing out.")
  in
  (* Every path has to be the same domain's, one run reading one tree. *)
  let placed ?domain cfg paths =
    let places =
      List.map
        (fun arg ->
          match Location.place ?domain cfg arg with
            | Ok place -> place
            | Error msg -> failwith msg)
        paths
    in
    let names =
      List.sort_uniq compare
        (Option.to_list domain
        @ List.map (fun (p : Location.place) -> p.Location.name) places)
    in
    match names with
      | [] | [_] ->
          ( (match names with [name] -> Some name | _ -> None),
            List.map (fun (p : Location.place) -> p.Location.rel) places )
      | names ->
          failwith
            ("one domain at a time, and these name "
            ^ String.concat " and " names)
  in
  let run domain source parallelism paths dst v =
    set_verbose v;
    let cfg = load_config () in
    let domain, paths = placed ?domain cfg paths in
    let (module C : Conf_lwt.S) =
      let conf = make_conf ?domain cfg in
      let conf =
        match source with Some name -> reading_from name conf | None -> conf
      in
      match parallelism with Some n -> reading_at_most n conf | None -> conf
    in
    let dst =
      if Filename.is_relative dst then Filename.concat (Sys.getcwd ()) dst
      else dst
    in
    let live = live_output () in
    let active : (string, progress) Hashtbl.t = Hashtbl.create 8 in
    let overall = Metrics.counter () in
    let files = ref 0 and finished = ref 0 and failed = ref 0 in
    let moved = ref 0L and total = ref 0L in
    let state () =
      {
        Export_display.files = !files;
        finished = !finished;
        moved = !moved;
        total = !total;
        rate = Metrics.rate overall;
        active =
          Hashtbl.fold
            (fun name (p : progress) acc ->
              {
                Export_display.name;
                moved = p.moved;
                total = p.size;
                rate = Metrics.rate p.rate;
              }
              :: acc)
            active [];
      }
    in
    let draw () = live.block (Export_display.render (state ())) in
    let said fmt =
      Printf.ksprintf
        (fun line ->
          live.clear ();
          print_endline line)
        fmt
    in
    let on_event : Export.event -> unit = function
      | `Plan p ->
          files := p.Export.files;
          total := p.Export.bytes;
          moved := p.Export.present;
          Job_progress.plan ~basis:`Sent ~bytes:p.Export.bytes;
          Job_progress.settle ~bytes:p.Export.present ~sent:0L `Skipped
      | `Started { Export.rel; size; present } ->
          Hashtbl.replace active rel
            { size; moved = present; rate = Metrics.counter () }
      | `Landed (rel, bytes) ->
          let landed = Int64.of_int bytes in
          moved := Int64.add !moved landed;
          Metrics.count overall bytes;
          Job_progress.settle ~bytes:landed ~sent:landed `Done;
          Option.iter
            (fun (p : progress) ->
              p.moved <- Int64.add p.moved landed;
              Metrics.count p.rate bytes)
            (Hashtbl.find_opt active rel)
      | `Finished (rel, outcome) -> (
          Hashtbl.remove active rel;
          incr finished;
          match outcome with
            | `Exported -> said "exported %s" rel
            | `Exported_symlink -> said "exported %s (symlink)" rel
            | `Already_there -> vprintf "already there: %s" rel
            | `Failed why ->
                incr failed;
                said "FAILED   %s (%s)" rel why)
    in
    (* A stall has to show as a rate falling, which only a clock can draw. *)
    let rec tick () =
      let open Lwt.Syntax in
      let* () = Lwt_unix.sleep (if live.watching then 1. else 10.) in
      draw ();
      tick ()
    in
    let summary =
      run_lwt
        ~report:(fun () ->
          report_job
            (module C)
            ~kind:"export" ~target:dst
            ~current:(fun () ->
              Hashtbl.fold (fun rel _ _ -> Some rel) active None)
            ~counters:(fun () ->
              [("files", !finished); ("planned", !files); ("failed", !failed)])
            ())
        (let module E = Export_lwt.Make (C) in
        vprintf "exporting from %s to %s" C.domain_name dst;
        let ticking = tick () in
        Lwt.finalize
          (fun () -> E.run ~on_event ~dst ~paths ())
          (fun () ->
            Lwt.cancel ticking;
            live.clear ();
            Lwt.return_unit))
    in
    let plural n = if n = 1 then "" else "s" in
    Printf.printf "\n%d file%s exported%s%s\n" summary.Export.exported
      (plural summary.Export.exported)
      (if summary.Export.already_there > 0 then
         Printf.sprintf ", %d already there" summary.Export.already_there
       else "")
      (if summary.Export.failed > 0 then
         Printf.sprintf ", %d failed" summary.Export.failed
       else "");
    (match summary.Export.pending with
      | [] -> ()
      | pending ->
          Printf.eprintf
            "\n%d local change%s not uploaded yet, and so not in this export:\n"
            (List.length pending)
            (plural (List.length pending));
          List.iter (Printf.eprintf "  %s\n") pending);
    if summary.Export.failed > 0 || summary.Export.pending <> [] then exit 1
  in
  Cmd.v
    (Cmd.info "export"
       ~doc:
         "Write files of the domain out as plain files, read straight from its \
          backends: the whole domain, or the files and folders named. Each \
          file is given its space up front, fetched in parallel, checked chunk \
          by chunk, and resumed where an earlier run stopped.")
    Term.(
      const run $ domain_arg $ source_arg $ parallelism_arg $ paths_arg
      $ dst_arg $ verbose_arg)
