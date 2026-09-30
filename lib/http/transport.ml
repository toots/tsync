module Host_name = Domain_name
open Tsync_core

type tls_impl = Openssl | Native

let tls_impl = Atomic.make Openssl

let tls_impl_of_string = function
  | "openssl" -> Some Openssl
  | "native" | "ocaml-tls" -> Some Native
  | _ -> None

type tls = { host : string; ca_file : string option }

type t = {
  fd : Unix.file_descr;
  read : ?timeout:float -> Bigstring.t -> int -> int -> int;
  write : ?timeout:float -> Bigstring.t -> unit;
  close : unit -> unit;
}

let retry_io = function
  | Unix.Unix_error ((EAGAIN | EWOULDBLOCK | EINTR), _, _) -> true
  | _ -> false

let plain fd =
  let rec read ?timeout buf off len =
    match Unix.read_bigarray fd buf off len with
      | n -> n
      | exception e when retry_io e ->
          Rt.wait_readable ?timeout fd;
          read ?timeout buf off len
  in
  let write ?timeout b =
    let rec go off =
      if off < Bigstring.length b then (
        match
          Unix.single_write_bigarray fd b off (Bigstring.length b - off)
        with
          | n -> go (off + n)
          | exception e when retry_io e ->
              Rt.wait_writable ?timeout fd;
              go off)
    in
    go 0
  in
  { fd; read; write; close = (fun () -> try Unix.close fd with _ -> ()) }

let of_fd fd =
  Unix.set_nonblock fd;
  plain fd

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

let tls_failure host what = Fail.raise_ Fail.Link "TLS with %s: %s" host what

(* A certificate that does not verify will not verify on a retry either. *)
let untrusted host what = Fail.raise_ Fail.Refused "TLS with %s: %s" host what

(* A non-blocking OpenSSL call answers "want read" or "want write" until the
   socket is ready. *)
let rec ssl_retry ?timeout fd f =
  match f () with
    | v -> v
    | exception
        ( Ssl.Read_error Error_want_read
        | Ssl.Write_error Error_want_read
        | Ssl.Connection_error Error_want_read ) ->
        Rt.wait_readable ?timeout fd;
        ssl_retry ?timeout fd f
    | exception
        ( Ssl.Read_error Error_want_write
        | Ssl.Write_error Error_want_write
        | Ssl.Connection_error Error_want_write ) ->
        Rt.wait_writable ?timeout fd;
        ssl_retry ?timeout fd f

let openssl fd { host; ca_file } =
  let s = Ssl.embed_socket fd (ssl_context ca_file) in
  Ssl.set_client_SNI_hostname s host;
  Ssl.set_host s host;
  (try ssl_retry fd (fun () -> Ssl.connect s)
   with Ssl.Connection_error _ ->
     let v = Ssl.get_verify_result s in
     if v <> 0 then untrusted host (Ssl.get_verify_error_string v)
     else tls_failure host "handshake failed");
  let read ?timeout buf off len =
    try ssl_retry ?timeout fd (fun () -> Ssl.read_into_bigarray s buf off len)
    with Ssl.Read_error (Error_zero_return | Error_syscall) -> 0
  in
  let write ?timeout b =
    let rec go off =
      if off < Bigstring.length b then
        go
          (off
          + ssl_retry ?timeout fd (fun () ->
              Ssl.write_bigarray s b off (Bigstring.length b - off)))
    in
    go 0
  in
  {
    fd;
    read;
    write;
    close =
      (fun () ->
        (try ignore (Ssl.close_notify s) with _ -> ());
        try Unix.close fd with _ -> ());
  }

let rng_initialised = Atomic.make false

let authenticator ca_file =
  match ca_file with
    | None -> (
        match Ca_certs.authenticator () with
          | Ok a -> a
          | Error (`Msg m) ->
              Fail.raise_ Fail.Local "no system trust store: %s" m)
    | Some f -> (
        let pem = Fs.read_file f in
        match X509.Certificate.decode_pem_multiple pem with
          | Ok cas ->
              X509.Authenticator.chain_of_trust
                ~time:(fun () -> Some (Ptime_clock.now ()))
                cas
          | Error (`Msg m) -> Fail.raise_ Fail.Invalid "%s: %s" f m)

(* The OCaml TLS engine is a state machine over records: bytes read from the
   socket go in, application data and records to send come out. *)
let native fd { host; ca_file } =
  if not (Atomic.exchange rng_initialised true) then
    Mirage_crypto_rng_unix.use_default ();
  let peer_name =
    match Host_name.of_string host with
      | Ok d -> (
          match Host_name.host d with Ok h -> Some h | Error _ -> None)
      | Error _ -> None
  in
  let config =
    match
      Tls.Config.client ~authenticator:(authenticator ca_file) ?peer_name ()
    with
      | Ok c -> c
      | Error (`Msg m) -> tls_failure host m
  in
  let raw = plain fd in
  let state, hello = Tls.Engine.client config in
  let state = ref state in
  (* The engine speaks strings: what it hands back is copied once into the
     caller's buffer. *)
  let pending = ref "" and pending_pos = ref 0 in
  let eof = ref false in
  let chunk = Bigstring.create 16384 in
  let send ?timeout s = raw.write ?timeout (Bigstring.of_string s) in
  send hello;
  let pump ?timeout () =
    let n = raw.read ?timeout chunk 0 (Bigstring.length chunk) in
    if n = 0 then eof := true
    else (
      match Tls.Engine.handle_tls !state (Bigstring.to_string ~len:n chunk) with
        | Ok (s, e, `Response resp, `Data data) ->
            state := s;
            Option.iter send resp;
            Option.iter
              (fun d ->
                pending :=
                  String.sub !pending !pending_pos
                    (String.length !pending - !pending_pos)
                  ^ d;
                pending_pos := 0)
              data;
            if e <> None then eof := true
        | Error (failure, `Response resp) -> (
            (try send resp with _ -> ());
            match failure with
              | `Error (`AuthenticationFailure e) ->
                  untrusted host
                    (Format.asprintf "%a" X509.Validation.pp_validation_error e
                    |> String.split_on_char '\n' |> List.rev |> List.hd
                    |> String.trim)
              | f -> tls_failure host (Tls.Engine.string_of_failure f)))
  in
  while Tls.Engine.handshake_in_progress !state && not !eof do
    pump ()
  done;
  if !eof then tls_failure host "the connection closed during the handshake";
  let available () = String.length !pending - !pending_pos in
  let read ?timeout buf off len =
    while available () = 0 && not !eof do
      pump ?timeout ()
    done;
    let n = min len (available ()) in
    Bigstring.blit_from_bytes
      (Bytes.unsafe_of_string !pending)
      !pending_pos buf off n;
    pending_pos := !pending_pos + n;
    n
  in
  let write ?timeout b =
    match Tls.Engine.send_application_data !state [Bigstring.to_string b] with
      | Some (st, out) ->
          state := st;
          send ?timeout out
      | None -> tls_failure host "the session is not ready"
  in
  {
    fd;
    read;
    write;
    close =
      (fun () ->
        (try
           let st, out = Tls.Engine.send_close_notify !state in
           state := st;
           send ~timeout:1. out
         with _ -> ());
        raw.close ());
  }

(* An unroutable address family must not hold the next address back. *)
let connect_timeout = 10.

let connect_fd ~host ~port =
  let addrs =
    Unix.getaddrinfo host (string_of_int port) [AI_SOCKTYPE SOCK_STREAM]
  in
  if addrs = [] then Fail.raise_ Fail.Link "%s: no address" host;
  let rec try_ last = function
    | [] -> (
        match last with
          | Some e -> raise e
          | None -> Fail.raise_ Fail.Link "%s: no address" host)
    | (a : Unix.addr_info) :: rest -> (
        let fd = Unix.socket ~cloexec:true a.ai_family a.ai_socktype 0 in
        Unix.set_nonblock fd;
        match Unix.connect fd a.ai_addr with
          | () -> fd
          | exception Unix.Unix_error (EINPROGRESS, _, _) -> (
              match Rt.wait_writable ~timeout:connect_timeout fd with
                | exception Rt.Timeout ->
                    Unix.close fd;
                    try_
                      (Some (Unix.Unix_error (ETIMEDOUT, "connect", host)))
                      rest
                | () -> (
                    match Unix.getsockopt_error fd with
                      | None -> fd
                      | Some e ->
                          Unix.close fd;
                          try_
                            (Some (Unix.Unix_error (e, "connect", host)))
                            rest))
          | exception e ->
              Unix.close fd;
              try_ (Some e) rest)
  in
  let fd = try_ None addrs in
  (try Unix.setsockopt fd TCP_NODELAY true with Unix.Unix_error _ -> ());
  fd

let connect ?tls ~host ~port () =
  let fd = connect_fd ~host ~port in
  match tls with
    | None -> plain fd
    | Some tls -> (
        try
          match Atomic.get tls_impl with
            | Openssl -> openssl fd tls
            | Native -> native fd tls
        with e ->
          (try Unix.close fd with _ -> ());
          raise e)

let read ?timeout t buf off len = t.read ?timeout buf off len
let write ?timeout t b = t.write ?timeout b
let write_string ?timeout t s = t.write ?timeout (Bigstring.of_string s)
let close t = t.close ()

(* A connection leaves its server's list before its descriptor is closed, so
   this never reaches a reused descriptor. *)
let shutdown t =
  try Unix.shutdown t.fd SHUTDOWN_ALL with Unix.Unix_error _ -> ()

let peer t =
  match Unix.getpeername t.fd with
    | ADDR_INET (a, p) -> Printf.sprintf "%s:%d" (Unix.string_of_inet_addr a) p
    | ADDR_UNIX p -> p
    | exception _ -> "?"
