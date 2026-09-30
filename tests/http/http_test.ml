open Tsync_core
open Tsync_http

let p fmt = Printf.printf (fmt ^^ "\n%!")

let handler (r : Server.request) read_body =
  match r.path with
    | "/echo" ->
        let body = read_body ~limit:16 in
        Server.text 200 (Printf.sprintf "%s %s %S" r.meth r.query body)
    | "/peer" -> Server.text 200 r.peer
    | "/stream" ->
        {
          status = 200;
          headers = [];
          body = Stream (fun w -> List.iter w ["one "; ""; "two "; "three"]);
        }
    | "/slow" ->
        Rt.sleep 1.5;
        Server.text 200 "late"
    | "/close" ->
        { (Server.text 200 "bye") with headers = [("connection", "close")] }
    | _ -> Server.text 404 "not found"

let show (r : Client.response) =
  p "  %d %S%s" r.status r.body
    (match Codec.header r.headers "transfer-encoding" with
      | Some te -> " (" ^ te ^ ")"
      | None -> "")

let () =
  Rt.run_sync (fun () ->
      let server =
        Server.serve [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)] handler
      in
      let port =
        match Server.addresses server with
          | [ADDR_INET (_, p)] -> p
          | _ -> assert false
      in
      let e = Client.endpoint (Printf.sprintf "http://127.0.0.1:%d" port) in
      p "== requests";
      show (Client.request e ~meth:"GET" "/echo?a=1");
      show (Client.request e ~meth:"PUT" ~body:"hello" "/echo");
      show (Client.request e ~meth:"PUT" ~body:(String.make 17 'x') "/echo");
      show (Client.request e ~meth:"HEAD" "/echo");
      show (Client.request e ~meth:"GET" "/stream");
      show (Client.request e ~meth:"GET" "/nothing");
      p "== keep-alive";
      let a = Client.request e ~meth:"GET" "/peer" in
      let b = Client.request e ~meth:"GET" "/peer" in
      p "  same connection: %b" (a.body = b.body);
      ignore (Client.request e ~meth:"GET" "/close");
      let c = Client.request e ~meth:"GET" "/peer" in
      p "  new connection after close: %b" (c.body <> b.body);
      p "== stall";
      (match Client.request ~stall:0.5 e ~meth:"GET" "/slow" with
        | r -> show r
        | exception Fail.E f ->
            p "  %s: %s" (Fail.kind_name f.kind)
              (String.concat "" (List.tl (String.split_on_char ':' f.reason))));
      show (Client.request ~stall:3. e ~meth:"GET" "/slow");
      p "== redial after the server dropped an idle connection";
      Server.close ~grace:0.1 server;
      let server =
        Server.serve [Unix.ADDR_INET (Unix.inet_addr_loopback, port)] handler
      in
      show (Client.request e ~meth:"GET" "/echo?after=restart");
      Server.close server;
      p "== nothing listening";
      match Client.request e ~meth:"GET" "/echo" with
        | r -> show r
        | exception Fail.E f -> p "  %s" (Fail.kind_name f.kind))
