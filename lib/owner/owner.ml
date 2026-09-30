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

let stop_on_signals () =
  let signals = [Sys.sigterm; Sys.sigint] in
  ignore (Thread.sigmask SIG_BLOCK signals);
  ignore
    (Thread.create
       (fun () ->
         while true do
           let s = Thread.wait_signal signals in
           Log.info "received %s; stopping"
             (if s = Sys.sigterm then "SIGTERM" else "SIGINT");
           Stop.request ()
         done)
       ())

type present =
  Tsync_domain.Domain.t -> (module Tsync_sync.Engine.S) -> Handler.hooks

type served = {
  domain : Domain.t;
  engine : (module Tsync_sync.Engine.S);
  handler : Handler.t;
}

let answered_while_draining = ["stats"; "status"; "stop"; "ping"]

(* A socket serving several domains routes by [domain]; one serving a single
   domain may be asked without it. *)
let route ~draining served req =
  let action = Option.value ~default:"" (Ipc.field req "action") in
  if action = "ping" then Ipc.Reply (Ipc.ok [])
  else if Atomic.get draining && not (List.mem action answered_while_draining)
  then Ipc.Reply (Ipc.failure (Fail.make Fail.Unexplained "stopping"))
  else (
    match (Ipc.field req "domain", served) with
      | None, [s] -> Handler.answer s.handler req
      | None, _ ->
          Ipc.Reply
            (Ipc.failure
               (Fail.make Fail.Invalid "domain is required on this socket"))
      | Some d, _ -> (
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

(* ponytail: a minimal domain body; the full report of 07 §5.5 lives with the
   status collector. *)
let domain_body (domain : Domain.t) (module E : Tsync_sync.Engine.S) =
  let sync =
    match E.bridge () with
      | Incremental -> [("state", `String "incremental")]
      | Hold reason -> [("state", `String "hold"); ("reason", `String reason)]
  in
  `Assoc
    [
      ("name", `String (Domain_name.to_string domain.name));
      ("paused", `Bool (E.is_paused ()));
      ( "sync",
        `Assoc
          (sync
          @ [
              ("unappliedEntries", `Int (List.length (E.unapplied ())));
              ("parkedMetadata", `Int (List.length (E.parked ())));
            ]) );
      ( "queues",
        `Assoc
          [
            ("pendingFiles", `Int (E.pending_uploads ()));
            ("pendingMetadata", `Int (E.pending_metadata ()));
          ] );
    ]

let housekeeping (module E : Tsync_sync.Engine.S) =
  try
    while true do
      Stop.sleep housekeeping_interval;
      E.poll ()
    done
  with Stop.Stopping -> ()

let serve ?present ~socket config domains =
  let draining = Atomic.make false in
  let server = ref None in
  let served = ref [] in
  let publish d ev =
    match !server with Some srv -> Ipc.publish srv d ev | None -> 0
  in
  let home = Paths.home () in
  served :=
    List.map
      (fun (dom : Config.domain) ->
        let domain = Domain.build ~owner:true config dom in
        let engine = Domain.engine domain in
        let (module E : Tsync_sync.Engine.S) = engine in
        E.start ();
        Rt.spawn ~name:"housekeeping" (fun () -> housekeeping engine);
        {
          domain;
          engine;
          handler =
            Handler.create ~domain ~engine ~hooks:Handler.no_hooks
              ~publish:(publish (Domain_name.to_string dom.name))
              ~stats:(fun _ ->
                Ipc.ok [("domains", `List [domain_body domain engine])])
              ~stop:Stop.request ~dest_roots:[home] ~staging_roots:[home];
        })
      domains;
  server := Some (Ipc.serve ~path:socket (route ~draining !served));
  List.iter
    (fun s ->
      ignore
        (publish
           (Domain_name.to_string s.domain.name)
           (Handler.event s.handler "recovered" [])))
    !served;
  Option.iter
    (fun present ->
      List.iter (fun s -> ignore (present s.domain s.engine)) !served)
    present;
  Stop.wait ();
  Atomic.set draining true;
  Rt.iter_concurrently
    (fun s ->
      let (module E : Tsync_sync.Engine.S) = s.engine in
      E.drain ())
    !served;
  Option.iter Ipc.close !server

let run ?present ?socket config (domains : Config.domain list) =
  let socket =
    match (socket, domains) with
      | Some s, _ -> s
      | None, [d] -> Paths.owner_socket d.name
      | None, _ -> Paths.owner_socket (List.hd domains).name
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
        serve ?present ~socket config domains;
        0

(* 07 §2.5, §3.5: an owner for the command's duration, with every duty but
   journal polling, drained before the lock is released. *)
let one_shot ~what config (dom : Config.domain) f =
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
            let home = Paths.home () in
            let handler =
              Handler.create ~domain ~engine ~hooks:Handler.no_hooks
                ~publish:(fun _ -> 0)
                ~stats:(fun _ ->
                  Ipc.ok [("domains", `List [domain_body domain engine])])
                ~stop:ignore ~dest_roots:[home] ~staging_roots:[home]
            in
            Fun.protect ~finally:(fun () -> E.drain ()) (fun () -> f handler))

let request ?(bulk = false) ~what config (dom : Config.domain) req =
  let req =
    match req with
      | `Assoc l ->
          `Assoc (("domain", `String (Domain_name.to_string dom.name)) :: l)
      | j -> j
  in
  let socket = Paths.owner_socket dom.name in
  match if bulk then Ipc.call_bulk socket req else Ipc.call socket req with
    | reply -> reply
    | exception Ipc.Not_serving _ ->
        one_shot ~what config dom (fun h ->
            match Handler.answer h req with
              | Ipc.Reply r -> r
              | Ipc.Subscribe _ -> Fail.invalid "a subscription needs an owner")
