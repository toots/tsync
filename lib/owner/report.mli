(** A domain's body in the status report (spec 07 §5.5), answered by its owner.
    Each member's probe and journal listing are cached for STORE_STATE_WINDOW
    and refreshed behind the answer, which waits for a listing at most
    LISTING_GRACE after the probe. *)

type t

val create :
  Tsync_domain.Domain.t ->
  (module Tsync_sync.Engine.S) ->
  frontend:(unit -> Tsync_status.Status_report.frontend option) ->
  t

val domain_body : t -> Tsync_status.Status_report.domain_body

(** The traffic of these domains' stores, rates since the previous call. *)
val traffic : t list -> Tsync_status.Status_report.traffic
