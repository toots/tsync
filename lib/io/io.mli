(** The concurrency a module needs before it can wait for anything.

    Small on purpose: what is here is what the modules beside it turned out to
    use, not what a scheduler offers. A filesystem is not here — waiting and
    reading a disk are different questions, and something that only needs to
    queue work should not have to be handed a disk to get it. *)

module type S = sig
  type 'a t

  (** The other end of a {!wait}: what makes an unfinished [t] finish. A pool
      hands one to whoever must release the slot, which is the whole of how a
      waiter is woken. *)
  type 'a u

  val return : 'a -> 'a t
  val bind : 'a t -> ('a -> 'b t) -> 'b t
  val map : ('a -> 'b) -> 'a t -> 'b t

  (** [catch f handler] runs [f], passing anything it raises to [handler]. *)
  val catch : (unit -> 'a t) -> (exn -> 'a t) -> 'a t

  (** [finalize f after] runs [after] whether or not [f] raised, and re-raises
      afterwards. *)
  val finalize : (unit -> 'a t) -> (unit -> unit t) -> 'a t

  val fail : exn -> 'a t

  (** A [t] that finishes when its resolver is used, and the resolver. *)
  val wait : unit -> 'a t * 'a u

  val wakeup_later : 'a u -> 'a -> unit

  (** These three run their arguments at once rather than in turn, which no
      amount of {!bind} expresses. *)
  val join : unit t list -> unit t

  val map_p : ('a -> 'b t) -> 'a list -> 'b list t
  val iter_p : ('a -> unit t) -> 'a list -> unit t
end
