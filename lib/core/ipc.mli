val send : socket_path:string -> string -> string
val auto_evict_enabled : data_dir:string -> bool
val handle_auto_evict : data_dir:string -> string -> string
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
