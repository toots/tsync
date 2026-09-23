(** A stop this process was asked for, which work in progress gives way to.

    Everything a stop leaves undone is on disk: an upload's record, a replica's
    job, a staged body. So a stop does not wait work out. A backoff in progress
    ends, a retry ladder is not climbed further, an upload goes no further than
    the chunk it is sending, and each fails with {!Stopping}: never retried,
    never counted as a failure, and never taken to mean the work is no longer
    owed, which is what [Retry.Cancelled] means. *)

exception Stopping

(** Idempotent. Runs every hook registered with {!on_request}, once. *)
val request : unit -> unit

val requested : unit -> bool

(** Call [f] when a stop is requested, at once if one already was. The result
    unregisters it. *)
val on_request : (unit -> unit) -> unit -> unit

(** Seconds a stop may take before what is still running is left to the next
    start. Settable so a test need not wait it out. *)
val grace : float ref

(** Forget a request, for a test that stops more than once. *)
val reset : unit -> unit

module Sleep (Io : Io.S) (Clock : Clock.S with type 'a io := 'a Io.t) : sig
  (** [`Slept] after [seconds], or [`Stopping] as soon as a stop is requested,
      at once if one already was. *)
  val sleep : float -> [ `Slept | `Stopping ] Io.t
end
