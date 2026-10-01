open Tsync_core

type tls_impl = Openssl | Native

let tls_impl = Atomic.make None

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

let make ~fd ~read ~write ~close = { fd; read; write; close }
let tls_failure host what = Fail.raise_ Fail.Link "TLS with %s: %s" host what

(* A certificate that does not verify will not verify on a retry either. *)
let untrusted host what = Fail.raise_ Fail.Refused "TLS with %s: %s" host what

type backend = {
  client : Unix.file_descr -> tls -> t;
  server : certificate:string -> key:string -> Unix.file_descr -> t;
}

let backends = Atomic.make []

let rec register impl b =
  let l = Atomic.get backends in
  if not (Atomic.compare_and_set backends l ((impl, b) :: l)) then
    register impl b

let available () = List.map fst (Atomic.get backends)
let impl_name = function Openssl -> "openssl" | Native -> "native"

(* 05 §2 [tls]: unset is the build's default, OpenSSL when it was built. *)
let backend () =
  let built impl = List.assoc_opt impl (Atomic.get backends) in
  match Atomic.get tls_impl with
    | Some impl -> (
        match built impl with
          | Some b -> b
          | None ->
              Fail.raise_ Fail.Invalid "this build has no %s TLS"
                (impl_name impl))
    | None -> (
        match (built Openssl, built Native) with
          | Some b, _ | None, Some b -> b
          | None, None -> Fail.raise_ Fail.Invalid "this build has no TLS")

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

(* A peer that takes the connection and never speaks TLS would otherwise hold
   the caller forever; the whole handshake is bounded, not each wait. *)
let bounded_handshake ~host timeout f =
  try Rt.with_timeout timeout f
  with Rt.Timeout ->
    tls_failure host (Printf.sprintf "no handshake within %gs" timeout)

let connect ?(handshake_timeout = connect_timeout) ?tls ~host ~port () =
  let fd = connect_fd ~host ~port in
  match tls with
    | None -> plain fd
    | Some tls -> (
        try
          bounded_handshake ~host:tls.host handshake_timeout (fun () ->
              (backend ()).client fd tls)
        with e ->
          (try Unix.close fd with _ -> ());
          raise e)

type server_tls = Unix.file_descr -> t

let server_tls ~certificate ~key = (backend ()).server ~certificate ~key

let accept_tls ~timeout server t =
  bounded_handshake ~host:"client" timeout (fun () -> server t.fd)

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
