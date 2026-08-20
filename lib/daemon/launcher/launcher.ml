type domain = {
  frontends : Conf_parsing.frontend_config list;
  conf : (module Conf.S);
  mount_point : string;
}

(* Do NOT touch Lwt here: any Lwt_unix/Lwt_preemptive call initializes the
   shared notification eventfd, and a child inheriting it across the fork below
   would have its worker wakeups delivered to the wrong process. *)

(* One binding per (domain × frontend), grouped by frontend. Each group is its
   own process (all but the last forked), so distinct frontends on one domain
   run concurrently. *)
let bindings_by_frontend domains =
  let all =
    List.concat_map
      (fun d ->
        List.map
          (fun (f : Conf_parsing.frontend_config) ->
            ( f.Conf_parsing.frontend_type,
              {
                Frontend.conf = d.conf;
                options = f.Conf_parsing.options;
                mount_point = d.mount_point;
              } ))
          d.frontends)
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

let run ?(on_leaf = fun ~name:_ -> ()) domains =
  let run_group (name, bindings) =
    let (module F : Frontend.S) = resolve name in
    Log.debug "starting frontend %s (%d domains)" name (List.length bindings);
    (* After the fork, so each process is named for what it runs. *)
    on_leaf ~name;
    (* Sized here because only this side knows what else shares the leaf, and
       after the fork because it is the first thing to touch Lwt. *)
    let serve bs =
      Frontend.cap_blocking_pool ~concurrency:(Frontend.binding_concurrency bs);
      F.start bs
    in
    match F.topology with
      | `One_process -> serve bindings
      | `Process_per_binding ->
          Frontend.run_forked (fun b -> serve [b]) bindings
  in
  Frontend.run_forked run_group (bindings_by_frontend domains)
