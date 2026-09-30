(** The health breaker of a member (spec 01 §8), on the monotonic clock. It
    hears only "lost", "answered" and "probe lost"; which outcomes count is
    failure-model §6. *)

type t

val trip_after : int
val trip_span : float
val hold_initial : float
val hold_max : float
val probe_timeout : float

(** [now] is the clock, replaceable in tests. *)
val create : ?now:(unit -> float) -> string -> t

(** The shared cell of a store that is not a member: never goes out. *)
val always_up : t

val name : t -> string

(** A failure counting against the member. [`Held] means the request was already
    in flight when the member went out, and extends nothing. *)
val lost : ?reason:string -> t -> [ `Up | `Held | `Tripped ]

(** [`Probe] is handed to exactly one caller per lapsed hold. *)
val check : t -> [ `Up | `Held | `Probe ]

(** Out, with the hold still running. *)
val is_held : t -> bool

(** Out, even if the hold lapsed. *)
val is_down : t -> bool

val answered : t -> unit

(** A deliberate probe failed or exceeded {!probe_timeout}. *)
val probe_lost : ?reason:string -> t -> unit

(** One-shot: called at the next trip. *)
val on_trip : t -> (unit -> unit) -> unit

(** The tally of attempts that hit a stall detector. *)
val timed_out : t -> unit

val timeouts : t -> int

(** "held down for Ns after K failures (reason)", while out. *)
val describe : t -> string option

val json : t -> Yojson.Safe.t
