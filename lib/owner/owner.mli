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

(** Whether the domain's recorded holder lives and names a socket (07 §2.5): the
    signal that an owner serves it, which a refused connection is not. *)
val served : Domain_name.t -> bool

(** Runs a call to the socket serving these domains, retrying
    {!Tsync_ipc.Ipc.Not_serving} every 100 ms while one of them is {!served},
    until the request deadline. *)
val retry_refused : Domain_name.t list -> (unit -> 'a) -> 'a

(** Exit status of an owner that found its domain owned. *)
val owner_held : int

(** SIGTERM and SIGINT request the process stop; with [second], a signal after
    that runs it. Call before the runtime starts any domain, so every thread
    inherits the mask. *)
val stop_on_signals : ?second:(unit -> unit) -> unit -> unit

(** What a presenting frontend does for its domain once its engine has started:
    the hooks the handler calls, and what presents it once the socket serves. *)
type present =
  Tsync_domain.Domain.t ->
  (module Tsync_sync.Engine.S) ->
  publish:(Protocol.event -> unit) ->
  Handler.hooks * (unit -> unit)

(** Owner start, serve until the process stop, then drain within the grace.
    Answers the exit status: 0, or {!owner_held}. [shared] (macOS): one socket
    for every domain, possibly none, whose router answers [subscribe], [menu],
    [menu_stats], [pause] and [stop] without a domain (file-provider §4).
    [roots]: the transfer roots the host declares (security-model §7.3), the
    user's home by default. *)
val run :
  ?present:present ->
  ?shared:bool ->
  ?roots:string list ->
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

(** A request to the domain's running owner, retrying a refused connection like
    {!request} but never taking ownership: for what only a running owner can
    answer, such as a job's cancel. *)
val ask :
  ?bulk:bool ->
  ?on_line:(Protocol.line -> unit) ->
  Tsync_config.Config.domain ->
  'a Protocol.request ->
  'a

(** A domain owned by a host with no socket (07 §3.6). *)
type embedded = {
  lock : lock;
  domain : Tsync_domain.Domain.t;
  engine : (module Tsync_sync.Engine.S);
  handler : Handler.t;
}

(** Takes the domain's ownership and builds its request handler, which sends its
    events to [publish]; BUSY naming the holder when another process owns it.
    Without [start] the queues are not started and nothing is reconciled.
    [roots] confine transfer paths. *)
val embed :
  ?start:bool ->
  ?pull_params:Pulls.params ->
  role:string ->
  what:string ->
  roots:string list ->
  publish:(Tsync_ipc.Ipc.json -> int) ->
  frontend:(unit -> Tsync_status.Status_report.frontend option) ->
  Tsync_config.Config.t ->
  Tsync_config.Config.domain ->
  embedded

(** Runs the owner's maintenance schedule (07 §6) until the process stops. *)
val maintain : embedded -> unit

(** An owner-class request (07 §2.5): sent to the domain's owner, else answered
    by {!one_shot}. A job's lines go to [on_line] from an owner; in-process they
    are this process's output. *)
val request :
  ?bulk:bool ->
  ?on_line:(Protocol.line -> unit) ->
  what:string ->
  Tsync_config.Config.t ->
  Tsync_config.Config.domain ->
  'a Protocol.request ->
  'a

(** How a presenting frontend hosts its owner (07 §3.7): given [run], which runs
    the owner with a presentation and answers its exit status, it answers the
    process's exit status. A frontend that must own the main thread (FUSE) runs
    the owner on another. *)
type host =
  mount:string option ->
  Tsync_config.Config.domain list ->
  run:(present -> int) ->
  int

(** At module initialisation, by the frontend's library. *)
val register_host : string -> host -> unit

(** The host of the first frontend of these domains that registered one. *)
val host_for : Tsync_config.Config.domain list -> host option
