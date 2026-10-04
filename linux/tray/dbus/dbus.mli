(** A session-bus connection over libdbus, with no library dispatch: every
    incoming message is handed to the caller, which owes a reply to each method
    call.

    Nothing here blocks except {!connect}. A connection is not safe for
    concurrent use: its caller serialises the calls on it. *)

exception Error of string

(** A D-Bus value. An array carries its element signature, so that an empty one
    is still typed. *)
type value =
  | Byte of int
  | Bool of bool
  | Int32 of int
  | Uint32 of int
  | Int64 of int
  | Double of float
  | String of string
  | Object_path of string
  | Signature of string
  | Array of string * value list
  | Struct of value list
  | Variant of value
  | Dict_entry of value * value
  | Unsupported

type kind = Method_call | Method_return | Error_reply | Signal
type message

val kind : message -> kind

(** The header fields below are [""] when the message carries none. *)

val path : message -> string
val interface : message -> string
val member : message -> string
val error_name : message -> string
val reply_serial : message -> int

(** The sender expects no reply. *)
val no_reply : message -> bool

val body : message -> value list

(** The constructors raise {!Error} on a name libdbus refuses. A string that is
    not valid UTF-8 is sent with each invalid byte replaced. *)

(** An empty [interface] sends the call with none in its header. *)
val method_call :
  destination:string ->
  path:string ->
  interface:string ->
  member:string ->
  value list ->
  message

val method_return : message -> value list -> message
val error_reply : message -> name:string -> string -> message

val signal :
  path:string -> interface:string -> member:string -> value list -> message

type t

(** Opens a private connection to the bus at this address and registers on it. A
    closed bus never ends the process. Blocks for the handshake. *)
val connect : string -> t

val descriptor : t -> Unix.file_descr

(** Queues the message; its serial. *)
val send : t -> message -> int

(** Reads and writes what the socket allows without waiting. [false] once the
    bus closed the connection. *)
val read_write : t -> bool

(** The next message received, if any. *)
val pop : t -> message option

(** Whether queued messages are still to be written. *)
val has_output : t -> bool
