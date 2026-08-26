val send : socket_path:string -> string -> string

(** [fields] as one request, answering its reply object. Raises [Failure]
    carrying the daemon's own message when the reply says [ok:false].

    The half that reads what {!Ipc_handler.error_reply} writes, so a caller acts
    on the envelope rather than on the wording of a sentence. [socket_path] is
    required rather than defaulted: a socket belongs to a domain, and which
    domain a caller means is the caller's to decide. *)
val request :
  socket_path:string ->
  (string * Yojson.Safe.t) list ->
  (string * Yojson.Safe.t) list

(** {!request} for the shape every action uses. The optional fields are omitted
    rather than sent empty, an absent [domain] being how a caller addresses a
    daemon serving exactly one. *)
val action :
  socket_path:string ->
  ?item:Item_ref.t ->
  ?arg:string ->
  ?domain:string ->
  string ->
  (string * Yojson.Safe.t) list

(** {1 The same socket, from inside an event loop}

    Everything above blocks the caller, which is what a one-shot command wants.
    A daemon has a loop to keep turning, so it takes the transport as a
    parameter and speaks through {!Make}. *)

(** What the loop's half needs of a transport, which is a line each way and a
    listener. *)
module type TRANSPORT = sig
  type 'a io
  type input
  type output
  type server

  val connect : string -> (input * output) io

  (** Raises at end of input. That is how a client going away reaches the loops
      inside: both of them read until this stops answering. *)
  val read_line : input -> string io

  val write_line : output -> string -> unit io
  val flush : output -> unit io
  val close : input -> unit io
  val serve : path:string -> (input * output -> unit io) -> server io
  val shutdown : server -> unit io
end

module Make
    (Io : Io.S)
    (Lock : Lock.S with type 'a io := 'a Io.t)
    (Clock : Clock.S with type 'a io := 'a Io.t)
    (T : TRANSPORT with type 'a io := 'a Io.t) : sig
  (** {!send} without blocking the loop. Raises after [timeout] seconds (default
      2.) so a wedged daemon is reported rather than waited on. *)
  val send : ?timeout:float -> socket_path:string -> string -> string Io.t

  (** Event subscribers.

      The daemon never connects out: a client wanting change notifications
      connects like any other caller and asks to subscribe, its connection then
      carrying a stream of events instead of replies. That direction is the
      dependable one, a sandboxed extension being always able to reach us while
      the OS owns its lifetime. *)
  module Subs : sig
    type t

    val create : unit -> t

    (** Queue [msg] for every subscriber of [topic] (a domain name; a subscriber
        registered under [""] hears everything) and return how many there were.
        Zero says nobody was listening, not that the request failed. *)
    val publish : t -> topic:string -> string -> int

    val count : t -> topic:string -> int
  end

  (** Start the IPC server loop, calling [handler] for each incoming line. A
      connection carries requests until the client closes it. Stops serving when
      the handler returns [`Stop]; hands the connection to [subs] as an event
      stream when it returns [`Subscribe topic]. Without [subs] a subscribe
      request simply closes the connection. *)
  val serve :
    ?subs:Subs.t ->
    path:string ->
    (string -> (string * [ `Continue | `Stop | `Subscribe of string ]) Io.t) ->
    unit Io.t
end
