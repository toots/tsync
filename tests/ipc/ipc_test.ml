open Tsync_core
open Tsync_ipc

let p fmt = Printf.printf (fmt ^^ "\n%!")
let str = Yojson.Safe.to_string
let action a = `Assoc [("action", `String a)]

let dir =
  let d = Filename.temp_dir "tsync-ipc" "" in
  Unix.chmod d 0o700;
  d

let path = Filename.concat dir "t.sock"

(* Raw lines, to show exactly what goes over the wire. *)
let raw_session ?(expect_close = false) lines =
  let fd = Unix.socket PF_UNIX SOCK_STREAM 0 in
  Unix.connect fd (ADDR_UNIX path);
  let ic = Unix.in_channel_of_descr fd and oc = Unix.out_channel_of_descr fd in
  List.iter
    (fun l ->
      output_string oc (l ^ "\n");
      flush oc;
      p "  > %s" (if String.length l > 40 then String.sub l 0 40 ^ "…" else l);
      match input_line ic with
        | r -> p "  < %s" r
        | exception End_of_file -> p "  < (closed)")
    lines;
  if expect_close then (
    match input_line ic with
      | l -> p "  unexpected %s" l
      | exception End_of_file -> p "  connection closed by the server");
  Unix.close fd

let handler server req =
  match Ipc.field req "action" with
    | Some "echo" ->
        Ipc.Reply (Ipc.ok [("arg", req |> Yojson.Safe.Util.member "arg")])
    | Some "fail" -> Fail.raise_ Fail.Unreachable "the store is down"
    | Some "subscribe" ->
        let topic = Option.value ~default:"" (Ipc.field req "domain") in
        Ipc.Subscribe
          (topic, Ipc.ok [], [`Assoc [("event", `String "recovered")]])
    | Some "publish" ->
        let topic = Option.value ~default:"" (Ipc.field req "domain") in
        let n =
          Ipc.publish (Option.get !server) topic
            (`Assoc
               [
                 ("event", `String "changed");
                 ("arg", Yojson.Safe.Util.member "arg" req);
               ])
        in
        Ipc.Reply (Ipc.ok [("delivered", `Int n)])
    | Some a ->
        Ipc.Reply
          (Ipc.failure (Fail.make Fail.Invalid ("unknown action: " ^ a)))
    | None -> Ipc.Reply (Ipc.failure (Fail.make Fail.Invalid "no action"))

let () =
  Rt.run_sync (fun () ->
      let server = ref None in
      server := Some (Ipc.serve ~path (handler server));
      p "== framing";
      raw_session
        [
          {|{"action":"echo","arg":1}|};
          "not json";
          "[1,2]";
          {|{"action":"nope"}|};
          {|{"action":"fail"}|};
          {|{"action":"echo","arg":"still here"}|};
        ];
      p "== over-long line";
      raw_session ~expect_close:true [String.make (Ipc.max_line + 10) 'x'];
      p "== client";
      p "  %s"
        (str
           (Ipc.call path
              (`Assoc [("action", `String "echo"); ("arg", `String "hi")])));
      p "== subscriptions";
      let sub topic =
        let c = Ipc.Client.connect path in
        let r =
          Ipc.Client.request c
            (`Assoc [("action", `String "subscribe"); ("domain", `String topic)])
        in
        p "  subscribe %s: %s" topic (str r);
        c
      in
      let publish topic arg =
        let r =
          Ipc.call path
            (`Assoc
               [
                 ("action", `String "publish");
                 ("domain", `String topic);
                 ("arg", `Int arg);
               ])
        in
        p "  publish %s %d: %s" topic arg (str r)
      in
      let next name c =
        match Ipc.Client.next ~timeout:2. c with
          | Some ev -> p "  %s got %s" name (str ev)
          | None -> p "  %s: end of stream" name
      in
      let a1 = sub "A" and a2 = sub "A" and b = sub "B" in
      next "a1" a1;
      next "a2" a2;
      next "b" b;
      publish "A" 1;
      publish "A" 2;
      publish "C" 3;
      next "a1" a1;
      next "a1" a1;
      next "a2" a2;
      next "a2" a2;
      publish "B" 4;
      next "b" b;
      Ipc.Client.close a2;
      Ipc.Client.close b;
      Rt.sleep 0.2;
      publish "A" 5;
      publish "B" 6;
      next "a1" a1;
      p "== no server";
      (try ignore (Ipc.call (Filename.concat dir "none.sock") (action "ping"))
       with Ipc.Not_serving _ -> p "  Not_serving");
      Ipc.advisory (Filename.concat dir "none.sock") (action "poll");
      p "  advisory to nobody returned";
      p "== a server that stopped accepting";
      let full = Filename.concat dir "full.sock" in
      let l = Unix.socket ~cloexec:true PF_UNIX SOCK_STREAM 0 in
      Unix.bind l (ADDR_UNIX full);
      Unix.listen l 1;
      let held =
        List.filter_map
          (fun _ ->
            match Ipc.Client.connect ~timeout:0.2 full with
              | c -> Some c
              | exception Fail.E _ -> None)
          (List.init 8 Fun.id)
      in
      let t0 = Rt.now () in
      let outcome =
        match Ipc.Client.connect ~timeout:0.3 full with
          | c ->
              Ipc.Client.close c;
              "connected"
          | exception Fail.E f -> Fail.kind_name f.kind
          | exception e -> Printexc.to_string e
      in
      p "  once its backlog is full: %s within 1s: %b" outcome
        (Rt.now () -. t0 < 1.);
      List.iter Ipc.Client.close held;
      Unix.close l;
      p "== close";
      let t0 = Rt.now () in
      Ipc.close (Option.get !server);
      p "  closed within 1s: %b, socket file gone: %b"
        (Rt.now () -. t0 < 1.)
        (not (Sys.file_exists path));
      next "a1" a1;
      p "== a request that closes its own server";
      let stopping = ref None in
      let stop_path = Filename.concat dir "stop.sock" in
      stopping :=
        Some
          (Ipc.serve ~path:stop_path (fun _ ->
               Rt.spawn (fun () -> Ipc.close (Option.get !stopping));
               Rt.sleep 0.2;
               Ipc.Reply (Ipc.ok [])));
      p "  answered: %s"
        (match Ipc.call stop_path (action "stop") with
          | r -> str r
          | exception e -> Printexc.to_string e);
      p "== directory checks";
      let open_dir = Filename.temp_dir "tsync-ipc" "" in
      Unix.chmod open_dir 0o755;
      (try
         ignore
           (Ipc.serve
              ~path:(Filename.concat open_dir "t.sock")
              (handler server))
       with Fail.E f -> p "  0755: %s" (Fail.code f.kind));
      try
        ignore
          (Ipc.serve
             ~path:(Filename.concat dir (String.make 120 'x'))
             (handler server))
      with Fail.E f -> p "  long path: %s" (Fail.code f.kind))
