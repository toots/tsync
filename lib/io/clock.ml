(** Time, as far as waiting out a failure needs it.

    Apart from {!Io.S} because a pool and an [EINTR] loop need none of it: what
    has to elapse and what a scheduler's own timeout is are questions only
    something that waits on a clock asks. *)

module type S = sig
  type 'a io

  val sleep : float -> unit io

  (** Whether [exn] is the scheduler's own timeout rather than a failure of the
      work. Only the scheduler that raises it can say. *)
  val is_timeout : exn -> bool
end
