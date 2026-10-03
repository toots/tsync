open Tsync_core
open Tsync_ipc
open Tsync_config
open Tsync_domain

type holder = {
  pid : int;
  role : string;
  what : string;
  socket : string option;
}

type lock = Unix.file_descr

let owner_held = 75
let housekeeping_interval = 60.

let holder_json h =
  `Assoc
    [
      ("pid", `Int h.pid);
      ("role", `String h.role);
      ("what", `String h.what);
      ("socket", match h.socket with Some s -> `String s | None -> `Null);
    ]

let holder_of_string s =
  match Yojson.Safe.from_string s with
    | `Assoc l -> (
        match (List.assoc_opt "pid" l, List.assoc_opt "role" l) with
          | Some (`Int pid), Some (`String role) ->
              let s k =
                match List.assoc_opt k l with
                  | Some (`String v) -> Some v
                  | _ -> None
              in
              Some
                {
                  pid;
                  role;
                  what = Option.value ~default:"" (s "what");
                  socket = s "socket";
                }
          | _ -> None)
    | _ -> None
    | exception _ -> None

let holder d =
  Option.bind (Fs.read_file_opt (Paths.ownership_lock d)) holder_of_string

(* 07 §2.3: flock on a close-on-exec descriptor is released only by the
   holder's exit, never by an unrelated close. *)
let acquire ?socket ~role ~what d =
  let path = Paths.ownership_lock d in
  Fs.mkdir_p ~perm:0o700 (Filename.dirname path);
  let fd = Unix.openfile path [O_RDWR; O_CREAT; O_CLOEXEC] 0o600 in
  if Fs.flock ~exclusive:true ~block:false fd then (
    let record =
      Yojson.Safe.to_string
        (holder_json { pid = Unix.getpid (); role; what; socket })
    in
    Unix.ftruncate fd 0;
    ignore (Unix.lseek fd 0 SEEK_SET);
    Fs.write_all fd record;
    Ok fd)
  else (
    Unix.close fd;
    Error (holder d))

let release fd =
  Fs.funlock fd;
  Unix.close fd

let stop_on_signals ?second () =
  let signals = [Sys.sigterm; Sys.sigint] in
  ignore (Thread.sigmask SIG_BLOCK signals);
  ignore
    (Thread.create
       (fun () ->
         while true do
           let s = Thread.wait_signal signals in
           match second with
             | Some f when Stop.requested () -> f ()
             | _ ->
                 Log.info "received %s; stopping"
                   (if s = Sys.sigterm then "SIGTERM" else "SIGINT");
                 Stop.request ()
         done)
       ())

type present =
  Tsync_domain.Domain.t ->
  (module Tsync_sync.Engine.S) ->
  publish:(Protocol.event -> unit) ->
  Handler.hooks * (unit -> unit)

type served = {
  domain : Domain.t;
  engine : (module Tsync_sync.Engine.S);
  handler : Handler.t;
  go : unit -> unit;
}

let answered_while_draining = ["stats"; "status"; "stop"]

(* A socket serving several domains routes by [domain]; one serving a single
   domain may be asked without it. *)
let route ~draining ~router served req =
  let action = Option.value ~default:"" (Ipc.field req "action") in
  if Atomic.get draining && not (List.mem action answered_while_draining) then
    Ipc.Reply (Ipc.failure (Fail.make Fail.Unexplained "stopping"))
  else (
    (* 08 §3.3: a shared socket's router answers its own actions when no domain
       is named, and declines the rest. *)
    let own =
      match (Ipc.field req "domain", router) with
        | None, Some answer -> answer action req
        | _ -> None
    in
    match (own, Ipc.field req "domain", served) with
      | Some reply, _, _ -> reply
      | None, None, [s] -> Handler.answer s.handler req
      | None, None, _ ->
          Ipc.Reply
            (Ipc.failure
               (Fail.make Fail.Invalid "domain is required on this socket"))
      | None, Some d, _ -> (
          match
            List.find_opt
              (fun s -> Domain_name.to_string s.domain.name = d)
              served
          with
            | Some s -> Handler.answer s.handler req
            | None ->
                Ipc.Reply
                  (Ipc.failure
                     (Fail.make Fail.Unreachable (d ^ " is not served here")))))

(* 07 §5.5: a domain's body, and this process's description of itself with
   the traffic of every domain it serves. *)
let stats_reply reports report : Tsync_status.Status_report.answer =
  {
    domains = [Answered (Report.domain_body report)];
    presented = [];
    self =
      Tsync_status.Self_report.self
        ~traffic:(Report.traffic (List.map snd reports))
        ~role:"owner" ~serves:(List.map fst reports) ();
  }

(* 04 §4.11: the daily tasks run on the first pass after a day went by. *)
let housekeeping (domain : Domain.t) (module E : Tsync_sync.Engine.S) =
  let daily = ref (Unix.gettimeofday ()) in
  let rearmed = ref (Unix.gettimeofday ()) in
  let pass () =
    E.poll ();
    E.trim_cache ();
    if Unix.gettimeofday () -. !rearmed >= Dqueue.rearm_interval then (
      rearmed := Unix.gettimeofday ();
      let n = E.rearm () in
      if n > 0 then Log.info "retrying %d parked records" n);
    if Unix.gettimeofday () -. !daily >= 86400. then (
      daily := Unix.gettimeofday ();
      let n =
        Tsync_sync.Export.sweep_records ~cache_root:domain.cache_root
          domain.name
      in
      if n > 0 then Log.info "removed %d stale export records" n;
      let n = E.prune_applied () in
      if n > 0 then Log.info "pruned %d applied-log shards" n);
    Usage.release_if_grown ()
  in
  try
    while true do
      Stop.sleep housekeeping_interval;
      try pass () with
        | Stop.Stopping -> raise Stop.Stopping
        | e -> Log.warn "housekeeping: %s" (Printexc.to_string e)
    done
  with Stop.Stopping -> ()

(* The router of a shared socket (file-provider §4.2, §8.1, §10). *)
let all_topics = "*"

let shared_router served reports action req =
  let now () = Unix.gettimeofday () in
  match action with
    | "subscribe" ->
        Some
          (Ipc.Subscribe
             ( all_topics,
               Ipc.ok [],
               List.map (fun s -> Handler.event_json s.handler Recovered) served
             ))
    | "menu" ->
        let answers =
          List.map
            (fun s ->
              ( Domain_name.to_string s.domain.Domain.name,
                match Handler.call s.handler Status with
                  | st -> Ok st
                  | exception e -> Error (Fail.classify e).reason ))
            served
        in
        Some (Ipc.Reply (Ipc.ok [("menu", Menu.render answers)]))
    | "menu_stats" ->
        let machine : Tsync_status.Status_report.machine =
          {
            host = Unix.gethostname ();
            domains =
              Tsync_status.Status_report.answered
                (List.map
                   (fun (name, report) ->
                     (name, Ok (stats_reply reports report)))
                   reports);
            processes = [];
            uplinks = [];
            jobs = [];
            warnings = [];
          }
        in
        Some
          (Ipc.Reply
             (Ipc.ok
                [
                  ( "entries",
                    `List
                      (Menu.stats_entries
                         (Tsync_status.Status_text.render ~now:(now ()) machine))
                  );
                ]))
    | "stop" ->
        Stop.request ();
        Some (Ipc.Reply (Ipc.ok []))
    | "pause" ->
        let on = Ipc.field req "arg" <> Some "off" in
        (* Pitfall B-10.9: every domain first, then the fold. *)
        let answers =
          List.map (fun s -> Handler.call s.handler (Pause on)) served
        in
        let paused = List.for_all Fun.id answers in
        Some (Ipc.Reply (Ipc.ok [("paused", `Bool paused)]))
    | _ -> None

let serve ?present ?(shared = false) ?roots ~socket config domains =
  let draining = Atomic.make false in
  let server = ref None in
  let served = ref [] in
  let publish d ev =
    match !server with
      | Some srv ->
          Ipc.publish srv d ev
          + if shared then Ipc.publish srv all_topics ev else 0
      | None -> 0
  in
  (* security-model §7.3: the host declares its roots; the user's home unless
     it says otherwise. *)
  let roots = Option.value ~default:[Paths.home ()] roots in
  let reports = ref [] in
  served :=
    List.map
      (fun (dom : Config.domain) ->
        let domain = Domain.build ~owner:true config dom in
        let engine = Domain.engine domain in
        let (module E : Tsync_sync.Engine.S) = engine in
        E.start ();
        Rt.spawn ~name:"housekeeping" (fun () -> housekeeping domain engine);
        let handler = ref None in
        let hooks, go =
          match present with
            | Some p ->
                p domain engine ~publish:(fun ev ->
                    Option.iter
                      (fun h -> ignore (Handler.publish_event h ev))
                      !handler)
            | None -> (Handler.no_hooks, ignore)
        in
        E.set_changed_hook hooks.changed;
        let report = Report.create domain engine ~frontend:hooks.frontend in
        reports := (Domain_name.to_string dom.name, report) :: !reports;
        let name = Domain_name.to_string dom.name in
        let subscribers () =
          match !server with
            | Some srv ->
                Ipc.subscribers srv name
                + if shared then Ipc.subscribers srv all_topics else 0
            | None -> 0
        in
        let h =
          Handler.create ~subscribers
            ~traffic:(fun () -> Report.traffic [report])
            ~domain ~engine ~hooks ~publish:(publish name)
            ~stats:(fun _ -> stats_reply !reports report)
            ~stop:Stop.request ~dest_roots:roots ~staging_roots:roots ()
        in
        handler := Some h;
        { domain; engine; go; handler = h })
      domains;
  let router =
    if shared then Some (fun a r -> shared_router !served !reports a r)
    else None
  in
  server := Some (Ipc.serve ~path:socket (route ~draining ~router !served));
  List.iter
    (fun s -> ignore (Handler.publish_event s.handler Recovered))
    !served;
  List.iter (fun s -> s.go ()) !served;
  Stop.wait ();
  Atomic.set draining true;
  Rt.iter_concurrently
    (fun s ->
      let (module E : Tsync_sync.Engine.S) = s.engine in
      E.drain ())
    !served;
  Option.iter Ipc.close !server

let run ?present ?shared ?roots ?socket config (domains : Config.domain list) =
  let socket =
    match (socket, domains) with
      | Some s, _ -> s
      | None, d :: _ -> Paths.owner_socket d.name
      | None, [] -> invalid_arg "Owner.run: no domain and no socket"
  in
  let rec take = function
    | [] -> Ok ()
    | (d : Config.domain) :: rest -> (
        match acquire ~socket ~role:"daemon" ~what:"tsync start" d.name with
          | Ok _ -> take rest
          | Error h ->
              Log.info "%s is owned by %s; exiting"
                (Domain_name.to_string d.name)
                (match h with
                  | Some h -> Printf.sprintf "%s (pid %d)" h.what h.pid
                  | None -> "another process");
              Error ())
  in
  match take domains with
    | Error () -> owner_held
    | Ok () ->
        serve ?present ?shared ?roots ~socket config domains;
        0

(* 07 §2.5, §3.5: an owner for the command's duration, with every duty but
   journal polling, drained before the lock is released. *)
let with_ownership ~what config (dom : Config.domain) f =
  match acquire ~role:"command" ~what dom.name with
    | Error h ->
        Fail.raise_ Fail.Load "%s is owned by %s, which is not serving"
          (Domain_name.to_string dom.name)
          (match h with
            | Some h -> Printf.sprintf "%s (pid %d)" h.what h.pid
            | None -> "another process")
    | Ok lock ->
        Fun.protect
          ~finally:(fun () -> release lock)
          (fun () ->
            let domain = Domain.build ~owner:true config dom in
            let engine = Domain.engine domain in
            let (module E : Tsync_sync.Engine.S) = engine in
            E.start ~poll_journal:false ();
            Fun.protect
              ~finally:(fun () -> E.drain ())
              (fun () -> f domain engine))

let one_shot ~what config dom f =
  with_ownership ~what config dom (fun domain engine ->
      let home = Paths.home () in
      let report = Report.create domain engine ~frontend:(fun () -> None) in
      let handler =
        Handler.create ~domain ~engine ~hooks:Handler.no_hooks
          ~publish:(fun _ -> 0)
          ~stats:(fun _ ->
            stats_reply [(Domain_name.to_string domain.name, report)] report)
          ~stop:ignore ~dest_roots:[home] ~staging_roots:[home] ()
      in
      f handler)

let alive pid =
  match Unix.kill pid 0 with
    | () -> true
    | exception Unix.Unix_error (Unix.EPERM, _, _) -> true
    | exception Unix.Unix_error _ -> false

let served name =
  match holder name with
    | Some { socket = Some _; pid; _ } -> alive pid
    | _ -> false

(* 07 §2.5: a refused connection is not an absent owner, since a full backlog
   gives the same error on macOS. *)
let retry_refused names call =
  let deadline = Rt.now () +. Ipc.request_deadline in
  let rec attempt () =
    match call () with
      | reply -> reply
      | exception Ipc.Not_serving _
        when Rt.now () < deadline && List.exists served names ->
          Rt.sleep 0.1;
          attempt ()
  in
  attempt ()

let ask ?(bulk = false) ?on_line (dom : Config.domain) req =
  retry_refused [dom.name] (fun () ->
      Protocol.call ~bulk ?on_line
        ~domain:(Domain_name.to_string dom.name)
        (Paths.owner_socket dom.name)
        req)

(* Past the retry, the one-shot's lock acquisition decides: it takes ownership
   if the lock is free and refuses busy if not. *)
let request ?bulk ?on_line ~what config (dom : Config.domain) req =
  match ask ?bulk ?on_line dom req with
    | reply -> reply
    | exception Ipc.Not_serving _ ->
        one_shot ~what config dom (fun h -> Handler.call h req)

type host =
  mount:string option ->
  Tsync_config.Config.domain list ->
  run:(present -> int) ->
  int

let hosts : host Registry.t = Registry.create ()
let register_host = Registry.register hosts

let host_for (domains : Config.domain list) =
  List.find_map
    (fun (d : Config.domain) ->
      List.find_map
        (fun (f : Config.frontend) -> Registry.find hosts f.ftype)
        d.frontends)
    domains
