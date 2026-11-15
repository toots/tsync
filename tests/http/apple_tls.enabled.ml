(* The "system" rows must come from Network.framework, not from OpenSSL
   standing in for it. *)
let check () =
  if
    not
      (List.mem Tsync_http.Transport.System (Tsync_http.Transport.available ()))
  then failwith "tls_trust_test: Network.framework did not register"
