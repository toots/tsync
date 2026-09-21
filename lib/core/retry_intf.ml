(** Whether a failure is worth trying again. A 503, a dropped socket and a full
    disk clear on their own; a 403, a bad key and a read-only target do not, and
    retrying those only delays the report. *)
type kind = Transient | Permanent

exception Failed of { kind : kind; op : string; detail : string }

(** Raised through a retry loop without being retried: the work is no longer
    wanted, so another attempt would be one nobody reads. *)
exception Cancelled

(** The one retry loop for a single request, jittered so a fleet that failed
    together does not return together. A caller decides only what [classify]
    means for it; the curve, the cap and the log line are shared, so two of them
    cannot drift into retrying differently. {!Cancelled} is never retried.

    [health] is the member the request is made of, told of every failure that
    may clear and of every answer. The climb goes on regardless: a caller with
    another member to ask stops waiting on its own account. *)
module type LOOP = sig
  type 'a io

  val with_retry :
    ?max_attempts:int ->
    ?health:Health.t ->
    classify:(exn -> kind) ->
    name:string ->
    op:string ->
    (unit -> 'a io) ->
    'a io
end
