module Host_name = Domain_name
open Tsync_core
module Transport = Tsync_http.Transport

let rng_initialised = Atomic.make false

let init_rng () =
  if not (Atomic.exchange rng_initialised true) then
    Mirage_crypto_rng_unix.use_default ()

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
let native_client ({ host; ca_file } : Transport.tls) =
  init_rng ();
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
      | Error (`Msg m) -> Transport.tls_failure host m
  in
  let state, hello = Tls.Engine.client config in
  (state, Some hello)

(* [first] is what this side sends before reading: a client's hello, nothing
   for a server. *)
let native_session ?timeout fd ~host
    ((state, first) : Tls.Engine.state * string option) =
  let raw = Transport.plain fd in
  let state = ref state in
  (* The engine speaks strings: what it hands back is copied once into the
     caller's buffer. *)
  let pending = ref "" and pending_pos = ref 0 in
  let eof = ref false in
  let chunk = Bigstring.create 16384 in
  let send ?timeout s = Transport.write ?timeout raw (Bigstring.of_string s) in
  Option.iter send first;
  let pump ?timeout () =
    let n = Transport.read ?timeout raw chunk 0 (Bigstring.length chunk) in
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
                  Transport.untrusted host
                    (Format.asprintf "%a" X509.Validation.pp_validation_error e
                    |> String.split_on_char '\n' |> List.rev |> List.hd
                    |> String.trim)
              | f -> Transport.tls_failure host (Tls.Engine.string_of_failure f)
            ))
  in
  while Tls.Engine.handshake_in_progress !state && not !eof do
    pump ?timeout ()
  done;
  if !eof then
    Transport.tls_failure host "the connection closed during the handshake";
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
  (* ocaml-tls takes strings: one record's worth at a time, so a mapped chunk
     is never copied whole onto the heap. *)
  let record = 16384 in
  let write ?timeout b =
    let n = Bigstring.length b in
    let rec go off =
      if off < n then (
        let len = min record (n - off) in
        match
          Tls.Engine.send_application_data !state
            [Bigstring.to_string ~off ~len b]
        with
          | Some (st, out) ->
              state := st;
              send ?timeout out;
              go (off + len)
          | None -> Transport.tls_failure host "the session is not ready")
    in
    go 0
  in
  Transport.make ~fd ~read ~write ~close:(fun () ->
      (try
         let st, out = Tls.Engine.send_close_notify !state in
         state := st;
         send ~timeout:1. out
       with _ -> ());
      Transport.close raw)

let () =
  Transport.register Native
    {
      client =
        (fun fd tls ->
          native_session fd ~host:tls.Transport.host (native_client tls));
      server =
        (fun ~certificate ~key ->
          init_rng ();
          let fail what = Fail.raise_ Fail.Invalid "TLS %s" what in
          let certs =
            match
              X509.Certificate.decode_pem_multiple (Fs.read_file certificate)
            with
              | Ok (_ :: _ as l) -> l
              | Ok [] -> fail (certificate ^ ": no certificate")
              | Error (`Msg m) -> fail (certificate ^ ": " ^ m)
          and pk =
            match X509.Private_key.decode_pem (Fs.read_file key) with
              | Ok k -> k
              | Error (`Msg m) -> fail (key ^ ": " ^ m)
          in
          match Tls.Config.server ~certificates:(`Single (certs, pk)) () with
            | Ok c ->
                fun fd ->
                  native_session fd ~host:"client" (Tls.Engine.server c, None)
            | Error (`Msg m) -> fail m);
    }
