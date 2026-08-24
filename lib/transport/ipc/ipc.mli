val send : socket_path:string -> string -> string

(** [send_lwt ?timeout ~socket_path cmd] is {!send} for a caller that is itself
    running an event loop and must not block it. Raises [Lwt_unix.Timeout] after
    [timeout] seconds (default 2.) so a wedged daemon is reported rather than
    waited on. *)
val send_lwt : ?timeout:float -> socket_path:string -> string -> string Lwt.t

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
  (string -> (string * [ `Continue | `Stop | `Subscribe of string ]) Lwt.t) ->
  unit Lwt.t
