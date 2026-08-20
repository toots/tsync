type domain = (string * Frontend.binding) list

(* Do NOT touch Lwt here: any Lwt_unix/Lwt_preemptive call initializes the
   shared notification eventfd, and a child inheriting it across the fork below
   would have its worker wakeups delivered to the wrong process. *)

(* One binding per (domain × frontend), grouped by frontend. Each group is its
   own process (all but the last forked), so distinct frontends on one domain
   run concurrently.

   The flag marks the one process that keeps each domain converging with the
   store. At most one may: they share a cache root and a bookmark with no
   arbitration between them, and the same client uuid, so neither could tell the
   other's work from its own. It goes to the first frontend listed, by position —
   naming the frontend type would hand it to both halves of a domain that listed
   one type twice. *)
let bindings_by_frontend domains =
  let all =
    List.concat_map
      (fun d -> List.mapi (fun i (name, b) -> (name, (b, i = 0))) d)
      domains
  in
  let order =
    List.fold_left
      (fun acc (name, _) -> if List.mem name acc then acc else acc @ [name])
      [] all
  in
  List.map
    (fun name ->
      ( name,
        List.filter_map (fun (n, b) -> if n = name then Some b else None) all ))
    order

let resolve name =
  match Frontend.find name with
    | Some m -> m
    | None ->
        failwith
          (Printf.sprintf
             "frontend %s is configured but not compiled into this binary" name)

(* The frontend's own wording, which knows what to point the user at instead. *)
let refuse name =
  let (module F : Frontend.S) = resolve name in
  F.start []

let run ?(on_leaf = fun ~name:_ -> ()) domains =
  let run_group (name, bindings) =
    let (module F : Frontend.S) = resolve name in
    Log.debug "starting frontend %s (%d domains)" name (List.length bindings);
    (* After the fork, so each process is named for what it runs. *)
    on_leaf ~name;
    (* Sized here because only this side knows what else shares the leaf, and
       after the fork because it is the first thing to touch Lwt. *)
    let serve items =
      Frontend.cap_blocking_pool
        ~concurrency:(Frontend.binding_concurrency (List.map fst items));
      F.start
        (List.map
           (fun (binding, owns) ->
             let module C = (val binding.Frontend.conf : Conf.S) in
             let module E = Domain_engine.Make (C) in
             let module P = Domain_engine.Passive (E) in
             {
               Frontend.binding;
               domain =
                 (if owns then (module E : Domain_engine.Domain)
                  else (module P : Domain_engine.Domain));
             })
           items)
    in
    match F.topology with
      | `One_process -> serve bindings
      | `Process_per_binding ->
          Frontend.run_forked (fun b -> serve [b]) bindings
      | `Not_a_daemon -> refuse name
  in
  let groups = bindings_by_frontend domains in
  (* Before the first fork: a frontend that cannot be served under the daemon
     says so while there are no siblings left running behind it. *)
  List.iter
    (fun (name, _) ->
      let (module F : Frontend.S) = resolve name in
      if F.topology = `Not_a_daemon then refuse name)
    groups;
  Frontend.run_forked run_group groups
