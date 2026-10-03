open Tsync_core
open Tsync_http

let p fmt = Printf.printf (fmt ^^ "\n%!")

let handler (r : Server.request) read_body =
  match r.path with
    | "/echo" ->
        let body = Bigstring.to_string (read_body ~limit:16) in
        Server.text 200 (Printf.sprintf "%s %s %S" r.meth r.query body)
    | "/peer" -> Server.text 200 r.peer
    | "/host" ->
        Server.text 200
          (Option.value ~default:"" (Codec.header r.headers "host"))
    | "/stream" ->
        {
          status = 200;
          headers = [];
          body =
            Stream
              (fun w ->
                List.iter
                  (fun s -> w (Bigstring.of_string s))
                  ["one "; ""; "two "; "three"]);
        }
    | "/slow" ->
        Rt.sleep 1.5;
        Server.text 200 "late"
    | "/close" ->
        { (Server.text 200 "bye") with headers = [("connection", "close")] }
    | _ -> Server.text 404 "not found"

let show (r : Client.response) =
  p "  %d %S%s" r.status
    (Bigstring.to_string r.body)
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
      show
        (Client.request e ~meth:"PUT"
           ~body:(Bigstring.of_string "hello")
           "/echo");
      show
        (Client.request e ~meth:"PUT"
           ~body:(Bigstring.of_string (String.make 17 'x'))
           "/echo");
      show (Client.request e ~meth:"HEAD" "/echo");
      show (Client.request e ~meth:"GET" "/stream");
      show (Client.request e ~meth:"GET" "/nothing");
      p "http date: %s, parsed back: %b, garbage: %b" (Codec.http_date 1e9)
        (Codec.parse_http_date (Codec.http_date 1e9) = Some 1e9)
        (Codec.parse_http_date "garbage" = None);
      p "host header carries the port: %b"
        (Bigstring.to_string (Client.request e ~meth:"GET" "/host").body
        |> String.trim
        = Printf.sprintf "127.0.0.1:%d" port);
      p "== keep-alive";
      let a = Client.request e ~meth:"GET" "/peer" in
      let b = Client.request e ~meth:"GET" "/peer" in
      p "  same connection: %b" (Bigstring.equal a.body b.body);
      ignore (Client.request e ~meth:"GET" "/close");
      let c = Client.request e ~meth:"GET" "/peer" in
      p "  new connection after close: %b" (not (Bigstring.equal c.body b.body));
      p "== stall";
      (match Client.request ~stall:0.5 e ~meth:"GET" "/slow" with
        | r -> show r
        | exception Fail.E f ->
            p "  %s: %s" (Fail.kind_name f.kind)
              (String.concat "" (List.tl (String.split_on_char ':' f.reason))));
      show (Client.request ~stall:3. e ~meth:"GET" "/slow");
      p "== a body still being accepted is progress";
      let l = Unix.socket PF_INET SOCK_STREAM 0 in
      Unix.bind l (ADDR_INET (Unix.inet_addr_loopback, 0));
      Unix.listen l 1;
      let sink_port =
        match Unix.getsockname l with
          | ADDR_INET (_, port) -> port
          | _ -> assert false
      in
      let size = 16 * 1024 * 1024 in
      let sink =
        Rt.async (fun () ->
            Rt.wait_readable l;
            let fd, _ = Unix.accept l in
            Unix.setsockopt_int fd SO_RCVBUF 65536;
            let t = Transport.of_fd fd in
            let buf = Bigstring.create 262144 in
            let first = Transport.read t buf 0 262144 in
            let head =
              let s =
                Bigstring.to_string (Bigstring.sub buf ~off:0 ~len:first)
              in
              let rec find i =
                if String.sub s i 4 = "\r\n\r\n" then i + 4 else find (i + 1)
              in
              find 0
            in
            let rec slowly total =
              if total < head + size then (
                Rt.sleep 0.02;
                slowly
                  (total
                  + Transport.read t buf 0 (min 262144 (head + size - total))))
            in
            slowly first;
            Transport.write_string t
              "HTTP/1.1 200 OK\r\n\
               content-length: 2\r\n\
               connection: close\r\n\
               \r\n\
               ok";
            Transport.close t)
      in
      (match
         Client.request ~stall:1.
           (Client.endpoint (Printf.sprintf "http://127.0.0.1:%d" sink_port))
           ~meth:"PUT"
           ~body:(Bigstring.of_string (String.make size 'x'))
           "/sink"
       with
        | r -> show r
        | exception Fail.E f ->
            p "  %s: %s" (Fail.kind_name f.kind)
              (String.concat "" (List.tl (String.split_on_char ':' f.reason))));
      (try Rt.with_timeout 5. (fun () -> Rt.Promise.await sink) with _ -> ());
      Unix.close l;
      p "== a client trickling its head";
      let strict =
        Server.serve
          ~limits:{ Server.default_limits with header_timeout = 0.5 }
          [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)]
          handler
      in
      let strict_port =
        match Server.addresses strict with
          | [ADDR_INET (_, p)] -> p
          | _ -> assert false
      in
      let slow = Transport.connect ~host:"127.0.0.1" ~port:strict_port () in
      let t0 = Rt.now () in
      let rec trickle i =
        if i >= 15 then false
        else (
          match
            Transport.write_string slow
              (String.make 1 "GET / HTTP/1.1".[i mod 14]);
            Transport.read ~timeout:0.2 slow (Bigstring.create 1) 0 1
          with
            | 0 -> true
            | _ -> true
            | exception Rt.Timeout -> trickle (i + 1)
            | exception _ -> true)
      in
      p "  dropped within 1.5s: %b" (trickle 0 && Rt.now () -. t0 < 1.5);
      Transport.close slow;
      Server.close ~grace:0.1 strict;
      p "== a cancelled connect closes its socket";
      let l = Unix.socket PF_INET SOCK_STREAM 0 in
      Unix.bind l (ADDR_INET (Unix.inet_addr_loopback, 0));
      Unix.listen l 0;
      let full_port =
        match Unix.getsockname l with
          | ADDR_INET (_, port) -> port
          | _ -> assert false
      in
      let fds () = Array.length (Sys.readdir "/dev/fd") in
      let attempt () =
        try
          Rt.with_timeout 0.1 (fun () ->
              Transport.close
                (Transport.connect ~host:"127.0.0.1" ~port:full_port ()))
        with _ -> ()
      in
      (* The first attempts fill the backlog; the later ones stay pending. *)
      for _ = 1 to 4 do
        attempt ()
      done;
      let before = fds () in
      for _ = 1 to 10 do
        attempt ()
      done;
      p "  ten cancelled connects leave fewer than 5 descriptors: %b"
        (fds () - before < 5);
      Unix.close l;
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

(* backends/http-proxy §2: a listener terminates TLS itself; every pairing of
   the two implementations interoperates, and an unknown CA is refused. *)
let () =
  Rt.run_sync (fun () ->
      p "== TLS listener";
      let listen impl =
        Atomic.set Transport.tls_impl (Some impl);
        let tls =
          Transport.server_tls ~certificate:"tls_cert.pem" ~key:"tls_key.pem"
        in
        let server =
          Server.serve ~tls
            [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)]
            handler
        in
        match Server.addresses server with
          | [ADDR_INET (_, port)] -> (server, port)
          | _ -> assert false
      in
      let name = function
        | Transport.Openssl -> "openssl"
        | Native -> "ocaml-tls"
      in
      let servers =
        List.map (fun impl -> (impl, listen impl)) [Transport.Openssl; Native]
      in
      List.iter
        (fun (server_impl, (_, port)) ->
          List.iter
            (fun client_impl ->
              Atomic.set Transport.tls_impl (Some client_impl);
              let url = Printf.sprintf "https://localhost:%d" port in
              let e = Client.endpoint ~ca_file:"tls_cert.pem" url in
              let r = Client.request e ~meth:"GET" "/echo?tls=1" in
              p "  %s server, %s client: %d" (name server_impl)
                (name client_impl) r.status;
              match
                Client.request (Client.endpoint url) ~meth:"GET" "/echo"
              with
                | r -> p "    without the CA: %d" r.status
                | exception Fail.E f ->
                    p "    without the CA: %s" (Fail.kind_name f.kind))
            [Transport.Openssl; Native])
        servers;
      List.iter (fun (_, (s, _)) -> Server.close ~grace:0.1 s) servers)

(* The failure modes of a TLS socket layer: plaintext buffered inside the TLS
   engine while the descriptor stays quiet, and handshakes nobody completes. *)
let () =
  Rt.run_sync (fun () ->
      p "== TLS edge cases";
      let listen () =
        let l = Unix.socket PF_INET SOCK_STREAM 0 in
        Unix.setsockopt l SO_REUSEADDR true;
        Unix.bind l (ADDR_INET (Unix.inet_addr_loopback, 0));
        Unix.listen l 4;
        match Unix.getsockname l with
          | ADDR_INET (_, port) -> (l, port)
          | _ -> assert false
      in
      let accept l =
        Rt.wait_readable l;
        Transport.of_fd (fst (Unix.accept l))
      in
      let tls =
        { Transport.host = "localhost"; ca_file = Some "tls_cert.pem" }
      in
      List.iter
        (fun (name, impl) ->
          Atomic.set Transport.tls_impl (Some impl);
          let server =
            Transport.server_tls ~certificate:"tls_cert.pem" ~key:"tls_key.pem"
          in
          let l, port = listen () in
          let got =
            Rt.async (fun () ->
                let conn = Transport.accept_tls ~timeout:5. server (accept l) in
                let buf = Bigstring.create 100 in
                let rec go n =
                  if n >= 3000 then n
                  else go (n + Transport.read ~timeout:2. conn buf 0 100)
                in
                let n = go 0 in
                Transport.close conn;
                n)
          in
          let c = Transport.connect ~tls ~host:"localhost" ~port () in
          Transport.write c (Bigstring.of_string (String.make 3000 'x'));
          p "  %s: one 3000-byte record read 100 bytes at a time: %s" name
            (match Rt.Promise.await got with
              | n -> Printf.sprintf "%d bytes" n
              | exception e -> Printexc.to_string e);
          Transport.close c;
          Unix.close l)
        [("openssl", Transport.Openssl); ("ocaml-tls", Native)];
      Atomic.set Transport.tls_impl (Some Openssl);
      let tls_server =
        Transport.server_tls ~certificate:"tls_cert.pem" ~key:"tls_key.pem"
      in
      let server =
        Server.serve
          ~limits:{ Server.default_limits with header_timeout = 0.3 }
          ~tls:tls_server
          [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)]
          handler
      in
      let port =
        match Server.addresses server with
          | [ADDR_INET (_, p)] -> p
          | _ -> assert false
      in
      let silent = Transport.connect ~host:"127.0.0.1" ~port () in
      p "  a client that never speaks TLS is dropped: %s"
        (match Transport.read ~timeout:3. silent (Bigstring.create 16) 0 16 with
          | 0 -> "end of stream"
          | n -> Printf.sprintf "%d bytes" n
          | exception e -> Printexc.to_string e);
      Transport.close silent;
      Server.close ~grace:0.1 server;
      let l, port = listen () in
      let held = Rt.async (fun () -> accept l) in
      p "  a server that never speaks TLS fails the client: %s"
        (match
           Transport.connect ~handshake_timeout:0.3 ~tls ~host:"localhost" ~port
             ()
         with
          | _ -> "connected"
          | exception Fail.E f -> Fail.kind_name f.kind ^ ": " ^ f.reason);
      Transport.close (Rt.Promise.await held);
      Unix.close l)
