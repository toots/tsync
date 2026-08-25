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

let request ~socket_path fields =
  let body = Yojson.Safe.to_string (`Assoc fields) in
  match Yojson.Safe.from_string (send ~socket_path body) with
    | `Assoc obj when List.assoc_opt "ok" obj = Some (`Bool true) -> obj
    | `Assoc obj ->
        let msg =
          match List.assoc_opt "error" obj with
            | Some (`String s) -> s
            | _ -> "unexpected response"
        in
        failwith msg
    | _ -> failwith "unexpected response"

let action ~socket_path ?item ?arg ?domain action =
  request ~socket_path
    ([("action", `String action)]
    @ (match item with
      | Some r -> [("ref", `String (Item_ref.to_string r))]
      | None -> [])
    @ (match domain with Some d -> [("domain", `String d)] | None -> [])
    @ match arg with Some a -> [("arg", `String a)] | None -> [])

module Subs = struct
  type sub = {
    topic : string;
    queue : string Queue.t;
    wake : unit Lwt_condition.t;
  }

  type t = { mutable subs : sub list }

  let create () = { subs = [] }

  (* ponytail: a subscriber that stops reading is trimmed rather than allowed to
     grow the output buffer without bound; events are hints on top of the
     journal, so a dropped one costs promptness, not correctness. Raise it if a
     real client is ever seen falling behind. *)
  let max_queued = 256
  let matches ~topic sub = sub.topic = "" || sub.topic = topic

  (* Zero means nobody is listening for this topic, which is all a caller waiting
     on a reply can honestly be told. *)
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

  (* Nothing yields between the empty check and the wait, so a publish cannot slip
     through and leave us asleep on a non-empty queue. *)
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

  (* Ends when the client goes away: EOF on the read side, or a failed write. *)
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
  (* One Lwt task per connection, so a slow request (a large restore) never
     blocks another client. A connection carries requests until the client
     closes it: fileproviderd asks constantly, and a connect and accept per
     question buys nothing. *)
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
            (* The connection becomes the event stream, so events and replies
               never interleave. *)
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
