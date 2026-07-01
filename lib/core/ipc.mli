(** Send a single-line command to the running daemon and return its response. *)
val send : socket_path:string -> string -> string

(** Split ["CMD rest of line"] into [("CMD", "rest of line")] on the first
    space. *)
val split_cmd : string -> string * string

type command =
  | Stop
  | Status
  | Evict of string
  | Restore of string
  | Auto_evict of string
  | Full_resync

(** Parse a CLI text line into a command. Raises [Failure] on unknown commands.
*)
val parse_command : string -> command

(** Auto-evict user feature, persisted as a marker file in the daemon data
    directory. [handle_auto_evict] handles the [auto-evict on|off|status] CLI
    command and returns the IPC response string. *)
val auto_evict_enabled : data_dir:string -> bool

val handle_auto_evict : data_dir:string -> string -> string
val notify_evict : path:string -> string -> unit
val notify_restore : path:string -> string -> unit
val notify_uploaded : path:string -> string -> unit

(** Start the IPC server loop, calling [handler] for each incoming line. Stops
    when the handler returns ["STOP"]. *)
val serve : path:string -> (string -> string) -> unit
