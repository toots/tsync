open Cmdliner
open Common

(* [<domain>:<path>] names a domain whether or not it is mounted here, which a
   path alone cannot do. Only a name the config knows is read that way, so a
   local file whose name happens to carry a colon still reaches the filesystem. *)
let split_named cfg arg =
  match String.index_opt arg ':' with
    | None -> None
    | Some i ->
        let name = String.sub arg 0 i in
        let rel = String.sub arg (i + 1) (String.length arg - i - 1) in
        if
          List.exists
            (fun (d : Conf_parsing.domain) -> d.Conf_parsing.name = name)
            cfg.Conf_parsing.domains
        then
          Some
            ( name,
              if String.length rel > 0 && rel.[0] = '/' then
                String.sub rel 1 (String.length rel - 1)
              else rel )
        else None

(* Which side of the wire each argument names: a domain it says outright, a
   domain root the path sits under, or the local filesystem. *)
let endpoint_of ?domain cfg arg =
  match split_named cfg arg with
    | Some (name, rel) -> `Domain (name, rel)
    | None -> (
        match Daemons.domain_for_path ?domain ~paths:runtime_paths cfg arg with
          | Some (d, rel) -> `Domain (d.Conf_parsing.name, rel)
          | None | (exception _) -> `Local arg)

let cmd : unit Cmd.t =
  let src_arg =
    Arg.(
      required
      & pos 0 (some string) None
      & info [] ~docv:"SRC"
          ~doc:
            "Source, as a path or as $(b,DOMAIN:/path). A path in a mounted \
             domain names that domain.")
  in
  let dst_arg =
    Arg.(
      required
      & pos 1 (some string) None
      & info [] ~docv:"DST" ~doc:"Destination, named the same way as $(i,SRC).")
  in
  let move_arg =
    Arg.(
      value & flag
      & info [ "move" ]
          ~doc:
            "Remove each source once its destination is published. Within one \
             domain and onto nothing, this is a rename and costs one journal \
             entry.")
  in
  let dry_run_arg =
    Arg.(
      value & flag
      & info [ "dry-run"; "n" ] ~doc:"Print what would be done and do nothing.")
  in
  let run domain src dst move dry_run v =
    set_verbose v;
    let cfg = load_config () in
    let src_end = endpoint_of ?domain cfg src
    and dst_end = endpoint_of ?domain cfg dst in
    let domain_name, src_e, dst_e =
      match (src_end, dst_end) with
        | `Local _, `Local _ ->
            failwith
              "neither path is under a tsync domain -- use rsync(1) for that"
        | `Domain (a, _), `Domain (b, _) when a <> b ->
            failwith
              (Printf.sprintf
                 "%s and %s are in different domains, which is a chunk copy \
                  rather than a manifest one -- see tsync mirror"
                 a b)
        | `Domain (a, ra), `Domain (_, rb) ->
            (a, Rsync.Domain ra, Rsync.Domain rb)
        | `Domain (a, ra), `Local p -> (a, Rsync.Domain ra, Rsync.Local p)
        | `Local p, `Domain (a, rb) -> (a, Rsync.Local p, Rsync.Domain rb)
    in
    let (module C : Conf_lwt.S) = make_conf ~domain:domain_name cfg in
    let current = ref None and copied = ref 0 and skipped = ref 0 in
    let code =
      run_lwt
        ~report:(fun () ->
          report_job
            (module C)
            ~kind:"rsync" ~target:dst
            ~current:(fun () -> !current)
            ~counters:(fun () ->
              [ ("copied", !copied); ("skipped", !skipped) ])
            ())
        (let open Lwt.Syntax in
         let module Rs = Rsync_lwt.Make (C) in
         let+ summary =
           Rs.run ~move ~dry_run
             ~on_entry:(fun ~rel decision ->
               current := Some rel;
               (match decision with
                 | Rsync.Skip _ -> incr skipped
                 | _ -> incr copied);
               if dry_run || !verbose then
                 Printf.printf "%-12s %s\n%!" (Rsync.describe decision) rel)
             ~src:src_e ~dst:dst_e ()
         in
         Printf.printf
           "\n%d copied, %d skipped, %d director%s, %d failed (%s moved)\n"
           summary.Rsync.copied summary.Rsync.skipped summary.Rsync.dirs
           (if summary.Rsync.dirs = 1 then "y" else "ies")
           summary.Rsync.failed
           (human_bytes (Int64.to_int summary.Rsync.bytes_moved));
         if summary.Rsync.failed > 0 then 1 else 0)
    in
    if code <> 0 then exit code
  in
  Cmd.v
    (Cmd.info "rsync"
       ~doc:
         "Copy files by content rather than by bytes. Within one domain the \
          chunks are already stored, so a copy publishes a manifest and moves \
          nothing; to or from this machine, only what differs is transferred.")
    Term.(
      const run $ domain_arg $ src_arg $ dst_arg $ move_arg $ dry_run_arg
      $ verbose_arg)
