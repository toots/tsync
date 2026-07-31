val send : socket_path:string -> string -> string

(** [send_lwt ?timeout ~socket_path cmd] is {!send} for a caller that is itself
    running an event loop and must not block it. Raises [Lwt_unix.Timeout] after
    [timeout] seconds (default 2.) so a wedged daemon is reported rather than
    waited on. *)
val send_lwt : ?timeout:float -> socket_path:string -> string -> string Lwt.t

(** Fire-and-forget messages to a frontend listening on [path]. Each returns
    whether the message was delivered: the listener only exists while the
    frontend is running, and a caller with no other way to get the news through
    must not report success on a message nothing received. *)

val notify_evict : path:string -> string -> bool
val notify_restore : path:string -> string -> bool
val notify_uploaded : path:string -> string -> bool
val notify_changed : path:string -> string -> bool
val notify_resync : path:string -> bool

(** Start the IPC server loop, calling [handler] for each incoming line. Stops
    when the handler returns [("...", `Stop)]. *)
val serve :
  path:string ->
  (string -> (string * [ `Continue | `Stop ]) Lwt.t) ->
  unit Lwt.t
