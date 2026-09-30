(** The request handler of one domain (spec 08 §3): every frontend, tool and
    command acts on a domain through it, over a socket or by direct call. *)

open Tsync_ipc

(** The frontend-specific behaviour (08 §3.2); {!no_hooks} does nothing. *)
type hooks = {
  changed : string list -> unit;
  surface_evicted : string -> unit;
  surface_restored : string -> unit;
  reannounce : unit -> unit;
  frontend : unit -> Tsync_status.Status_report.frontend option;
}

val no_hooks : hooks

type t

(** [publish] sends an event to the domain's subscribers and answers how many
    received it; [stats] answers the owner's report for an [arg] set; [stop]
    requests the owner's stop. [dest_roots] and [staging_roots] confine the
    paths clients pass (security-model §7.3). *)
val create :
  domain:Tsync_domain.Domain.t ->
  engine:(module Tsync_sync.Engine.S) ->
  hooks:hooks ->
  publish:(Ipc.json -> int) ->
  stats:(string list -> Tsync_status.Status_report.answer) ->
  stop:(unit -> unit) ->
  dest_roots:string list ->
  staging_roots:string list ->
  t

(** Publishes an event to the domain's subscribers, [id] increasing within the
    process (08 §3.8); how many received it. *)
val publish_event : t -> Protocol.event -> int

(** In-process: the rules of 08 §3.5, then the request; a failure raises. *)
val call : t -> 'a Protocol.request -> 'a

(** The socket edge: decodes a request, answers it, and encodes the reply or the
    failure's code; also turns [subscribe] into an event stream. *)
val answer : t -> Ipc.json -> Ipc.answer
