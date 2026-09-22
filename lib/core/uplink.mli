(** Admission to a link: the gate a store's writes go through.

    A store asks before each body it sends and says how it went after. What
    it asks is a record of closures rather than a module, so a store built once
    can be handed whichever gate its config names, and a gate answering for
    one store can later be swapped for one answering to a daemon without the
    store changing. Upload only: a read is the caller waiting, and is not made
    to wait longer here.

    Two gates. {!Make.capped} is a ceiling on one store, a budget of its own.
    The process governor, {!Make.process}, is one {!Uplink_control} for every
    store in the process, stepped by a ticker and fed by probes: the one link
    the process has, written at the rate the law chooses. *)

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

  (** [compose first second] asks [first] and then [second], and tells both:
      a store's own ceiling in front of the process governor. *)
  val compose :
    unit Io.t admission -> unit Io.t admission -> unit Io.t admission

  (** {1 The process governor} *)

  (** Who is asking. [Background] takes from the budget; [Foreground] is a
      user waiting, and passes. Upload only today, so every store is
      [Background]; the class is here so a download path can say otherwise
      without the interface changing. *)
  type class_ = Background | Foreground

  type t

  val create : ?settings:Uplink_control.settings -> unit -> t

  (** Applied once per process, before the first store is built. A later
      call is a no-op: a process opening a second domain has one link. *)
  val configure : Uplink_control.settings -> unit

  (** The one governor every store in the process shares. Made with the
      defaults if nothing configured it. *)
  val process : unit -> t

  val enabled : t -> bool
  val control : t -> Uplink_control.t

  (** Waits for room, in order; a body of at most {!small_body} bytes passes
      ahead when the budget covers it. Returns at once when disabled or
      [Foreground]. Starts the ticker on first use. *)
  val acquire : t -> class_:class_ -> bytes:int -> unit Io.t

  (** The drop path's question: room now, or not at all; a [false] is a drop
      and charges nothing. A [true] holds only until this turn yields: the
      caller's {!acquire} that follows takes the room synchronously, with no
      bind between, which is what {!Deferred} relies on. Always [true] when
      disabled. *)
  val try_admit : t -> bytes:int -> bool

  (** What a store hands {!Backend.Make.make}: this governor, asked as
      [class_]. *)
  val admission : t -> class_ -> unit Io.t admission

  (** A store with governed bytes crossing the link, and how to time one small
      round trip to it. Probed every tick while the governor has bytes in
      flight and the store is not [held]; never when idle, since a probe is a
      billed request. *)
  val attach :
    t -> name:string -> held:(unit -> bool) -> probe:(unit -> unit Io.t) -> unit

  val waiting : t -> int
  val json : t -> (string * Yojson.Safe.t) list
end
