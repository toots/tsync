(* ── Client ──────────────────────────────────────────────────────────────── *)

let send ~socket_path cmd =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_UNIX socket_path);
  let ic = Unix.in_channel_of_descr fd in
  let oc = Unix.out_channel_of_descr fd in
  output_string oc (cmd ^ "\n");
  flush oc;
  let resp = input_line ic in
  Unix.close fd;
  resp

(* Same request, for a caller that is itself an event loop: the http-proxy asks
   the mount daemon for its stats while serving, and must not block the listener
   on a daemon that has wedged. A lapsed [timeout] is reported to the caller, not
   swallowed. *)
let send_lwt ?(timeout = 2.) ~socket_path cmd =
  let open Lwt.Syntax in
  Lwt_unix.with_timeout timeout (fun () ->
      let* ic, oc = Lwt_io.open_connection (Unix.ADDR_UNIX socket_path) in
      Lwt.finalize
        (fun () ->
          let* () = Lwt_io.write_line oc cmd in
          let* () = Lwt_io.flush oc in
          Lwt_io.read_line ic)
        (fun () -> Lwt_io.close ic))

(* ── Event subscribers ─────────────────────────────────────────────────────
   The daemon never connects out. A client that wants to be told about changes
   connects here like any other caller and asks to subscribe; the connection is
   then dedicated to a stream of events. Only this direction is dependable: a
   sandboxed macOS extension can reach us, and its own lifetime is the OS's to
   decide, so a channel that exists only while it happens to be running is no
   channel at all. *)
module Subs = struct
  type sub = {
    topic : string;
    queue : string Queue.t;
    wake : unit Lwt_condition.t;
  }

  type t = { mutable subs : sub list }

  let create () = { subs = [] }

  (* ponytail: a subscriber that stops reading is trimmed rather than allowed to
     grow the output buffer without bound. Safe to lose: events are hints on top
     of the journal, which is what actually says what changed — a dropped one
     costs promptness, not correctness. Raise this, or fold the drop count into a
     resync event, if a real client is ever seen falling behind. *)
  let max_queued = 256
  let matches ~topic sub = sub.topic = "" || sub.topic = topic

  (* Number of subscribers the message was queued for. Zero means nobody is
     listening for this topic, which is the only thing a caller waiting on a
     reply can honestly be told. *)
  let publish t ~topic msg =
    let targets = List.filter (matches ~topic) t.subs in
    List.iter
      (fun sub ->
        if Queue.length sub.queue >= max_queued then begin
          ignore (Queue.take_opt sub.queue);
          Log.err "ipc: subscriber for %S is behind, dropping an event" topic
        end;
        Queue.add msg sub.queue;
        Lwt_condition.signal sub.wake ())
      targets;
    List.length targets

  let count t ~topic = List.length (List.filter (matches ~topic) t.subs)

  let register t ~topic =
    let sub =
      { topic; queue = Queue.create (); wake = Lwt_condition.create () }
    in
    t.subs <- sub :: t.subs;
    sub

  let unregister t sub = t.subs <- List.filter (fun s -> s != sub) t.subs

  (* Drain the queue, then park until something is published. Nothing yields
     between the empty check and the wait, so a publish cannot slip through the
     gap and leave us asleep on a non-empty queue. *)
  let rec write_pending sub oc =
    let open Lwt.Syntax in
    match Queue.take_opt sub.queue with
      | Some msg ->
          let* () = Lwt_io.write_line oc msg in
          let* () = Lwt_io.flush oc in
          write_pending sub oc
      | None ->
          let* () = Lwt_condition.wait sub.wake in
          write_pending sub oc

  (* Hand the connection over to the event stream. It ends when the client goes
     away, which shows up either as EOF on the read side or as a failed write. *)
  let serve t ~topic ~ic ~oc =
    let open Lwt.Syntax in
    let sub = register t ~topic in
    Lwt.finalize
      (fun () ->
        let until_eof () =
          let rec loop () =
            let* _ = Lwt_io.read_line ic in
            loop ()
          in
          Lwt.catch loop (fun _ -> Lwt.return_unit)
        in
        Lwt.catch
          (fun () -> Lwt.pick [write_pending sub oc; until_eof ()])
          (fun _ -> Lwt.return_unit))
      (fun () ->
        unregister t sub;
        Lwt.return_unit)
end

(* ── Server ──────────────────────────────────────────────────────────────── *)

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let serve ?subs ~path handler =
  let open Lwt.Syntax in
  let dir = Filename.dirname path in
  mkdir_p dir;
  (try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  let stopped, wake_stop = Lwt.wait () in
  (* Each connection is served on its own Lwt task, so a slow request (e.g. a
     large restore) never blocks other clients (e.g. status). A connection
     carries requests until the client closes it: fileproviderd asks constantly,
     and a connect and accept per question is a cost with nothing to show for
     it. [read_line] raising at EOF is how a connection ends. *)
  let handle_client (ic, oc) =
    let rec loop () =
      let* line = Lwt_io.read_line ic in
      let* resp, action = handler line in
      let* () = Lwt_io.write_line oc resp in
      let* () = Lwt_io.flush oc in
      match action with
        | `Stop ->
            if Lwt.state stopped = Lwt.Sleep then Lwt.wakeup_later wake_stop ();
            Lwt.return_unit
        | `Subscribe topic -> (
            (* The connection stops answering questions and becomes the event
               stream, so events and replies never interleave on it. *)
              match subs with
              | None -> Lwt.return_unit
              | Some subs -> Subs.serve subs ~topic ~ic ~oc)
        | `Continue -> loop ()
    in
    Lwt.catch loop (fun _ -> Lwt.return_unit)
  in
  let addr = Unix.ADDR_UNIX path in
  let* server =
    Lwt_io.establish_server_with_client_address addr (fun _addr channels ->
        handle_client channels)
  in
  let* () = stopped in
  let* () = Lwt_io.shutdown_server server in
  (try Unix.unlink path with _ -> ());
  Lwt.return_unit
