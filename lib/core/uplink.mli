(** Admission to a link: the gate a store's writes go through.

    A store asks before each body it sends and says how it went after. What
    it asks is a record of closures rather than a module, so a store built once
    can be handed whichever gate its config names, and a gate answering for
    one store can later be swapped for one answering to a daemon without the
    store changing. Upload only: a read is the caller waiting, and is not made
    to wait longer here. *)

type 'io admission = {
  acquire : bytes:int -> 'io;  (** Returns once [bytes] may be sent. *)
  completed : bytes:int -> elapsed:float -> unit;
      (** [bytes] were answered, [elapsed] seconds after [acquire] returned. *)
  abandoned : bytes:int -> unit;
      (** [bytes] were given up on, however that happened: they have left the
          link. *)
  now : unit -> float;
      (** The clock [elapsed] is read off, so a store need not hold one. *)
  waiting : unit -> int;  (** Bodies queued behind the gate right now. *)
}

(** A body of at most this many bytes may pass ahead of what is queued, when
    the budget covers it: a cursor or a journal entry should not sit behind a
    chunk. Bounded, so a run of them cannot keep a chunk waiting for long. *)
val small_body : int ref

module Make (Io : Io.S) (Clock : Clock.S with type 'a io := 'a Io.t) : sig
  (** Admits everything at once: a store with no ceiling. *)
  val unbounded : unit Io.t admission

  (** A ceiling of [rate] bytes per second on one store, over its own
      {!Uplink_budget}. Waiters are served in order, each woken the moment the
      budget next allows it, whether by refill or by a body leaving the link;
      a body larger than the bucket goes alone and is paid off before the
      next, as the budget says. *)
  val capped : rate:float -> unit Io.t admission
end
