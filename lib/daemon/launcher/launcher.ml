type domain = (string * Frontend.binding) list

(* Only {!recover} touches Lwt here, and only through an [Lwt_main.run] that
   returns before the first fork. The hazard is a child inheriting the
   notification eventfd and having its worker wakeups delivered to the parent;
   [Lwt_unix.fork] reinitialises the notification system in the child, which is
   why {!Frontend.run_forked} uses it.

   Nothing else here may touch Lwt: what runs after the forks belongs to a leaf,
   which starts its own loop. *)

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

(* Where one frontend answers, if it answers at all. [None] for one driven by
   commands rather than by requests. *)
let socket_of (name, b) =
  let (module F : Frontend.S) = resolve name in
  match F.listens with
    | None -> None
    | Some `Domain_socket ->
        let module C = (val b.Frontend.conf : Conf.S) in
        Some C.socket_path
    | Some `Proxy_socket ->
        Some (Runtime.proxy_socket_path (Runtime.default_paths ()))

(* Each of a domain's frontends and where it answers, deduplicated by socket:
   frontends sharing a path answer the same one and collapse. The name travels
   with it so a silent socket can be reported as the frontend that went quiet
   rather than as an address. *)
let frontends_of domain =
  List.fold_left
    (fun acc (name, b) ->
      match socket_of (name, b) with
        | None -> acc
        | Some socket ->
            if List.exists (fun (_, s) -> s = socket) acc then acc
            else acc @ [(name, socket)])
    [] domain

(* Where a domain's frontends answer, so what the poller applied can reach
   them. *)
let frontend_sockets domain = List.map snd (frontends_of domain)

(* The same list minus the named frontend's own, which is what a frontend
   reporting on the whole domain needs and cannot work out for itself: it holds
   one binding, so it would have to assume its siblings rather than be told. *)
let peers_of domain name =
  let mine =
    List.filter_map
      (fun (n, b) -> if n = name then socket_of (n, b) else None)
      domain
  in
  List.filter (fun s -> not (List.mem s mine)) (frontend_sockets domain)

(* One binding per (domain × frontend), grouped by frontend. Each group is its
   own process, so distinct frontends on one domain run concurrently.

   Each binding carries where its domain's other frontends answer: that needs the
   whole matrix, which is here and nowhere below. *)
let bindings_by_frontend domains =
  let all =
    List.concat_map
      (fun d -> List.map (fun (name, b) -> (name, (b, peers_of d name))) d)
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
        List.filter_map (fun (n, x) -> if n = name then Some x else None) all ))
    order

type engine = {
  name : string;
  frontends : (string * string) list;
      (** each frontend of this domain and the socket it answers on *)
  converging : (module Domain_engine.Converging);
  diagnose :
    totals:bool -> exact:bool -> reload:bool -> unit -> Yojson.Safe.t Lwt.t;
}

(* The machine's `tsync status', assembled here because this is the process that
   can.

   The domain -- its cache, the records owed, its backends -- belongs to whoever
   converges it, which is this process; a frontend asked for it would redo those
   probes for an answer this one already has. What a frontend knows and nobody
   else does is its own -- its mount, its handles, its queues -- and that is what
   [frontend_only] asks each of them for.

   Only a collector fans out. A frontend asked for its figures answers about
   itself and asks nobody, or this would cost frontends x frontends round trips.

   Both fan-outs are as wide as the config, not as the data, and every leaf is
   under its own deadline -- {!Status_report.ask}'s for a socket, the probe
   timeout for a store -- so neither needs a pool. *)
let report ~totals ~exact ~reload engines =
  let open Lwt.Syntax in
  let* domains =
    Lwt_list.map_p (fun e -> e.diagnose ~totals ~exact ~reload ()) engines
  in
  let+ answers =
    Lwt_list.map_p
      (fun (domain, (frontend, socket_path)) ->
        Status_report.ask ~arg:Status_report.frontend_only ~frontend ~domain
          ~socket_path ())
      (List.concat_map
         (fun e -> List.map (fun f -> (e.name, f)) e.frontends)
         engines)
  in
  Status_report.of_answers
    ~local:
      (Diagnostics.self_json
         ~extra:
           [
             ("frontend", `String "sync");
             ("serves", `List (List.map (fun e -> `String e.name) engines));
           ]
         ())
    ~domains answers

(* Answered in the same vocabulary the mount daemon's socket uses, so a client
   can match on the code rather than on the wording. *)
let handler ~request_stop engines line =
  let open Lwt.Syntax in
  let fail code msg =
    Lwt.return (Ipc_handler.error_reply code msg, `Continue)
  in
  match Yojson.Safe.from_string line with
    | exception _ -> fail `Invalid "invalid JSON"
    | `Assoc obj -> (
        let arg =
          match List.assoc_opt "arg" obj with Some (`String s) -> s | _ -> ""
        in
        let asked name = List.mem name (String.split_on_char ',' arg) in
        match List.assoc_opt "action" obj with
          | Some (`String "stats") ->
              let exact = asked "exact" in
              let totals = exact || asked "totals" in
              let reload = totals && asked "reload" in
              let* r = report ~totals ~exact ~reload engines in
              let fields = match r with `Assoc f -> f | _ -> [] in
              Lwt.return
                ( Yojson.Safe.to_string (`Assoc (("ok", `Bool true) :: fields)),
                  `Continue )
          | Some (`String "stop") ->
              (* Answered before winding down, so the caller hears that it was
                 asked rather than losing the connection. *)
              request_stop ();
              Lwt.return
                (Yojson.Safe.to_string (`Assoc [("ok", `Bool true)]), `Stop)
          | Some (`String a) -> fail `Invalid ("unknown action: " ^ a)
          | _ -> fail `Invalid "unknown action: ")
    | _ -> fail `Internal "expected JSON object"

(* The domains' background work, in the process that forked the frontends rather
   than in one of them.

   It is the domain's work, not a frontend's: it writes the mirror, the
   applied-through bookmark and the staged tree, which every process serving the
   domain shares and none of them arbitrate. Giving it to one of the frontends
   made that one silently different from its peers, and picked which by config
   order. Here nobody is picked, because there is nobody to pick. *)
let converge domains =
  let engines =
    List.filter_map
      (function
        | [] -> None
        | (_, b) :: _ as d ->
            let module C = (val b.Frontend.conf : Conf.S) in
            let module E = Domain_engine.Make (C) in
            let module Cv = Domain_engine.Converge (E) in
            let module Diag = Diagnostics.Make (C) in
            Some
              {
                name = C.domain_name;
                frontends = frontends_of d;
                converging = (module Cv : Domain_engine.Converging);
                diagnose =
                  (fun ~totals ~exact ~reload () ->
                    Diag.domain_json ~totals ~exact ~reload ());
              })
      domains
  in
  Domain_engine.run (fun ~ready ->
      let open Lwt.Syntax in
      let stop, wake = Lwt.wait () in
      let request_stop () =
        match Lwt.state stop with
          | Lwt.Sleep -> Lwt.wakeup_later wake ()
          | _ -> ()
      in
      List.iter
        (fun s -> ignore (Lwt_unix.on_signal s (fun _ -> request_stop ())))
        [Sys.sigterm; Sys.sigint];
      let* () =
        Lwt_list.iter_s
          (fun e ->
            let module Cv = (val e.converging : Domain_engine.Converging) in
            Cv.start
              ~on_changed:
                (Change_notice.send ~domain:e.name
                   ~sockets:(List.map snd e.frontends))
              ())
          engines
      in
      let socket_path = Runtime.sync_socket_path (Runtime.default_paths ()) in
      Log.debug "converging %d domain(s), answering at %s" (List.length engines)
        socket_path;
      Lwt.async (fun () ->
          Ipc.serve ~path:socket_path (handler ~request_stop engines));
      ready ();
      let* () = stop in
      Log.info "stopping, letting the domains catch up";
      (try Unix.unlink socket_path with _ -> ());
      Lwt_list.iter_s
        (fun e ->
          let module Cv = (val e.converging : Domain_engine.Converging) in
          Cv.drain ())
        engines)

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
           (fun (binding, peers) ->
             let module C = (val binding.Frontend.conf : Conf.S) in
             let module E = Domain_engine.Make (C) in
             {
               Frontend.binding;
               domain = (module E : Domain_engine.Domain);
               peers;
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
  let reap = Frontend.fork_each run_group groups in
  Fun.protect ~finally:reap (fun () -> converge domains)
