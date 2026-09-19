(** Time, as far as waiting out a failure needs it.

    Apart from {!Io.S} because a pool and an [EINTR] loop need none of it: what
    has to elapse and what a scheduler's own timeout is are questions only
    something that waits on a clock asks. *)

module type S = sig
  type 'a io

  val sleep : float -> unit io

  (** [with_timeout seconds f] runs [f], failing with the scheduler's own
      timeout if it has not finished by then. Racing one against the other is
      what {!Io.S} cannot express. *)
  val with_timeout : float -> (unit -> 'a io) -> 'a io

  (** [with_stall_timeout seconds f] runs [f alive], failing as {!with_timeout}
      does once [seconds] pass without [alive] being called: for work whose
      length is its peer's to choose, where only silence says it is stuck. *)
  val with_stall_timeout : float -> ((unit -> unit) -> 'a io) -> 'a io

  (** The first of these to finish, the rest being cancelled: a request given up
      on is called back rather than left to run. *)
  val pick : 'a io list -> 'a io

  (** Whether [exn] is the scheduler calling work back, which is not something
      that happened to the work. *)
  val is_cancelled : exn -> bool

  (** Whether [exn] is the scheduler's own timeout rather than a failure of the
      work. Only the scheduler that raises it can say. *)
  val is_timeout : exn -> bool
end
