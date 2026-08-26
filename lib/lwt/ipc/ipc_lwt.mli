(** The IPC bound to this process's sockets.

    {!Ipc} spoken synchronously is re-exported, so a caller doing both names one
    module; what this adds is {!Ipc.Make} applied to [Lwt_io]. The prose for
    each member is there. *)

include module type of Ipc

(** {!Ipc.Make.send}, named apart from the blocking {!Ipc.send} because the two
    differ in whether they hold up the loop. {!Io_lwt.Clock.is_timeout} tells
    the timeout apart from any other failure. *)
val send_lwt : ?timeout:float -> socket_path:string -> string -> string Lwt.t

module Subs : sig
  type t

  val create : unit -> t
  val publish : t -> topic:string -> string -> int
  val count : t -> topic:string -> int
end

val serve :
  ?subs:Subs.t ->
  path:string ->
  (string -> (string * [ `Continue | `Stop | `Subscribe of string ]) Lwt.t) ->
  unit Lwt.t
