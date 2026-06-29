(** Path to the Unix-domain socket used for daemon IPC. *)
val socket_path : unit -> string

(** Path to the sentinel file whose presence enables auto-evict mode. *)
val auto_evict_path : unit -> string

(** Send a single-line command to the running daemon and return its response. *)
val send : string -> string

(** Split ["CMD rest of line"] into [("CMD", "rest of line")] on the first
    space. *)
val split_cmd : string -> string * string

(** Start the IPC server loop, calling [handler] for each incoming line. Stops
    when the handler returns ["STOP"]. *)
val serve : (string -> string) -> unit
