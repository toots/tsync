open Tsync_core
module Transport = Tsync_http.Transport

let ssl_initialised = Atomic.make false

let ssl_context ca_file =
  if not (Atomic.exchange ssl_initialised true) then Ssl.init ();
  let ctx = Ssl.create_context Ssl.TLSv1_2 Ssl.Client_context in
  Ssl.set_min_protocol_version ctx Ssl.TLSv1_2;
  (match ca_file with
    | Some f -> Ssl.load_verify_locations ctx f ""
    | None ->
        if not (Ssl.set_default_verify_paths ctx) then
          Fail.raise_ Fail.Local "OpenSSL has no system trust store");
  Ssl.set_verify ctx [Ssl.Verify_peer] None;
  ctx

(* One context per trust store, shared by every connection. *)
let ssl_contexts = Mutex.create ()

let ssl_context_cache : (string option, Ssl.context) Hashtbl.t =
  Hashtbl.create 2

let ssl_context ca_file =
  Mutex.protect ssl_contexts (fun () ->
      match Hashtbl.find_opt ssl_context_cache ca_file with
        | Some c -> c
        | None ->
            let c = ssl_context ca_file in
            Hashtbl.replace ssl_context_cache ca_file c;
            c)

(* A non-blocking OpenSSL call answers "want read" or "want write" until the
   socket is ready; the wait and the retry are non-blocking I/O (01 §6.5). *)
let rec ssl_retry ?timeout fd f =
  match f () with
    | v -> v
    | exception
        ( Ssl.Read_error Error_want_read
        | Ssl.Write_error Error_want_read
        | Ssl.Connection_error Error_want_read
        | Ssl.Accept_error Error_want_read ) ->
        Rt.within `Immediate (fun () ->
            Rt.wait_readable ?timeout fd;
            ssl_retry ?timeout fd f)
    | exception
        ( Ssl.Read_error Error_want_write
        | Ssl.Write_error Error_want_write
        | Ssl.Connection_error Error_want_write
        | Ssl.Accept_error Error_want_write ) ->
        Rt.within `Immediate (fun () ->
            Rt.wait_writable ?timeout fd;
            ssl_retry ?timeout fd f)

(* Pitfall A-11.6: a failure of the session is a broken connection, which the
   callers of a transport know as a socket error, not as OpenSSL's own. *)
let broken what = raise (Unix.Unix_error (Unix.ECONNRESET, "tls " ^ what, ""))

let of_ssl fd s =
  let read ?timeout buf off len =
    try
      ssl_retry ?timeout fd (fun () -> Ssl.read_into_bigarray s buf off len)
    with
      | Ssl.Read_error (Error_zero_return | Error_syscall) -> 0
      | Ssl.Read_error _ -> broken "read"
  in
  let write ?timeout b =
    let rec go off =
      if off < Bigstring.length b then
        go
          (off
          + ssl_retry ?timeout fd (fun () ->
              Ssl.write_bigarray s b off (Bigstring.length b - off)))
    in
    try go 0 with Ssl.Write_error _ -> broken "write"
  in
  Transport.make ~fd ~read ~write ~close:(fun () ->
      (try ignore (Ssl.close_notify s) with _ -> ());
      try Unix.close fd with _ -> ())

let openssl fd ({ host; ca_file } : Transport.tls) =
  let s = Ssl.embed_socket fd (ssl_context ca_file) in
  Ssl.set_client_SNI_hostname s host;
  Ssl.set_host s host;
  (try ssl_retry fd (fun () -> Ssl.connect s)
   with Ssl.Connection_error _ ->
     let v = Ssl.get_verify_result s in
     if v <> 0 then Transport.untrusted host (Ssl.get_verify_error_string v)
     else Transport.tls_failure host "handshake failed");
  of_ssl fd s

let () =
  Transport.register Openssl
    {
      client = openssl;
      server =
        (fun ~certificate ~key ->
          if not (Atomic.exchange ssl_initialised true) then Ssl.init ();
          let ctx = Ssl.create_context Ssl.TLSv1_2 Ssl.Server_context in
          Ssl.set_min_protocol_version ctx Ssl.TLSv1_2;
          (match Ssl.use_certificate ctx certificate key with
            | () -> ()
            | exception e ->
                Fail.raise_ Fail.Invalid "TLS certificate %s or key %s: %s"
                  certificate key (Printexc.to_string e));
          fun fd ->
            let s = Ssl.embed_socket fd ctx in
            (try ssl_retry fd (fun () -> Ssl.accept s)
             with Ssl.Accept_error _ ->
               Transport.tls_failure "client" "handshake failed");
            of_ssl fd s);
    }
