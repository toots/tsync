(** A byte stream over TCP, plain or TLS (security-model §9), read and written
    from fibers. Each TLS implementation the build has registers itself: OpenSSL
    ([tsync_http_ssl]), the OCaml one ([tsync_http_native]) and the platform's
    where it is not OpenSSL ([tsync_http_apple]). *)

type t

(** [System] is the platform's implementation, OpenSSL where the build registers
    none of its own (security-model §9.2). *)
type tls_impl = System | Openssl | Native

(** The implementation new connections use; [None] is the build's default:
    [System], else OpenSSL, else the OCaml one. INVALID at the next connection
    when the build lacks the one set. *)
val tls_impl : tls_impl option Atomic.t

(** The implementations this build has. *)
val available : unit -> tls_impl list

val impl_name : tls_impl -> string

(** Every name {!tls_impl_of_string} reads, for messages. *)
val impl_names : string

val tls_impl_of_string : string -> tls_impl option

(** Verified TLS: the system trust store, or [ca_file] alone when given, and the
    certificate checked against [host]. *)
type tls = { host : string; ca_file : string option }

(** [localhost] or a loopback address literal. *)
val is_loopback : string -> bool

(** Set by a host whose platform cannot veto the core's traffic (android §4.1):
    a connection without TLS to a host that is not {!is_loopback} is REFUSED. *)
val cleartext_loopback_only : bool Atomic.t

(** Connects to the first address of [host] that answers, IPv4 or IPv6, each
    within [CONNECT_TIMEOUT] (10 s). The whole TLS handshake is bounded by
    [handshake_timeout] (10 s), and a platform connection by both; a failed
    handshake closes the socket, so the peer sees the end of the stream. *)
val connect :
  ?handshake_timeout:float -> ?tls:tls -> host:string -> port:int -> unit -> t

(** A listener's certificate chain and key, loaded once with the implementation
    of {!tls_impl}, or OpenSSL or the OCaml one when that one cannot serve;
    INVALID when they do not load. *)
type server_tls

val server_tls : certificate:string -> key:string -> server_tls

(** The server side of the handshake on an accepted socket, all of it within
    [timeout]; the caller closes the socket when it fails. *)
val accept_tls : timeout:float -> server_tls -> Unix.file_descr -> t

(** A connection already accepted by a plain listener. *)
val of_fd : Unix.file_descr -> t

(** {2 For TLS implementations} *)

(** A plain stream over a non-blocking descriptor. *)
val plain : Unix.file_descr -> t

val make :
  read:(?timeout:float -> Tsync_core.Bigstring.t -> int -> int -> int) ->
  write:(?timeout:float -> Tsync_core.Bigstring.t -> unit) ->
  close:(unit -> unit) ->
  t

(** A handshake or session failure: TRANSIENT/LINK. *)
val tls_failure : string -> string -> 'a

(** A certificate that does not verify, which a retry will not change. *)
val untrusted : string -> string -> 'a

(** [client] is the handshake over a socket the core connected, or a platform
    connection that resolves, connects and handshakes itself and closes what it
    opened when cancelled (security-model §9.1). [server] loads the chain once,
    then runs the server handshake per connection; [None] for a client-only
    implementation. *)
type backend = {
  client :
    [ `Over_socket of Unix.file_descr -> tls -> t
    | `Platform of host:string -> port:int -> tls -> t ];
  server : (certificate:string -> key:string -> Unix.file_descr -> t) option;
}

val register : tls_impl -> backend -> unit

(** Up to [len] bytes; 0 at end of stream. [timeout] bounds the wait. *)
val read : ?timeout:float -> t -> Tsync_core.Bigstring.t -> int -> int -> int

val write : ?timeout:float -> t -> Tsync_core.Bigstring.t -> unit

(** Small metadata: status lines, headers. *)
val write_string : ?timeout:float -> t -> string -> unit

val close : t -> unit

(** Wakes whoever reads or writes an accepted socket, without closing it. *)
val shutdown : Unix.file_descr -> unit

(** An accepted socket's peer address, for logs. *)
val peer : Unix.file_descr -> string
