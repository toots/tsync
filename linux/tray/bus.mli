(** The tray's session-bus connection as one event source of the runtime (spec
    frontends/linux-tray.md §5.1): nothing here waits on the bus while holding
    it, so a call the tray makes never delays a reply it owes. *)

open Tsync_dbus

type t

(** Raises {!Dbus.Error}. *)
val connect : string -> t

(** Queues a message and writes what the socket takes. Safe from any fiber. *)
val send : t -> Dbus.message -> unit

(** A method call and its reply's body, or the error's name. No reply within
    [timeout] is [Error "timeout"]. Only the calling fiber waits. *)
val call :
  t ->
  timeout:float ->
  destination:string ->
  path:string ->
  interface:string ->
  member:string ->
  Dbus.value list ->
  (Dbus.value list, string) result

(** Hands every method call and signal received to the handler, which must not
    wait, until the bus closes the connection. *)
val serve : t -> (Dbus.message -> unit) -> unit
