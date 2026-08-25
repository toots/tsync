(** Keeping concurrent work off each other, and waking it when there is
    something to do.

    Apart from {!Io.S} because most things that wait need neither: a pool builds
    its own queue out of {!Io.wait}, and an [EINTR] loop coordinates with
    nobody. What is here is what a queue with a shared log turned out to need.
*)

module type S = sig
  type 'a io
  type mutex
  type condition

  val mutex : unit -> mutex

  (** Run [f] with the mutex held, releasing it however [f] ends. *)
  val with_lock : mutex -> (unit -> 'a io) -> 'a io

  val condition : unit -> condition

  (** Wait until someone {!signal}s or {!broadcast}s. Nothing is carried: a
      waiter re-reads the state it was waiting on. *)
  val wait : condition -> unit io

  (** Wake one waiter; {!broadcast} wakes all of them. *)
  val signal : condition -> unit

  val broadcast : condition -> unit
end
