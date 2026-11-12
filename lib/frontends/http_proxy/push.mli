(** Pushes to a domain's iOS clients (frontends/http-proxy.md §A4.7). *)

open Tsync_core

(** The [push_*] listener options. *)
type options = {
  key : string;
  key_id : string;
  team_id : string;
  topic : string;
}

type registration = {
  client : string;
  token : string;
  environment : [ `Development | `Production ];
  fp_domain : string;
  registered : float;  (** wall-clock seconds *)
}

type params = {
  coalesce : float;
  max_age : float;
  auth_renewal : float;
  apns : [ `Development | `Production ] -> string;  (** an APNs base URL *)
}

val default_params : params

type t

(** Reads the key and the registrations kept under [dir]. Raises
    {!Tsync_config.Config.Invalid} naming the option when the key is unusable or
    the build cannot push. [count] receives the counters of §A12. *)
val create :
  ?params:params ->
  count:(string -> unit) ->
  dir:string ->
  options ->
  Domain_name.t list ->
  t

(** Durable once it returns. *)
val register : t -> Domain_name.t -> registration -> unit

(** A log entry by [author] was won: every other client of the domain is due a
    push. Never blocks. *)
val changed : t -> Domain_name.t -> author:string -> unit

(** The registration's fields from a [/push-register] body; [None] when it is
    malformed. *)
val parse_registration : now:float -> string -> registration option

(** The ES256 bearer token APNs takes, signed at [iat]. *)
val jwt : t -> iat:int -> string

val registrations : t -> Domain_name.t -> registration list
