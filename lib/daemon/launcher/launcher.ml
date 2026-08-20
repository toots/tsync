type domain = (string * Frontend.binding) list

(* Only {!recover} touches Lwt here, and only through an [Lwt_main.run] that
   returns before the first fork. The hazard is a child inheriting the
   notification eventfd and having its worker wakeups delivered to the parent;
   [Lwt_unix.fork] reinitialises the notification system in the child, which is
   why {!Frontend.run_forked} uses it.

   Nothing else here may touch Lwt: what runs after the forks belongs to a leaf,
   which starts its own loop. *)

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

(* What a crash left behind, collected while nothing is serving.

   Both halves name a leftover by an absence — a temp file nobody has renamed
   yet, a staged body no manifest names — which is what work in progress looks
   like too. Called from a process that serves the domain, either one takes what
   a sibling is in the middle of writing. Here there are no siblings: this
   returns before the first fork.

   Its own [Lwt_main.run], so no promise is still in flight when the forks
   happen. *)
let recover domains =
  (* Any one of a domain's bindings will do: they carry the same conf. *)
  let confs =
    List.filter_map
      (function [] -> None | (_, b) :: _ -> Some b.Frontend.conf)
      domains
  in
  Lwt_main.run
    (Lwt_list.iter_s
       (fun conf ->
         let module C = (val conf : Conf.S) in
         let module E = Domain_engine.Make (C) in
         Lwt.catch E.recover (fun exn ->
             (* One domain's leftovers are not another's problem, and none of
                them are worth refusing to start over. *)
             Log.err "recovering %s: %s" C.domain_name (Printexc.to_string exn);
             Lwt.return_unit))
       confs)

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
  recover domains;
  Frontend.run_forked run_group groups
