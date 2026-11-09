(* security-model §14: every TLS implementation the build carries refuses the
   same certificates, and only those. *)

open Tsync_core
open Tsync_http

let p fmt = Printf.printf (fmt ^^ "\n%!")

let serve ~certificate ~key =
  Atomic.set Transport.tls_impl (Some Openssl);
  let server =
    Server.serve
      ~tls:(Transport.server_tls ~certificate ~key)
      [Unix.ADDR_INET (Unix.inet_addr_loopback, 0)]
      (fun _ _ -> Server.text 200 "ok")
  in
  match Server.addresses server with
    | [ADDR_INET (_, port)] -> (server, port)
    | _ -> assert false

let attempt impl ~port tls =
  Atomic.set Transport.tls_impl (Some impl);
  match Transport.connect ~tls ~host:"localhost" ~port () with
    | t ->
        Transport.close t;
        "accepted"
    | exception Fail.E f -> Fail.kind_name f.kind

let () =
  Rt.run_sync (fun () ->
      let valid, valid_port =
        serve ~certificate:"tls_cert.pem" ~key:"tls_key.pem"
      in
      let expired, expired_port =
        serve ~certificate:"tls_expired_cert.pem" ~key:"tls_expired_key.pem"
      in
      let impls =
        List.sort_uniq compare (Transport.System :: Transport.available ())
      in
      List.iter
        (fun impl ->
          let check what port tls =
            p "%s, %s: %s" (Transport.impl_name impl) what
              (attempt impl ~port tls)
          in
          let anchored host ca = { Transport.host; ca_file = Some ca } in
          check "its own root" valid_port (anchored "localhost" "tls_cert.pem");
          check "another name" valid_port
            (anchored "other.example" "tls_cert.pem");
          check "an unknown root" valid_port
            (anchored "localhost" "tls_expired_cert.pem");
          check "the system store for a private root" valid_port
            { host = "localhost"; ca_file = None };
          check "an expired certificate" expired_port
            (anchored "localhost" "tls_expired_cert.pem"))
        impls;
      Server.close ~grace:0.1 valid;
      Server.close ~grace:0.1 expired)
