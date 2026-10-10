(** An HTTP/1.1 listener (security-model §11): header size and time bounds, an
    idle bound on every read and write, keep-alive, a connection bound, and a
    body read only when the handler asks for it within its own limit. *)

type limits = {
  header_bytes : int;
  header_timeout : float;
  idle_timeout : float;
  keepalive_timeout : float;
  max_connections : int;
}

val default_limits : limits

type request = {
  meth : string;
  target : string;  (** as received: path and raw query *)
  path : string;
  query : string;  (** raw, after [?]; [""] when absent *)
  headers : Codec.headers;
  peer : string;
  body_length : [ `Length of int | `Chunked | `Eof ];
}

type body =
  | Empty
  | String of string  (** short texts *)
  | Bigstring of Tsync_core.Bigstring.t
  | Stream of {
      write : (Tsync_core.Bigstring.t -> unit) -> unit;
          (** written as chunks, or as [length] bytes when that is known; a
              failure after the headers truncates it *)
      length : int option;
      finally : unit -> unit;
          (** run once the response ends, on every path: written, skipped for
              HEAD, failed on its head or body (pitfall C-2.9) *)
    }
  | Held of { bytes : Tsync_core.Bigstring.t; finally : unit -> unit }
      (** a body of known length whose [finally] runs as a stream's does: for a
          resource held until the body is written *)

type response = { status : int; headers : Codec.headers; body : body }

(** A streamed body; [finally] defaults to nothing. *)
val stream :
  ?finally:(unit -> unit) ->
  ?length:int ->
  ((Tsync_core.Bigstring.t -> unit) -> unit) ->
  body

(** A [text/plain] answer of one line. *)
val text : ?headers:Codec.headers -> int -> string -> response

(** Raised by the body reader past the handler's limit. *)
exception Body_too_large

type t

(** [handle] reads the body with the function it is given, at most once. With
    [tls], each connection's handshake runs in its own fiber within the header
    timeout. *)
val serve :
  ?limits:limits ->
  ?tls:Transport.server_tls ->
  Unix.sockaddr list ->
  (request -> (limit:int -> Tsync_core.Bigstring.t) -> response) ->
  t

(** Stops accepting, lets in-flight requests finish within [grace], then closes
    what remains. *)
val close : ?grace:float -> t -> unit

(** Requests in flight. *)
val in_flight : t -> int

(** The bound addresses, ports resolved. *)
val addresses : t -> Unix.sockaddr list
