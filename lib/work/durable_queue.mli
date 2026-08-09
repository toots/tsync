(** Work that has to happen, kept on disk until it does.

    A record is written before the caller is told its own operation is done, so
    a crash leaves something saying what is still owed. Nothing here knows what
    a job {i is}: the owner supplies {!JOB} and the function that runs one.

    Two things sit here, because the durable record outlives the queue that
    drains it:

    - {!Make.Records} — the records themselves, usable on their own by work done
      synchronously that only needs to survive a crash, and read by whatever
      reconciles or reports on what is outstanding.
    - {!Make.t} — a worker draining that log, either {!Make.ordered} or
      {!Make.keyed}; both share the log, the backoff, the poison policy and the
      drain, and differ only in what the work is. *)

(** What to do with a job whose failure will not clear.

    Either way the job leaves the queue: the same request would be refused
    again, and everything recorded behind it would wait forever. *)
type poison =
  | Stop
      (** Leave the record on disk. For work something outside the queue is
          expected to reconcile or report, so dropping it would strand what it
          names. *)
  | Drop
      (** Unlink the record. For a target that can be rebuilt wholesale — the
          queue is marked degraded, which is the state a resync repairs. *)

(** [degraded] means work was dropped or the log overflowed. Unlike being merely
    behind, patience will not fix it. *)
type stats = {
  queued : int;
  in_flight : int;
  degraded : bool;
  bytes : int64;  (** Total {!Make.keyed} weight still owed; [0L] otherwise. *)
}

(** How a job is written to and read back from disk. A body that no longer
    parses reads as [None]: it is logged and discarded, rather than stalling the
    queue at every start. *)
module type JOB = sig
  type t

  val to_string : t -> string
  val of_string : string -> t option
end

(** Wait for every queue in this process to catch up.

    Stops waiting on a queue that has started failing, and on everything after
    [timeout]: what is left is on disk and resumes on the next start, so holding
    a command open for a store that is down buys nothing. *)
val settle_all : ?timeout:float -> unit -> unit Lwt.t

(** Also wait for this, under the same [timeout]. For background work a queue's
    owner runs beside it without recording: not owed, but still in flight, and a
    caller that has waited for quiet should not have it land afterwards. *)
val register_settle : (unit -> unit Lwt.t) -> unit

module Make (J : JOB) : sig
  (** {1 The records} *)

  module Records : sig
    type t

    (** [dir] should be per target and per domain: the records name one target's
        work, and a shared directory would replay one domain's against
        another's. *)
    val create : dir:string -> t

    val write : t -> id:string -> J.t -> unit Lwt.t

    (** Read, transform, write back. A record that is already gone is not an
        error: whatever owns it may have finished first. *)
    val update : t -> string -> (J.t -> J.t) -> unit Lwt.t

    (** The work is done and the record is no longer owed. *)
    val complete : t -> string -> unit Lwt.t

    (** Everything on disk, in the order it was recorded. *)
    val list : t -> (string * J.t) list Lwt.t
  end

  (** {1 Draining it} *)

  type t

  (** One worker, jobs in the order recorded. A job stays at the head until it
      is taken, so a failure that can clear is waited out rather than losing the
      write and letting what follows overtake it. *)
  val ordered :
    ?max_queued:int ->
    name:string ->
    log:Records.t ->
    poison:poison ->
    run:(J.t -> unit Lwt.t) ->
    unit ->
    t

  (** [workers] jobs at once, at most one per [key]: posting a job whose key is
      already busy cancels the running one and takes its place, so a file
      rewritten while its upload is in flight uploads once, from the newer bytes
      ([run] is handed the flag to poll for that).

      A transient failure requeues at the back rather than the head, holding the
      head being what would stall every other key behind one that is failing;
      [weight] is what {!stats.bytes} sums. *)
  val keyed :
    ?max_queued:int ->
    ?workers:int ->
    ?weight:(J.t -> int64) ->
    name:string ->
    log:Records.t ->
    key:(J.t -> string) ->
    poison:poison ->
    run:(id:string -> J.t -> cancel:bool ref -> unit Lwt.t) ->
    unit ->
    t

  (** Record [job], then queue it. Returns once it is durable, not once it has
      run — that is the point. *)
  val post : ?id:string -> t -> J.t -> unit Lwt.t

  (** Run the workers. [recover] picks up what a previous run left in the log
      first; without it those records are left alone, for a caller that
      reconciles them itself, or so two processes cannot drain one log at once
      and reorder a rename's copy and delete. *)
  val start : ?recover:bool -> t -> unit

  (** Cancel the job running or queued under [key], and drop any replacement
      waiting behind it. [false] when nothing is owed for that key. Only
      meaningful for {!keyed}. *)
  val cancel : t -> string -> bool

  (** Hold the workers without losing what is queued. A stop still drains. *)
  val set_paused : t -> bool -> unit

  val paused : t -> bool

  (** Stop the workers and wait for them, leaving anything unstarted on disk. *)
  val stop : t -> unit Lwt.t

  val stats : t -> stats

  (** Keys running right now, as opposed to merely queued. *)
  val in_flight_keys : t -> string list

  (** Distinct keys still owed, running or queued. *)
  val owed : t -> int
end
