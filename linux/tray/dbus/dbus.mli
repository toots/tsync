(** As much of libdbus as a StatusNotifierItem needs, and no more.

    The two protocols the tray speaks -- org.kde.StatusNotifierItem and
    com.canonical.dbusmenu -- are pure D-Bus, so a toolkit would only be a way
    of not writing this. What they are not is small in shape: nested variants,
    arrays of structs of dictionaries. That shape is why the recursion lives in
    OCaml and the C side only offers an iterator handle -- a C marshaller
    switching on [Tag_val] would make every constructor added below a silent
    change to an ABI nobody reviews. *)

type connection
type message
type iter

(** A D-Bus error name and its message, as the peer sent them. *)
exception Error of string * string

(** {1 Values} *)

type value =
  | Byte of int
  | Bool of bool
  | Int16 of int
  | Uint16 of int
  | Int32 of int32
  | Uint32 of int32
  | Int64 of int64
  | Uint64 of int64
  | Double of float
  | String of string
  | Path of string  (** object path, ['o'] *)
  | Sig of string  (** signature, ['g'] *)
  | Array of string * value list
      (** element signature, then elements. The signature is carried rather than
          derived because an empty array must still be typed: [a{sv}] and [as]
          are both [Array (_, [])]. *)
  | Struct of value list
  | Variant of value
  | Dict of value * value  (** only legal inside an {!Array} *)

val signature_of : value -> string

(** The [a{sv}] that both protocols are mostly made of. *)
val dict_sv : (string * value) list -> value

(** {1 Connection} *)

(** The session bus, private and not exiting the process when it drops. A
    library deciding to [_exit] on our behalf is not a diagnosis anyone can
    read. Raises {!Error} when there is no bus to reach. *)
val session_bus : unit -> connection

(** [request_name_exclusive conn name] is whether we became the primary owner.
    DO_NOT_QUEUE: a second tray has to find out now, not silently inherit the
    name when the first one exits. *)
val request_name_exclusive : connection -> string -> bool

val add_match : connection -> string -> unit
val close : connection -> unit

(** {1 Messages} *)

val method_call : int
val method_return : int
val error : int
val signal : int

val message_new_method_call :
  dest:string -> path:string -> iface:string -> member:string -> message

val message_new_signal : path:string -> iface:string -> member:string -> message
val message_type : message -> int

(** These answer [""] where libdbus answers NULL, so a router matches on them
    without an option dance for headers that are simply absent. *)

val message_path : message -> string
val message_interface : message -> string
val message_member : message -> string
val message_sender : message -> string
val message_error_name : message -> string
val message_no_reply : message -> bool

(** {1 Body} *)

val append : message -> value list -> unit
val body : message -> value list

(** {1 Sending} *)

val send : connection -> message -> unit
val flush : connection -> unit

val emit :
  connection ->
  path:string ->
  iface:string ->
  member:string ->
  value list ->
  unit

val reply : connection -> message -> value list -> unit

(** [error_reply conn to_ name text] answers a call with a D-Bus error. Every
    method call must be answered with one or the other: a call left hanging
    costs the caller its full timeout, which for a menu is 25 seconds of looking
    wedged. *)
val error_reply : connection -> message -> string -> string -> unit

(** The four standard refusals, named so that an object's dispatch reads as what
    it does rather than as error strings. *)

val unknown_method : connection -> message -> unit
val unknown_property : connection -> message -> string -> unit
val unknown_interface : connection -> message -> unit
val read_only_property : connection -> message -> unit

(** {1 Introspection}

    No host needs it -- Plasma reads properties, and the GNOME extension brings
    its own interface description -- but [busctl], [gdbus] and [d-feet] do, and
    those are how any of this gets debugged. *)

(** [introspection own] is the document for an object exporting [own], with the
    three interfaces every object answers already around it. *)
val introspection : string -> string

(** A blocking round trip. Unrelated messages that arrive while it waits are
    queued rather than dropped, so this is safe to use from inside the loop.
    Raises {!Error} when the peer answers with one, and on timeout. *)
val call :
  connection ->
  ?timeout:int ->
  dest:string ->
  path:string ->
  iface:string ->
  member:string ->
  value list ->
  value list

(** {1 Receiving} *)

(** [read_write conn timeout_ms] does the transport I/O and queues whatever
    arrived. [false] means the connection is gone. *)
val read_write : connection -> int -> bool

(** The next queued message, taken without running libdbus's own dispatch --
    which would answer method calls we mean to handle with an automatic
    UnknownMethod. Routing is entirely the caller's, and so is the obligation to
    reply to everything. *)
val pop_message : connection -> message option
