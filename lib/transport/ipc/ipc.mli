val send : socket_path:string -> string -> string

(** [send_lwt ?timeout ~socket_path cmd] is {!send} for a caller that is itself
    running an event loop and must not block it. Raises [Lwt_unix.Timeout] after
    [timeout] seconds (default 2.) so a wedged daemon is reported rather than
    waited on. *)
val send_lwt : ?timeout:float -> socket_path:string -> string -> string Lwt.t

(** Event subscribers.

    The daemon never connects out. A client wanting change notifications
    connects like any other caller and asks to subscribe; its connection then
    carries a stream of events instead of replies. That direction is the
    dependable one: a sandboxed extension can always reach us, while the OS owns
    its lifetime. *)
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
