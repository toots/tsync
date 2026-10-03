(** The request handler of one domain (spec 08 §3): every frontend, tool and
    command acts on a domain through it, over a socket or by direct call. *)

open Tsync_ipc

(** The frontend-specific behaviour (08 §3.2); {!no_hooks} does nothing. *)
type hooks = {
  changed : string list -> unit;
  reannounce : unit -> unit;
  frontend : unit -> Tsync_status.Status_report.frontend option;
}

val no_hooks : hooks

type t

(** [publish] sends an event to the domain's subscribers and answers how many
    received it; [stats] answers the owner's report for an [arg] set; [stop]
    requests the owner's stop. [dest_roots] and [staging_roots] confine the
    paths clients pass (security-model §7.3). [subscribers] counts the
    connections subscribed to the domain's events and [traffic] measures its
    stores, for [status] (08 §3.3). On a pulled tree [publish] also receives the
    notices of android §4.2. *)
val create :
  ?subscribers:(unit -> int) ->
  ?traffic:(unit -> Tsync_status.Status_report.traffic) ->
  ?pull_params:Pulls.params ->
  domain:Tsync_domain.Domain.t ->
  engine:(module Tsync_sync.Engine.S) ->
  hooks:hooks ->
  publish:(Ipc.json -> int) ->
  stats:(string list -> Tsync_status.Status_report.answer) ->
  stop:(unit -> unit) ->
  dest_roots:string list ->
  staging_roots:string list ->
  unit ->
  t

(** An event of this domain, numbered as {!publish_event} numbers them. *)
val event_json : t -> Protocol.event -> Ipc.json

(** Publishes an event to the domain's subscribers, [id] increasing within the
    process (08 §3.8); how many received it. *)
val publish_event : t -> Protocol.event -> int

(** Where a job's lines go in this process: output to stdout, narration to
    stderr (07 §5.1). *)
val print_line : Protocol.line -> unit

(** In-process: the rules of 08 §3.5, then the request; a failure raises. A
    job's output goes to this process's stdout, its narration to stderr. *)
val call : t -> 'a Protocol.request -> 'a

(** The socket edge: decodes a request, answers it, and encodes the reply or the
    failure's code; also turns [subscribe] into an event stream. *)
val answer : t -> Ipc.json -> Ipc.answer

(** Pulled tree: a [changed] notice naming the folders of these keys; what the
    engine's changed hook is set to. *)
val keys_changed : t -> string list -> unit

(** android §5 [open]: resolves a file reference to its current version and
    retains it; released with the engine's [release]. *)
val open_version : t -> string -> Tsync_sync.Local_ops.handle

(** The path a reference resolves to; mints nothing (08 §2.2). *)
val path_of_ref : t -> string -> string
