val send : socket_path:string -> string -> string

(** [send_lwt ?timeout ~socket_path cmd] is {!send} for a caller that is itself
    running an event loop and must not block it. Raises [Lwt_unix.Timeout] after
    [timeout] seconds (default 2.) so a wedged daemon is reported rather than
    waited on. *)
val send_lwt : ?timeout:float -> socket_path:string -> string -> string Lwt.t

val notify_evict : path:string -> string -> unit
val notify_restore : path:string -> string -> unit
val notify_uploaded : path:string -> string -> unit
val notify_changed : path:string -> string -> unit
val notify_resync : path:string -> unit

(** Start the IPC server loop, calling [handler] for each incoming line. Stops
    when the handler returns [("...", `Stop)]. *)
val serve :
  path:string ->
  (string -> (string * [ `Continue | `Stop ]) Lwt.t) ->
  unit Lwt.t
