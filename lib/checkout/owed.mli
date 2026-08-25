(** A hand-off between something that produces work and something that performs
    it, when the two are not in step. *)

module Make (Lock : Lock.S with type 'a io := 'a Lwt.t) : sig
  type 'a t

  val create : unit -> 'a t

  (** Hand one over. Never blocks, and never drops what it is told: something
      signalled while nobody waits is delivered to whoever waits next. *)
  val signal : 'a t -> 'a -> unit

  (** The next one, waiting until there is one. In the order they were
      signalled. *)
  val next : 'a t -> 'a Lwt.t

  (** How many are waiting to be taken up. *)
  val pending : 'a t -> int
end
