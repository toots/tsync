open Tsync_core
open Tsync_store
open Tsync_http
module P = Tsync_http_proxy.Store_server

let p = Contract.p
let secret = String.make 40 's'
let d = Domain_name.v "d"
let ro_secret = String.make 40 'r'

let () =
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "tsync-proxy-%d" (Unix.getpid ()))
  in
  Fs.rm_rf root;
  Rt.run_sync (fun () ->
      let local name = Local.create ~name (Filename.concat root name) in
      let route ?(read_only = false) ?(secret = secret) name domain store =
        {
          P.name;
          domain = Domain_name.v domain;
          secret;
          read_only;
          chunk_size = Some 4096;
          store;
          share = None;
        }
      in
      (* A backend that answers "later" until told otherwise. *)
      let throttling = Atomic.make false in
      let throttled =
        let inner = local "throttled" in
        {
          inner with
          get_opt =
            (fun k ->
              if Atomic.get throttling then
                Fail.raise_ Fail.Load "the backend throttles";
              inner.get_opt k);
        }
      in
      let proxy =
        P.create ~max_concurrent:4
          [
            route "d" "d" (local "d");
            route "throttled" "throttled" throttled;
            route "ro" "ro" ~read_only:true ~secret:ro_secret (local "ro");
          ]
      in
      let server =
        Server.serve
          [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)]
          (P.handle proxy)
      in
      let url =
        match Server.addresses server with
          | [ADDR_INET (_, port)] -> Printf.sprintf "http://127.0.0.1:%d" port
          | _ -> assert false
      in
      let client ?(secret = secret) domain =
        (Option.get (Driver.find "http-proxy")).create ~admission:Uplink.none
          ~domain:(Domain_name.v domain) ~name:("proxy-" ^ domain)
          [("url", Field_spec.S url); ("secret", Field_spec.S secret)]
      in
      let s = client "d" in
      Contract.run s;
      p "\n== http-proxy (backends/http-proxy §12)\n";
      let kind f = Contract.kind_of f in
      let ro = client ~secret:ro_secret "ro" in
      p "read-only put: %s\n"
        (kind (fun () -> Contract.put ro (Key.v "tsync/ro/x") "x"));
      p "read-only get of an absent key: %s\n"
        (Contract.show (Contract.get ro (Key.v "tsync/ro/x")));
      let wrong = client ~secret:(String.make 40 'w') "d" in
      p "wrong secret: %s\n"
        (kind (fun () -> Contract.get wrong (Key.v "tsync/d/a")));
      let unserved = client "other" in
      p "unserved domain get_opt: %s\n"
        (kind (fun () -> Contract.get unserved (Key.v "tsync/other/a")));
      p "unserved domain head: %s\n"
        (kind (fun () -> unserved.head_opt (Key.v "tsync/other/a")));
      p "a key of another route: %s\n"
        (kind (fun () -> Contract.get s (Key.v "tsync/ro/x")));
      let caps = s.capabilities (Key.domain_prefix d) in
      p "capabilities: chunk %s, concurrency %s, verified %b\n"
        (Option.fold ~none:"none" ~some:string_of_int caps.chunk_size)
        (Option.fold ~none:"none" ~some:string_of_int caps.max_concurrency)
        caps.verified;
      p "get_many across pages: %d answers\n"
        (List.length
           (Option.get s.get_many
              (List.init 2500 (fun i ->
                   Key.v (Printf.sprintf "tsync/d/many/%d" i)))));
      Contract.put s
        (Key.v "tsync/d/manifests/x/f")
        {|{"dir":true,"name":"f","id":"0123456789ab-1"}|};
      p "list_many: %d folders\n"
        (List.length
           (Option.get s.list_many [Key.prefix "tsync/d/manifests/x/"]));
      let staged = Key.v "tsync/shares/cache/x" in
      Contract.put s staged {|{"domain":"ro","dir":"root"}|};
      p "copy into a share manifest: %s\n"
        (kind (fun () -> s.copy staged (Key.v "tsync/shares/abcd")));
      p "copy out of a share manifest: %s\n"
        (kind (fun () ->
             s.copy (Key.v "tsync/shares/abcd") (Key.v "tsync/shares/cache/y")));
      p "copy within the share cache: %s\n"
        (kind (fun () -> s.copy staged (Key.v "tsync/shares/cache/z")));
      p "== a backend that throttles for two seconds\n";
      let slow = client "throttled" in
      Contract.put slow (Key.v "tsync/throttled/a") "a";
      Atomic.set throttling true;
      Rt.spawn ~name:"throttling ends" (fun () ->
          Rt.sleep 2.;
          Atomic.set throttling false);
      let trips = Atomic.make 0 in
      let unwatch = Health.on_trip slow.health (fun () -> Atomic.incr trips) in
      let read = kind (fun () -> slow.get_opt (Key.v "tsync/throttled/a")) in
      unwatch ();
      p "a read through it: %s; the peer's breaker tripped: %b\n" read
        (Atomic.get trips > 0);
      p "== unsigned bodies dripping do not hold the data slots\n";
      let port =
        match Server.addresses server with
          | [ADDR_INET (_, port)] -> port
          | _ -> assert false
      in
      let drips =
        List.init 12 (fun i ->
            let c = Transport.connect ~host:"127.0.0.1" ~port () in
            Transport.write_string c
              (Printf.sprintf
                 "PUT /o/%s HTTP/1.1\r\n\
                  host: x\r\n\
                  x-tsync-timestamp: %d\r\n\
                  x-tsync-signature: %s\r\n\
                  content-length: 1000\r\n\
                  \r\n\
                  x"
                 (Tsync_http_proxy_client.Proxy_wire.encode_key
                    (Key.v (Printf.sprintf "tsync/d/drip%d" i)))
                 (int_of_float (Unix.gettimeofday ()))
                 (String.make 64 '0'));
            c)
      in
      Rt.sleep 0.2;
      let t0 = Rt.now () in
      let read = kind (fun () -> s.get_opt (Key.v "tsync/d/a")) in
      p "a signed read meanwhile: %s within 2s: %b\n" read (Rt.now () -. t0 < 2.);
      List.iter Transport.close drips;
      p "== a 401 from a skewed clock is not remembered\n";
      let skewed = ref true and conditional_puts = ref 0 in
      let l = Unix.socket PF_INET SOCK_STREAM 0 in
      Unix.bind l (ADDR_INET (Unix.inet_addr_loopback, 0));
      Unix.listen l 4;
      let fake_url =
        match Unix.getsockname l with
          | ADDR_INET (_, port) -> Printf.sprintf "http://127.0.0.1:%d" port
          | _ -> assert false
      in
      (* A raw responder: the server would add a Date of its own first. *)
      Rt.spawn (fun () ->
          let rec serve () =
            Rt.wait_readable l;
            let fd, _ = Unix.accept l in
            let t = Transport.of_fd fd in
            let buf = Bigstring.create 4096 in
            let head =
              Bigstring.to_string
                (Bigstring.sub buf ~off:0 ~len:(Transport.read t buf 0 4096))
            in
            let status, date, body =
              if !skewed then
                ("401 Unauthorized", Unix.gettimeofday () -. 3600., "stale")
              else if String.starts_with ~prefix:"GET /list" head then
                ("200 OK", Unix.gettimeofday (), "[]")
              else if String.starts_with ~prefix:"GET /checksum" head then
                (* a server from before the endpoint *)
                ("404 Not Found", Unix.gettimeofday (), "not found")
              else if
                String.starts_with ~prefix:"PUT" head
                && (Text.contains head "if_match"
                   || Text.contains head "if_none_match")
              then (
                incr conditional_puts;
                ("200 OK", Unix.gettimeofday (), ""))
              else ("404 Not Found", Unix.gettimeofday (), "")
            in
            Transport.write_string t
              (Printf.sprintf
                 "HTTP/1.1 %s\r\n\
                  date: %s\r\n\
                  content-length: %d\r\n\
                  connection: close\r\n\
                  \r\n\
                  %s"
                 status (Codec.http_date date) (String.length body) body);
            Transport.close t;
            serve ()
          in
          try serve () with _ -> ());
      let behind =
        (Option.get (Driver.find "http-proxy")).create ~admission:Uplink.none
          ~domain:d ~name:"skewed"
          [("url", Field_spec.S fake_url); ("secret", Field_spec.S secret)]
      in
      p "while skewed: %s\n"
        (kind (fun () -> behind.get_opt (Key.v "tsync/d/a")));
      skewed := false;
      p "once the clocks agree: %s\n"
        (kind (fun () -> behind.get_opt (Key.v "tsync/d/a")));
      p "== a server without /checksum\n";
      p "conditional replace: %s, conditional PUTs sent: %d\n"
        (kind (fun () ->
             behind.put_if_unchanged (Key.v "tsync/d/a")
               (Bigstring.of_string "x") None))
        !conditional_puts;
      p "checksum falls back to a read: %s\n"
        (match behind.compute_checksum (Key.v "tsync/d/a") Checksum.md5 with
          | Some _ -> "some"
          | None -> "none");
      Unix.close l;
      p "== watch\n";
      let cursor = Key.cursor d in
      Contract.put s cursor "one";
      let t0 = Rt.now () in
      s.watch cursor None;
      p "behind: returned at once %b\n" (Rt.now () -. t0 < 1.);
      let waiter =
        Rt.async (fun () ->
            let t0 = Rt.now () in
            s.watch cursor (Some "one");
            Rt.now () -. t0)
      in
      Rt.sleep 0.5;
      Contract.put s cursor "two";
      let took = Rt.Promise.await waiter in
      p "a change wakes the watch: %b\n" (took < 5.);
      let held =
        Rt.async (fun () -> try s.watch cursor (Some "two") with _ -> ())
      in
      Rt.sleep 0.5;
      let t0 = Rt.now () in
      Stop.request ();
      Server.close server;
      p "a stop answers a held watch, closing in under 2s: %b\n"
        (Rt.now () -. t0 < 2.);
      ignore (Rt.Promise.peek held))
