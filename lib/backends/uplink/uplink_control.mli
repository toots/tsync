(** The rate a link is written at, chosen from how long a small request takes to
    be answered.

    A queue building in the modem is the one thing that says the other users of
    a link are being hurt, and no throughput figure can: two megabytes a second
    is all of a small pipe or half of a large one. So the signal is queueing
    delay, a probe's round trip above the least seen lately, and the law is
    LEDBAT's (RFC 6817) in shape: aim for a small delay over the base, grow
    below it, shrink above it, and cut hard on a timeout. On a rate rather than
    a window, and stepped every few seconds rather than every round trip, since
    a probe is noisy and only a trend is worth acting on.

    Two things the plain law would get wrong are handled apart. A polite sender
    never learns the link got faster, so every so often the ceiling is lifted
    and the rate climbs until delay says stop. And what the link can carry is
    not read off a trailing average, which on a ramp still holds the early
    seconds and reads the link far too small: on the way up it is placed between
    the last step that built no queue and the one that did, and in a steady
    state a queue that stays up brings it down to what is completing, since that
    is what another user has left.

    The law alone: delays and completions in, a rate out. What is admitted
    against that rate is an {!Uplink_budget} the caller keeps, since under a
    lease the one law serves several budgets. Pure: every entry point is handed
    the time, and what it decided at an instant is read off it, not waited for.
*)

(** What the config can set. *)
type settings = {
  enabled : bool;
  headroom : float;  (** Fraction of the measured capacity written at. *)
  target_delay : float;  (** Queueing delay aimed for, seconds. *)
  min_rate : int;  (** Bytes per second the rate never drops below. *)
  max_rate : int option;  (** A ceiling whatever the link allows. *)
}

val default_settings : settings

(** {1 The law's constants}

    Settable, so a test need not wait a minute for a probe. *)

(** Bytes per second a cold start begins at, doubling each tick until delay says
    otherwise. *)
val initial_rate : float ref

(** One control step, and one probe round, seconds. *)
val tick_interval : float ref

(** The largest fraction the rate moves in one step while steady. *)
val gain : float ref

(** The smallest multiplier one step applies, and the cut a timeout makes. *)
val decrease_floor : float ref

(** How far back the least delay is remembered, seconds: a route that got
    shorter is believed after this. *)
val base_window : float ref

(** Bytes completed over this many seconds are the achieved rate. *)
val rate_window : float ref

(** Steady this long, and the ceiling is lifted to see whether the link has room
    again. *)
val probe_up_every : float ref

(** After a timeout, no growth for this long. *)
val backoff_hold : float ref

type state =
  | Ramping  (** Growing while delay stays flat; no ceiling but [max_rate]. *)
  | Steady  (** Held at [headroom] of capacity, shrinking as delay rises. *)
  | Backing_off  (** Cut by a timeout, and not growing until the hold ends. *)

val string_of_state : state -> string

type t

val create : ?settings:settings -> now:float -> unit -> t
val settings : t -> settings

(** {1 What happened} *)

(** A body refused on a path that drops rather than waits. *)
val dropped : t -> unit

(** [bytes] were answered, [elapsed] seconds after they were admitted: they
    count toward the rate the link was seen to carry, spread over the seconds
    they took. A body given up on counts toward nothing, and is not reported. *)
val completed : t -> now:float -> bytes:int -> elapsed:float -> unit

(** One probe's round trip, seconds. Several in a tick are read as their least,
    server-side delay being one-sided. *)
val observe_delay : t -> now:float -> float -> unit

(** A request timed out: the rate is cut by {!decrease_floor} and held. *)
val timed_out : t -> now:float -> unit

(** One step of the law. The caller runs it every {!tick_interval}.

    [limited] is whether the rate held the sender back since the last step: a
    body waited or was refused. The rate grows only then, and only while bytes
    are completing, since a body waiting out a debt on an idle link is no reason
    to grant more. A sender with little to send would otherwise see delay stay
    flat and be granted more forever, and meet its first real load with a rate
    that never met any edge, and a capacity read off it. *)
val tick : t -> now:float -> limited:bool -> unit

(** {1 Readers} *)

val rate : t -> float
val state : t -> state

(** Bytes per second the link has for us, as last measured: raised by a ramp
    that met the edge, lowered by a queue that stayed up; [None] until the edge
    has been met once. *)
val capacity : t -> float option

(** The least probe delay in {!base_window}; [None] before any probe. *)
val base_delay : t -> now:float -> float option

(** The smoothed delay above base, seconds. *)
val queueing_delay : t -> float

val drops : t -> int

(** Under the names every report uses. *)
val json : t -> now:float -> (string * Yojson.Safe.t) list
