(** A byte stream over TCP, plain or TLS (security-model §9), read and written
    from fibers. Two TLS implementations are selectable: OpenSSL and the OCaml
    one. *)

type t
type tls_impl = Openssl | Native

(** The implementation new connections use; [Openssl] by default. *)
val tls_impl : tls_impl Atomic.t

val tls_impl_of_string : string -> tls_impl option

(** Verified TLS: the system trust store, or [ca_file] alone when given, and the
    certificate checked against [host]. *)
type tls = { host : string; ca_file : string option }

(** Connects to the first address of [host] that answers, IPv4 or IPv6. *)
val connect : ?tls:tls -> host:string -> port:int -> unit -> t

(** A connection already accepted by a plain listener. *)
val of_fd : Unix.file_descr -> t

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
