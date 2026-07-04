val send : socket_path:string -> string -> string
val auto_evict_enabled : data_dir:string -> bool
val handle_auto_evict : data_dir:string -> string -> string

(** Minimum free-space percentage to preserve on the filesystem holding the
    local cache. [None] = disabled; defaults to 10%% when never configured. *)
val preserve_space_percent : data_dir:string -> float option

val handle_preserve_space : data_dir:string -> string -> string
val notify_evict : path:string -> string -> unit
val notify_restore : path:string -> string -> unit
val notify_uploaded : path:string -> string -> unit
val notify_changed : path:string -> string -> unit

(** Start the IPC server loop, calling [handler] for each incoming line. Stops
    when the handler returns [("...", `Stop)]. *)
val serve :
  path:string ->
  (string -> (string * [ `Continue | `Stop ]) Lwt.t) ->
  unit Lwt.t
