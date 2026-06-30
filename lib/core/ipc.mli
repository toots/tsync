(** Path to the Unix-domain socket used for daemon IPC. *)
val socket_path : unit -> string

(** Path to the sentinel file whose presence enables auto-evict mode. *)
val auto_evict_path : unit -> string

(** Send a single-line command to the running daemon and return its response. *)
val send : string -> string

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

(** Parse a CLI text line into a command. Raises [Failure] on unknown commands. *)
val parse_command : string -> command

val notify_evict : path:string -> string -> unit
val notify_uploaded : path:string -> string -> unit

(** Start the IPC server loop, calling [handler] for each incoming line. Stops
    when the handler returns ["STOP"]. *)
val serve : path:string -> (string -> string) -> unit
