(* The event channel, over a real socket.

   Two things are easy to get wrong and invisible until a client is left waiting:
   a connection must keep answering questions until the client hangs up
   (fileproviderd asks constantly), and a subscribed connection must stop
   answering and carry events instead. Exercised end to end rather than by
   inspecting [Subs]. *)

open Lwt.Syntax

let root = Filename.temp_dir "tsync-subs" ""
let socket_path = Filename.concat root "tsync.sock"
let failures = ref 0

let check name ok =
  if ok then Printf.printf "%s: ok\n%!" name
  else begin
    incr failures;
    Printf.printf "%s: FAILED\n%!" name
  end

(* Answers "ping" and takes "subscribe <topic>" as the handover. *)
let handler line =
  match String.split_on_char ' ' (String.trim line) with
    | ["ping"] -> Lwt.return ("pong", `Continue)
    | ["subscribe"; topic] -> Lwt.return ("subscribed", `Subscribe topic)
    | ["stop"] -> Lwt.return ("stopping", `Stop)
    | _ -> Lwt.return ("what", `Continue)

let connect () = Lwt_io.open_connection (Unix.ADDR_UNIX socket_path)

let ask (ic, oc) msg =
  let* () = Lwt_io.write_line oc msg in
  let* () = Lwt_io.flush oc in
  Lwt_io.read_line ic

(* A published event has to travel over the socket first and nothing here says
   when it has. Wait for the line, but not forever: a bug here is a client that
   hangs, so the test must not hang too. *)
let read_within ic seconds =
  Lwt.pick
    [
      (let+ line = Lwt_io.read_line ic in
       Some line);
      (let* () = Lwt_unix.sleep seconds in
       Lwt.return_none);
    ]

let main () =
  let subs = Ipc.Subs.create () in
  Lwt.async (fun () -> Ipc.serve ~subs ~path:socket_path handler);
  let* () = Lwt_unix.sleep 0.2 in

  check "no subscribers yet" (Ipc.Subs.publish subs ~topic:"a" "early" = 0);

  (* Several requests on one connection: the old server closed after the first. *)
  let* client = connect () in
  let* first = ask client "ping" in
  let* second = ask client "ping" in
  check "connection serves more than one request"
    (first = "pong" && second = "pong");

  let* sub_a = connect () in
  let ic_a, _ = sub_a in
  let* ack = ask sub_a "subscribe a" in
  check "subscribe is acknowledged" (ack = "subscribed");
  check "subscriber is counted" (Ipc.Subs.count subs ~topic:"a" = 1);
  check "other topics are unaffected" (Ipc.Subs.count subs ~topic:"b" = 0);

  check "publish reports the delivery"
    (Ipc.Subs.publish subs ~topic:"a" "hello" = 1);
  let* got = read_within ic_a 2. in
  check "event reaches the subscriber" (got = Some "hello");

  check "a different topic is not delivered"
    (Ipc.Subs.publish subs ~topic:"b" "not for a" = 0);

  (* Queued before anyone could be waiting on them, and in order. *)
  ignore (Ipc.Subs.publish subs ~topic:"a" "one");
  ignore (Ipc.Subs.publish subs ~topic:"a" "two");
  let* one = read_within ic_a 2. in
  let* two = read_within ic_a 2. in
  check "events arrive in order" (one = Some "one" && two = Some "two");

  (* A subscriber that goes away must be forgotten, or the daemon reports
     deliveries to nobody and [evict] lies about having been carried out. *)
  let* () = Lwt_io.close ic_a in
  let* () = Lwt_unix.sleep 0.3 in
  check "a departed subscriber is dropped" (Ipc.Subs.count subs ~topic:"a" = 0);
  check "publishing to nobody reports zero"
    (Ipc.Subs.publish subs ~topic:"a" "gone" = 0);

  let* () = Lwt_io.close (fst client) in
  Lwt.return_unit

let () =
  Lwt_main.run (main ());
  (try Unix.unlink socket_path with _ -> ());
  try Unix.rmdir root with _ -> ()
