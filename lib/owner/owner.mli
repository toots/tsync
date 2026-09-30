(** The domain owner (spec 07 §2.2–§2.3, §3.2, §3.4): the one process that
    mutates a domain's local state, serving its request handler on a socket. *)

open Tsync_core

(** The advisory record an owner writes into its lock file. *)
type holder = {
  pid : int;
  role : string;  (** [daemon], [command] or [app] *)
  what : string;
  socket : string option;
}

type lock

(** Non-blocking and exclusive; [Error] carries the current holder's record when
    one is readable. The lock lives until {!release} or process exit. *)
val acquire :
  ?socket:string ->
  role:string ->
  what:string ->
  Domain_name.t ->
  (lock, holder option) result

val release : lock -> unit

(** The record in a domain's lock file; advisory, the lock may be free. *)
val holder : Domain_name.t -> holder option

(** Exit status of an owner that found its domain owned. *)
val owner_held : int

(** SIGTERM and SIGINT request the process stop. Call before the runtime starts
    any domain, so every thread inherits the mask. *)
val stop_on_signals : unit -> unit

(** What a presenting frontend does for its domain: present it, then return the
    hooks the handler calls. *)
type present =
  Tsync_domain.Domain.t -> (module Tsync_sync.Engine.S) -> Handler.hooks

(** Owner start, serve until the process stop, then drain within the grace.
    Answers the exit status: 0, or {!owner_held}. *)
val run :
  ?present:present ->
  ?socket:string ->
  Tsync_config.Config.t ->
  Tsync_config.Config.domain list ->
  int

(** Takes the domain's ownership for [f]'s duration, with an in-process request
    handler, and drains before releasing it; BUSY when another process holds it.
*)
val one_shot :
  what:string ->
  Tsync_config.Config.t ->
  Tsync_config.Config.domain ->
  (Handler.t -> 'a) ->
  'a

(** An owner-class request (07 §2.5): sent to the domain's owner, else answered
    by {!one_shot}. *)
val request :
  ?bulk:bool ->
  what:string ->
  Tsync_config.Config.t ->
  Tsync_config.Config.domain ->
  Tsync_ipc.Ipc.json ->
  Tsync_ipc.Ipc.json
