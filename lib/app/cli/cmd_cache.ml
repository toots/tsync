open Cmdliner
open Common

(* Residency, both directions, and what the cache is holding that nothing wants.

   Evicting and fetching are the same operation over the same paths with the
   wire verb swapped, and naming them apart put [restore] beside [revert], which
   recovers a lost thing -- this one only moves bytes on and off this machine.
   Pruning is the third thing that can be said about what is on this machine,
   which is why it lives here rather than under $(b,tsync gc): that one collects
   chunks in a store, needs a local main one, and has nothing to say about a
   domain served out of a remote. *)
let cmd : unit Cmd.t =
  let path_arg = Arg.(value & pos_all string [] & info [] ~docv:"PATH") in
  let evict_arg =
    Arg.(
      value & flag
      & info ["evict"] ~doc:"Drop these files or directories from the cache.")
  in
  let fetch_arg =
    Arg.(
      value & flag
      & info ["fetch"]
          ~doc:"Download these files or directories into the cache.")
  in
  let prune_arg =
    Arg.(
      value & flag
      & info ["prune"]
          ~doc:
            "Collect what a crash left in this domain's cache: temp files \
             whose writer is gone, and staged bodies no manifest names. Takes \
             no PATH. Safe to run while the daemon serves the domain.")
  in
  let grace_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["grace"] ~docv:"DUR"
          ~doc:
            "With $(b,--prune), leave staged bodies younger than this alone \
             (default: 1h). A body is written before the manifest that names \
             it, so a young one nothing names may be a write still in \
             progress. One count and one unit: $(b,30s), $(b,10m), $(b,2h).")
  in
  let act ~verb ~done_ ~domain paths =
    if paths = [] then failwith "cache --evict and --fetch need a PATH.";
    List.iter
      (fun path ->
        match Location.item ?domain path with
          | Error msg -> Printf.eprintf "Error: %s\n" msg
          | Ok (domain, item) -> (
              match
                Ipc.action ~socket_path:(domain_socket ~domain ()) ~domain ~item
                  verb
              with
                | _ -> Printf.printf "%s: %s\n" done_ path
                | exception Failure msg -> Printf.eprintf "Error: %s\n" msg))
      paths
  in
  (* Straight at the cache rather than through the daemon: there may not be one,
     and what this collects is named by what is on disk rather than by anything
     a serving process is holding. *)
  let prune ~domain ~grace paths =
    if paths <> [] then
      failwith "cache --prune takes no PATH; it collects the whole domain.";
    let (module C : Conf_lwt.S) = load_conf ?domain () in
    let module Md = Maintenance_lwt.Domain (C) in
    (* The declared list, not a call to each sweep: a sweep added there is one
       this collects, and one this collects is one [tsync status] names. *)
    let total =
      List.fold_left
        (fun acc (t : Maintenance_lwt.task) ->
          let swept = run_lwt (Maintenance_lwt.run_task t) in
          Printf.printf "  %-20s %d file(s), %s\n" t.Maintenance_lwt.name
            swept.Sweep.files
            (human_bytes swept.Sweep.bytes);
          Maintenance_lwt.add acc swept)
        Maintenance_lwt.nothing
        (Md.tasks ~staged_grace:grace ())
    in
    Printf.printf "%s: %d file(s), %s reclaimed.\n" C.domain_name
      total.Sweep.files
      (human_bytes total.Sweep.bytes)
  in
  let run paths domain evict fetch prune_ grace =
    match (evict, fetch, prune_) with
      | true, false, false -> act ~verb:"evict" ~done_:"Evicted" ~domain paths
      | false, true, false -> act ~verb:"restore" ~done_:"Fetched" ~domain paths
      | false, false, true ->
          let grace =
            match grace with
              | Some d -> parse_duration d
              | None -> Maintenance_lwt.default_staged_grace
          in
          prune ~domain ~grace paths
      | false, false, false ->
          failwith "cache needs --evict, --fetch or --prune."
      | _ ->
          failwith "--evict, --fetch and --prune do different things; run one."
  in
  Cmd.v
    (Cmd.info "cache"
       ~doc:
         "Move files on and off this machine: $(b,--evict) drops them from the \
          cache, $(b,--fetch) downloads them into it, $(b,--prune) collects \
          what a crash left behind.")
    Term.(
      const run $ path_arg $ domain_arg $ evict_arg $ fetch_arg $ prune_arg
      $ grace_arg)
