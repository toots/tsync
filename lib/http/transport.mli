(** A byte stream over TCP, plain or TLS (security-model §9), read and written
    from fibers. Each TLS implementation the build has registers itself: OpenSSL
    ([tsync_http_ssl]) and the OCaml one ([tsync_http_native]). *)

type t
type tls_impl = Openssl | Native

(** The implementation new connections use; [None] is the build's default,
    OpenSSL when it was built. INVALID at the next connection when the build
    lacks the one set. *)
val tls_impl : tls_impl option Atomic.t

(** The implementations this build has. *)
val available : unit -> tls_impl list

val impl_name : tls_impl -> string
val tls_impl_of_string : string -> tls_impl option

(** Verified TLS: the system trust store, or [ca_file] alone when given, and the
    certificate checked against [host]. *)
type tls = { host : string; ca_file : string option }

(** [localhost] or a loopback address literal. *)
val is_loopback : string -> bool

(** Set by a host whose platform cannot veto the core's traffic (android §4.1):
    a connection without TLS to a host that is not {!is_loopback} is REFUSED. *)
val cleartext_loopback_only : bool Atomic.t

(** Connects to the first address of [host] that answers, IPv4 or IPv6. The
    whole TLS handshake is bounded by [handshake_timeout] (10 s); a failed
    handshake closes the socket, so the peer sees the end of the stream. *)
val connect :
  ?handshake_timeout:float -> ?tls:tls -> host:string -> port:int -> unit -> t

(** A listener's certificate chain and key, loaded once with the implementation
    of {!tls_impl}; INVALID when they do not load. *)
type server_tls

val server_tls : certificate:string -> key:string -> server_tls

(** The server side of the handshake on an accepted connection, all of it within
    [timeout]; the caller closes the connection when it fails. *)
val accept_tls : timeout:float -> server_tls -> t -> t

(** A connection already accepted by a plain listener. *)
val of_fd : Unix.file_descr -> t

(** {2 For TLS implementations} *)

(** A plain stream over a non-blocking descriptor. *)
val plain : Unix.file_descr -> t

val make :
  fd:Unix.file_descr ->
  read:(?timeout:float -> Tsync_core.Bigstring.t -> int -> int -> int) ->
  write:(?timeout:float -> Tsync_core.Bigstring.t -> unit) ->
  close:(unit -> unit) ->
  t

(** A handshake or session failure: TRANSIENT/LINK. *)
val tls_failure : string -> string -> 'a

(** A certificate that does not verify, which a retry will not change. *)
val untrusted : string -> string -> 'a

type backend = {
  client : Unix.file_descr -> tls -> t;  (** the client handshake *)
  server : certificate:string -> key:string -> Unix.file_descr -> t;
      (** loads the chain once, then the server handshake per connection *)
}

val register : tls_impl -> backend -> unit

(** Up to [len] bytes; 0 at end of stream. [timeout] bounds the wait. *)
val read : ?timeout:float -> t -> Tsync_core.Bigstring.t -> int -> int -> int

val write : ?timeout:float -> t -> Tsync_core.Bigstring.t -> unit

(** Small metadata: status lines, headers. *)
val write_string : ?timeout:float -> t -> string -> unit

val close : t -> unit

(** Wakes whoever reads or writes it, without closing the descriptor. *)
val shutdown : t -> unit

(** The peer address, for logs. *)
val peer : t -> string
