(* The tap the end-to-end tests watch requests through.

   Checked on its own because there it is the instrument: a tap that quietly
   recorded nothing would read as "the system never made that call", which is the
   exact conclusion those tests draw.

   What is in question is whether a bound unix socket survives being renamed. It
   does — the pathname is a lookup key, the socket lives in its inode — which is
   what lets the daemon be observed without test-only code inside it. A toy server
   stands in for it: the relay is what is under test. *)

open Check

let root = Scratch.dir "tap"
let socket_path = Filename.concat root "s.sock"

(* Echoes each request line back prefixed: enough to tell a relayed answer from a
   fabricated one. *)
let serve stop =
  let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_UNIX socket_path);
  Unix.listen listener 8;
  let handle client =
    let input = Unix.in_channel_of_descr client in
    let output = Unix.out_channel_of_descr client in
    (try
       while true do
         let line = input_line input in
         Printf.fprintf output "{\"echo\":%s}\n" line;
         flush output
       done
     with _ -> ());
    try Unix.close client with _ -> ()
  in
  let loop () =
    while not !stop do
      match Unix.select [listener] [] [] 0.2 with
        | [_], _, _ -> (
            match Unix.accept listener with
              | client, _ -> ignore (Thread.create handle client)
              | exception _ -> ())
        | _ -> ()
        | exception Unix.Unix_error _ -> stop := true
    done;
    try Unix.close listener with _ -> ()
  in
  ignore (Thread.create loop ())

(* One request, the way the real callers make one: a line, then a half-close to
   say nothing more is coming. *)
let request line =
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.connect fd (Unix.ADDR_UNIX socket_path);
  let output = Unix.out_channel_of_descr fd in
  Printf.fprintf output "%s\n" line;
  flush output;
  Unix.shutdown fd Unix.SHUTDOWN_SEND;
  let input = Unix.in_channel_of_descr fd in
  let answer = try input_line input with End_of_file -> "" in
  (try Unix.close fd with _ -> ());
  answer

let () =
  let stop = ref false in
  serve stop;
  Thread.delay 0.2;

  check "the server answers before anything is in the way"
    (request "{\"action\":\"stat\"}" = "{\"echo\":{\"action\":\"stat\"}}");

  let tap = Ipc_tap.start ~socket_path in

  (* The point of the whole arrangement: callers keep working, unaware. *)
  let answer =
    request "{\"action\":\"fetch_range\",\"offset\":8,\"length\":4}"
  in
  check "a request through the tap is answered by the real server"
    (answer
   = "{\"echo\":{\"action\":\"fetch_range\",\"offset\":8,\"length\":4}}");

  let seen = Ipc_tap.requests tap "fetch_range" in
  check "the request was recorded" (List.length seen = 1);
  check "the recorded request keeps its arguments"
    (match seen with
      | [j] ->
          Ipc_tap.field "offset" j = `Int 8 && Ipc_tap.field "length" j = `Int 4
      | _ -> false);
  check "an action nobody asked for is not recorded"
    (Ipc_tap.requests tap "ensure_cached" = []);

  (* The extension is not the only caller, and each gets its own connection. *)
  let answers =
    List.map
      (fun i ->
        Thread.create
          (fun () ->
            ignore (request (Printf.sprintf "{\"action\":\"stat\",\"n\":%d}" i)))
          ())
      [1; 2; 3; 4; 5]
  in
  List.iter Thread.join answers;
  check "concurrent requests are all recorded"
    (List.length (Ipc_tap.requests tap "stat") = 5);

  Ipc_tap.forget tap;
  check "forgetting clears what was seen" (Ipc_tap.seen tap = []);

  Ipc_tap.stop tap;
  (* The socket has to be handed back, or everything after the test — the user's
     own daemon included — is talking to nothing. *)
  check "the server is reachable again once the tap is gone"
    (request "{\"action\":\"stat\"}" = "{\"echo\":{\"action\":\"stat\"}}");

  stop := true;
  Thread.delay 0.3;
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote root)))
