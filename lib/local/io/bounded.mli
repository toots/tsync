(** A ceiling on how much of something runs at once.

    A pool stands for a resource, not for a piece of work: the width belongs to
    whoever knows what shares the process, and the code inside only asks. *)

(** Raised by {!Make.use} when the pool is full and its queue is capped. *)
exception Busy

module type S = Bounded_intf.S

module Make (Io : Io.S) : S with type 'a io := 'a Io.t
