open Cmdliner
open Common

let cmd : unit Cmd.t =
  let source_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["source"] ~docv:"NAME"
          ~doc:
            "Backend to copy from, by its configured name. Default: the \
             primary backend.")
  in
  let manifests_arg =
    Arg.(
      value & flag
      & info ["manifests"]
          ~doc:
            "Copy only the manifests namespace (skip chunks, journal, \
             versions, cursor) — a cheap way to complete a backend's structure \
             without hauling chunk data.")
  in
  let path_arg =
    Arg.(
      value
      & opt (some string) None
      & info ["path"] ~docv:"PATH"
          ~doc:
            "Copy only what is under this domain-relative folder: its files, \
             and the chunks their manifests name. Journal, versions and cursor \
             are skipped — they describe the whole domain, not a subtree.")
  in
  let run domain source manifests_only path v =
    set_verbose v;
    (* Mirror copies between the stores themselves, so it reads [C.members]
       rather than going through the composite. *)
    let (module C : Conf_lwt.S) = load_conf ?domain () in
    let src =
      Option.value source
        ~default:(match C.members with m :: _ -> m.Backend.name | [] -> "")
    in
    let current = ref None and planned = ref 0 in
    let copied = ref 0 and checked = ref 0 in
    (* Ahead of {!run_lwt} rather than inside the promise it is handed: that
       argument is evaluated before reporting starts, so a raise there is a
       command with no row and no failed state to show. *)
    if List.length C.members < 2 then
      failwith
        (Printf.sprintf
           "mirror needs at least two configured backends; %s has %d."
           C.domain_name (List.length C.members));
    if manifests_only && path <> None then
      failwith "--manifests and --path select different things; run one.";
    let code =
      run_lwt
        ~report:(fun () ->
          report_job
            (module C)
            ~kind:
              (match (manifests_only, path) with
                | _, Some _ -> "mirror --path"
                | true, None -> "mirror --manifests"
                | false, None -> "mirror")
            ~target:src
            ~current:(fun () -> !current)
            ~counters:(fun () ->
              [
                ("objects", !checked); ("planned", !planned); ("copied", !copied);
              ])
            ())
        (let open Lwt.Syntax in
         begin
           let scope =
             match (manifests_only, path) with
               | _, Some rel -> `Path rel
               | true, None -> `Manifests
               | false, None -> `All
           in
           vprintf "initiating remote sync: copying %s from %s..."
             (match scope with
               | `All -> "all objects"
               | `Manifests -> "manifests"
               | `Path rel -> Printf.sprintf "%s and its chunks" rel)
             src;
           let module M = Mirror_lwt.Make (C) in
           let on_list ~name =
             current := Some name;
             vprintf "  %s..." name
           in
           (* Every destination is examined for every source object, and they go
              one after another, so the run's own total is the product. *)
           let destinations =
             List.length
               (List.filter
                  (fun (m : (module Backend_lwt.Store) Backend.member) ->
                    m.Backend.name <> src)
                  C.members)
           in
           let on_scan ~objects ~bytes =
             planned := objects * destinations;
             (* A mirror spends its time asking destinations what they hold, and
                mostly they hold it: an estimate against what it happened to
                copy would answer with hours of transfer for a run that has
                minutes of checking left. *)
             Job_progress.plan ~basis:`Handled
               ~bytes:(Int64.mul bytes (Int64.of_int destinations));
             vprintf "scanned %s: %d object%s to check" src objects
               (if objects = 1 then "" else "s")
           in
           let on_start ~name ~key =
             incr checked;
             current := Some (doing name (Stored_key.to_string key))
           in
           (* As each object lands rather than as a list at the end: the list
              was the whole keyspace of a first resync, held to print it. *)
           let on_entry ~name ~key ~size ~outcome =
             let key = Stored_key.to_string key in
             let size = Int64.of_int size in
             match outcome with
               | `Present -> Job_progress.settle ~bytes:size ~sent:0L `Skipped
               | `Copied (reason, bytes) ->
                   Job_progress.settle ~bytes:size ~sent:(Int64.of_int bytes)
                     `Done;
                   incr copied;
                   let why =
                     match reason with
                       | `Missing -> "missing"
                       | `Wrong_size -> "wrong size"
                   in
                   if !verbose then
                     vprintf "  copied %s (%s, %s) -> %s" key
                       (human_bytes bytes) why name
                   else Printf.printf "copied %s -> %s\n%!" key name
           in
           let+ dests =
             M.resync ~source:src ~scope ~on_scan ~on_list ~on_start ~on_entry
               ()
           in
           List.iter
             (fun (dst : Mirror.dest_stats) ->
               Printf.printf "%s -> %s: %d object%s checked, %d copied (%s)\n"
                 src dst.Mirror.name dst.Mirror.checked
                 (if dst.Mirror.checked = 1 then "" else "s")
                 dst.Mirror.copied
                 (human_bytes dst.Mirror.copied_bytes))
             dests;
           0
         end)
    in
    if code <> 0 then exit code
  in
  Cmd.v
    (Cmd.info "mirror"
       ~doc:
         "Fill one backend from another: copy every object of the domain \
          (manifests, chunks, journal, versions) that is missing or \
          size-mismatched on the other configured backends. Pass --manifests \
          to copy only the manifests, --path to copy one folder and the chunks \
          its files name. A chunk of the right size holding the wrong bytes is \
          data-integrity's to find, not this one's.")
    Term.(
      const run $ domain_arg $ source_arg $ manifests_arg $ path_arg
      $ verbose_arg)
