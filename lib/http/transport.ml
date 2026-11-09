open Tsync_core

type tls_impl = System | Openssl | Native

let tls_impl = Atomic.make None

let tls_impl_of_string = function
  | "system" -> Some System
  | "openssl" -> Some Openssl
  | "native" | "ocaml-tls" -> Some Native
  | _ -> None

type tls = { host : string; ca_file : string option }

type t = {
  read : ?timeout:float -> Bigstring.t -> int -> int -> int;
  write : ?timeout:float -> Bigstring.t -> unit;
  close : unit -> unit;
}

let retry_io = function
  | Unix.Unix_error ((EAGAIN | EWOULDBLOCK | EINTR), _, _) -> true
  | _ -> false

(* 01 §6.5: a call that would block waits and retries as non-blocking I/O;
   one that goes through costs no change of class. *)
let plain fd =
  let rec read ?timeout buf off len =
    match Unix.read_bigarray fd buf off len with
      | n -> n
      | exception e when retry_io e ->
          Rt.within `Immediate (fun () ->
              Rt.wait_readable ?timeout fd;
              read ?timeout buf off len)
  in
  let write ?timeout b =
    let rec go off =
      if off < Bigstring.length b then (
        match
          Unix.single_write_bigarray fd b off (Bigstring.length b - off)
        with
          | n -> go (off + n)
          | exception e when retry_io e ->
              Rt.within `Immediate (fun () ->
                  Rt.wait_writable ?timeout fd;
                  go off))
    in
    go 0
  in
  { read; write; close = (fun () -> try Unix.close fd with _ -> ()) }

let of_fd fd =
  Unix.set_nonblock fd;
  plain fd

let make ~read ~write ~close = { read; write; close }
let tls_failure host what = Fail.raise_ Fail.Link "TLS with %s: %s" host what

(* A certificate that does not verify will not verify on a retry either. *)
let untrusted host what = Fail.raise_ Fail.Refused "TLS with %s: %s" host what

type backend = {
  client :
    [ `Over_socket of Unix.file_descr -> tls -> t
    | `Platform of host:string -> port:int -> tls -> t ];
  server : (certificate:string -> key:string -> Unix.file_descr -> t) option;
}

let backends = Atomic.make []

let rec register impl b =
  let l = Atomic.get backends in
  if not (Atomic.compare_and_set backends l ((impl, b) :: l)) then
    register impl b

let available () = List.map fst (Atomic.get backends)

let impl_name = function
  | System -> "system"
  | Openssl -> "openssl"
  | Native -> "native"

let impl_names =
  String.concat ", " (List.map impl_name [System; Openssl; Native])

(* security-model §9.2: [System] is OpenSSL on a host that registers no
   platform implementation of its own. *)
let built impl =
  let find impl = List.assoc_opt impl (Atomic.get backends) in
  match (impl, find impl) with System, None -> find Openssl | _, b -> b

(* 05 §2 [tls]: unset is the platform implementation, else OpenSSL, else the
   OCaml one. *)
let backend () =
  match Atomic.get tls_impl with
    | Some impl -> (
        match built impl with
          | Some b -> b
          | None ->
              Fail.raise_ Fail.Invalid "this build has no %s TLS"
                (impl_name impl))
    | None -> (
        match List.find_map built [System; Openssl; Native] with
          | Some b -> b
          | None -> Fail.raise_ Fail.Invalid "this build has no TLS")

(* An unroutable address family must not hold the next address back. *)
let connect_timeout = 10.

let connect_fd ~host ~port =
  let addrs =
    Unix.getaddrinfo host (string_of_int port) [AI_SOCKTYPE SOCK_STREAM]
  in
  if addrs = [] then Fail.raise_ Fail.Link "%s: no address" host;
  (* One address: the connected socket, or the failure that moves on to the
     next one; anything else raises, the socket closed (lesson 8). *)
  let connect_one (a : Unix.addr_info) =
    let fd = Unix.socket ~cloexec:true a.ai_family a.ai_socktype 0 in
    let failed =
      Fs.or_close fd (fun fd ->
          Unix.set_nonblock fd;
          match Unix.connect fd a.ai_addr with
            | () -> None
            (* Windows reports a connection under way as EWOULDBLOCK. *)
            | exception Unix.Unix_error (e, _, _)
              when e = EINPROGRESS || (Sys.win32 && e = EWOULDBLOCK) -> (
                match Rt.wait_writable ~timeout:connect_timeout fd with
                  | exception Rt.Timeout ->
                      Some (Unix.Unix_error (ETIMEDOUT, "connect", host))
                  | () ->
                      Option.map
                        (fun e -> Unix.Unix_error (e, "connect", host))
                        (Unix.getsockopt_error fd))
            | exception e when not (Rt.is_cancelled e) -> Some e)
    in
    match failed with
      | None -> Ok fd
      | Some e ->
          Fs.close fd;
          Error e
  in
  let rec try_ last = function
    | [] -> (
        match last with
          | Some e -> raise e
          | None -> Fail.raise_ Fail.Link "%s: no address" host)
    | a :: rest -> (
        match connect_one a with Ok fd -> fd | Error e -> try_ (Some e) rest)
  in
  let fd = try_ None addrs in
  (try Unix.setsockopt fd TCP_NODELAY true with Unix.Unix_error _ -> ());
  fd

(* A peer that takes the connection and never speaks TLS would otherwise hold
   the caller forever; the whole handshake is bounded, not each wait. *)
let bounded_handshake ~host timeout f =
  try Rt.with_timeout timeout f
  with Rt.Timeout ->
    tls_failure host (Printf.sprintf "no handshake within %gs" timeout)

(* A name is never loopback by its spelling: 127.0.0.1.example.org is a host
   like any other. *)
let is_loopback host =
  host = "localhost" || host = "::1" || host = "[::1]"
  ||
    match List.map int_of_string_opt (String.split_on_char '.' host) with
    | [Some 127; Some b; Some c; Some d] ->
        List.for_all (fun octet -> octet >= 0 && octet <= 255) [b; c; d]
    | _ -> false

let cleartext_loopback_only = Atomic.make false

let connect ?(handshake_timeout = connect_timeout) ?tls ~host ~port () =
  if tls = None && Atomic.get cleartext_loopback_only && not (is_loopback host)
  then Fail.raise_ Fail.Refused "%s: cleartext connections are refused" host;
  match tls with
    | None -> plain (connect_fd ~host ~port)
    | Some tls -> (
        match (backend ()).client with
          | `Over_socket handshake -> (
              let fd = connect_fd ~host ~port in
              try
                bounded_handshake ~host:tls.host handshake_timeout (fun () ->
                    handshake fd tls)
              with e ->
                (try Unix.close fd with _ -> ());
                raise e)
          | `Platform open_connection ->
              (* 01 §10: the platform's phases cannot be told apart. *)
              bounded_handshake ~host:tls.host
                (connect_timeout +. handshake_timeout) (fun () ->
                  open_connection ~host ~port tls))

type server_tls = Unix.file_descr -> t

(* security-model §9.1: a client-only platform implementation leaves the
   listener to one that serves. *)
let server_tls ~certificate ~key =
  let serving =
    match (backend ()).server with
      | Some s -> Some s
      | None ->
          List.find_map
            (fun impl -> Option.bind (built impl) (fun b -> b.server))
            [Openssl; Native]
  in
  match serving with
    | Some s -> s ~certificate ~key
    | None -> Fail.raise_ Fail.Invalid "this build has no TLS that serves"

let accept_tls ~timeout server fd =
  bounded_handshake ~host:"client" timeout (fun () -> server fd)

let read ?timeout t buf off len = t.read ?timeout buf off len
let write ?timeout t b = t.write ?timeout b
let write_string ?timeout t s = t.write ?timeout (Bigstring.of_string s)
let close t = t.close ()

(* A connection leaves its server's list before its descriptor is closed, so
   this never reaches a reused descriptor. *)
let shutdown fd =
  try Unix.shutdown fd SHUTDOWN_ALL with Unix.Unix_error _ -> ()

let peer fd =
  match Unix.getpeername fd with
    | ADDR_INET (a, p) -> Printf.sprintf "%s:%d" (Unix.string_of_inet_addr a) p
    | ADDR_UNIX p -> p
    | exception _ -> "?"
