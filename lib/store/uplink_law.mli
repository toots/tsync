(** The control law of one link (spec algorithms/uplink-governor.md §4.4, §4.7):
    a rate that approaches [headroom] of the measured capacity while the
    queueing delay stays near zero. Pure: every call is handed [now]. *)

type settings = {
  headroom : float;
  target_delay : float;  (** seconds *)
  min_rate : float;  (** bytes per second *)
  max_rate : float option;
}

type phase = Ramping | Steady | Backing_off
type limit = Configured | Measured | Estimating

val initial_rate : float
val tick_interval : float
val probe_timeout : float

type t

(** Cold: [initial_rate], ramping with a doubling first step. *)
val create : settings -> now:float -> t

(** §4.7: a law restarted from a saved operating point younger than a day ramps
    back to it at ×1.25; older or absent state starts cold. *)
val restore : settings -> now:float -> capacity:float -> saved_at:float -> t

(** Bytes spread over the whole seconds they took to cross. *)
val completed : t -> now:float -> float -> elapsed:float -> unit

(** A probe's round-trip delay on a path, in seconds. *)
val observe_delay : t -> string -> float -> unit

val timed_out : t -> now:float -> unit

(** One step: [limited] says some party was held back, [busy] that bytes are in
    flight. *)
val tick : t -> now:float -> limited:bool -> busy:bool -> unit

val rate : t -> float
val phase : t -> phase
val capacity : t -> float option
val queueing : t -> float
val achieved : t -> now:float -> float
val limit : t -> limit

(** The least effective baseline across paths, in seconds. *)
val base_delay : t -> float option
