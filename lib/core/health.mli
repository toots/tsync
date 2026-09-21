(** Whether a member is worth asking right now.

    A member whose link is gone fails every request the same way, and the retry
    ladder under it is built for a blip: eight attempts against a host that is
    not there is a minute of a reader's time spent reaching the answer the first
    attempt gave. So failures are remembered per member, a couple in a row take
    it out of the rotation, and one request at a time is spent finding out
    whether it came back. *)

type t

(** The cell of a store with no link to lose: never held, whatever it is told,
    and with nothing to say in a report. *)
val always_up : t

val create : unit -> t

(** Failures in a row, with no answer between them, that take a member out, once
    they have gone on for {!trip_span}: eight requests refused in the same
    instant are one bad moment, and a member that has refused everything for a
    second is down. *)
val trip_after : int ref

val trip_span : float ref

(** How long it stays out, doubling up to {!hold_max} each time the request
    spent on finding out fails too. *)
val hold_initial : float ref

val hold_max : float ref

(** How long a caller probing a member on purpose waits for it. *)
val probe_timeout : float ref

(** For whoever could ask another member instead. [`Probe] is handed to one
    caller per hold, and taking it pushes the hold out, so a probe that never
    reports back is tried again at the next expiry instead of leaving the member
    out for good. Whoever has nowhere else to go does not ask: a held member is
    still the only one there is. *)
val check : t -> [ `Up | `Probe | `Held ]

(** For whoever is choosing between members and asking none yet: false once a
    probe is due, so the one that would make it is let through. *)
val is_held : t -> bool

(** Out since it tripped and not heard from since, whether or not the hold has
    run out: for whoever must not act as though it were there, and has to go and
    look instead of taking an expired hold for an answer. *)
val is_down : t -> bool

(** Whether this process has heard from the member at all, either way. A command
    that has just started has not, and has to look before it concludes. *)
val sampled : t -> bool

(** The member answered, a refusal or a miss included: an answer about an object
    says the link is there. *)
val answered : t -> unit

(** A failure that may clear on its own, with why. [`Tripped] is the report that
    took the member out, or the probe's that kept it out, and is the one worth a
    line in a log; [`Held] is a request that was already on its way. *)
val lost : t -> string -> [ `Up | `Tripped | `Held ]

(** A probe made on purpose and lost: the member is out on this answer alone. A
    run of failures is what a request that was going there anyway has to add up
    to, and a deadline cancelling the request under it leaves {!lost} nothing to
    be told at all. *)
val probe_lost : t -> string -> unit

(** Called once, the next time the member goes or stays out: for whoever is
    waiting on it with somewhere else to go. {!off} withdraws it. *)
val on_held : t -> (unit -> unit) -> int

val off : t -> int -> unit

(** ["held down for 27s after 2 failures (HTTP 530: …)"], or [""] when not. *)
val describe : t -> string

(** For a report, empty unless held. The wall-clock string is made here, so what
    renders it does not have to know the zone. *)
val json : t -> (string * Yojson.Safe.t) list

(** {1 For tests, which must not sleep a hold out} *)

(** As though the hold had just run out. *)
val expire : t -> unit

(** The hold the cell last chose, which is what doubling is read off. *)
val hold_length : t -> float
