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

(* The same socket for a caller that has a loop to keep turning. *)
module type TRANSPORT = sig
  type 'a io
  type input
  type output
  type server

  val connect : string -> (input * output) io
  val read_line : input -> string io
  val write_line : output -> string -> unit io
  val flush : output -> unit io
  val close : input -> unit io
  val serve : path:string -> (input * output -> unit io) -> server io
  val shutdown : server -> unit io
end

module Make
    (Io : Io.S)
    (Lock : Lock.S with type 'a io := 'a Io.t)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (T : TRANSPORT with type 'a io := 'a Io.t) =
struct
  open Io_syntax.Make (Io)

  let send ?(timeout = 2.) ~socket_path cmd =
    Clock.with_timeout timeout (fun () ->
        let* ic, oc = T.connect socket_path in
        Io.finalize
          (fun () ->
            let* () = T.write_line oc cmd in
            let* () = T.flush oc in
            T.read_line ic)
          (fun () -> T.close ic))

  module Subs = struct
    type sub = { topic : string; queue : string Queue.t; wake : Lock.condition }
    type t = { mutable subs : sub list }

    let create () = { subs = [] }

    (* ponytail: a subscriber that stops reading is trimmed rather than allowed
       to grow the output buffer without bound; events are hints on top of the
       journal, so a dropped one costs promptness, not correctness. Raise it if
       a real client is ever seen falling behind. *)
    let max_queued = 256
    let matches ~topic sub = sub.topic = "" || sub.topic = topic

    (* Zero means nobody is listening for this topic, which is all a caller
       waiting on a reply can honestly be told. *)
    let publish t ~topic msg =
      let targets = List.filter (matches ~topic) t.subs in
      List.iter
        (fun sub ->
          if Queue.length sub.queue >= max_queued then begin
            ignore (Queue.take_opt sub.queue);
            Log.err "ipc: subscriber for %S is behind, dropping an event" topic
          end;
          Queue.add msg sub.queue;
          Lock.signal sub.wake)
        targets;
      List.length targets

    let count t ~topic = List.length (List.filter (matches ~topic) t.subs)

    let register t ~topic =
      let sub = { topic; queue = Queue.create (); wake = Lock.condition () } in
      t.subs <- sub :: t.subs;
      sub

    let unregister t sub = t.subs <- List.filter (fun s -> s != sub) t.subs

    (* Nothing yields between the empty check and the wait, so a publish cannot
       slip through and leave us asleep on a non-empty queue.

       [gone] is what ends this side: it has nothing to read, so it would
       otherwise wait on the condition for a client that has already left. *)
    let rec write_pending sub ~gone oc =
      match Queue.take_opt sub.queue with
        | Some msg ->
            let* () = T.write_line oc msg in
            let* () = T.flush oc in
            write_pending sub ~gone oc
        | None ->
            let* () = Lock.wait sub.wake in
            if !gone then Io.return () else write_pending sub ~gone oc

    (* Ends when the client goes away: EOF on the read side, or a failed write.
       Both halves end of their own accord — the read side says so and wakes the
       write side — rather than one being cancelled out from under the other. *)
    let serve t ~topic ~ic ~oc =
      let sub = register t ~topic in
      let gone = ref false in
      let give_up () =
        gone := true;
        Lock.signal sub.wake;
        Io.return ()
      in
      Io.finalize
        (fun () ->
          let until_eof () =
            let rec loop () =
              let* _ = T.read_line ic in
              loop ()
            in
            Io.finalize
              (fun () -> Io.catch loop (fun _ -> Io.return ()))
              give_up
          in
          Io.catch
            (fun () ->
              Io.join
                [
                  Io.catch
                    (fun () -> write_pending sub ~gone oc)
                    (fun _ -> give_up ());
                  until_eof ();
                ])
            (fun _ -> Io.return ()))
        (fun () ->
          unregister t sub;
          Io.return ())
  end

  let serve ?subs ~path handler =
    let dir = Filename.dirname path in
    Fs.mkdir_p_sync ~perm:0o700 dir;
    (try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
    let stopped, wake_stop = Io.wait () in
    (* Waking twice raises, and two clients can each ask the daemon to stop. *)
    let woken = ref false in
    (* One task per connection, so a slow request (a large restore) never blocks
       another client. A connection carries requests until the client closes it:
       fileproviderd asks constantly, and a connect and accept per question buys
       nothing. *)
    let handle_client (ic, oc) =
      let rec loop () =
        let* line = T.read_line ic in
        let* resp, action = handler line in
        let* () = T.write_line oc resp in
        let* () = T.flush oc in
        match action with
          | `Stop ->
              if not !woken then begin
                woken := true;
                Io.wakeup_later wake_stop ()
              end;
              Io.return ()
          | `Subscribe topic -> (
              (* The connection becomes the event stream, so events and replies
                 never interleave. *)
                match subs with
                | None -> Io.return ()
                | Some subs -> Subs.serve subs ~topic ~ic ~oc)
          | `Continue -> loop ()
      in
      Io.catch loop (fun _ -> Io.return ())
    in
    let* server = T.serve ~path handle_client in
    let* () = stopped in
    let* () = T.shutdown server in
    (try Unix.unlink path with _ -> ());
    Io.return ()
end
