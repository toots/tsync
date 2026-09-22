(** The lessees of a link's owner: who holds a share of it, what each last
    said, and how the rate the law chose is split among them.

    A lessee renews every {!Uplink_control.tick_interval}, reporting what it
    has in flight, what completed and what timed out since it last renewed,
    and how many bodies wait behind its line; it is granted a rate in reply.
    The owner's own writes are a lessee too, in the same table under the same
    rule, so one implementation admits everyone. One silent for three
    intervals is gone: the {!Job_registry} rule, and the same reason.

    The split is max-min fair over what each lessee can use. A lessee with a
    line behind it wants all it can get; one moving bytes but with nothing
    waiting is using what it has, and is given a little over that and no
    more, since more would sit idle; one moving nothing holds the floor, so
    its first body is admitted at once. What is left over is handed out
    evenly regardless: it costs nothing to grant, and a lessee that wakes
    bursts into it.

    Pure: every entry point is handed the time. *)

(** What a lessee says when it renews. Deltas since its last renewal, except
    [in_flight] and [waiting], which are what is true now. *)
type report = { in_flight : int; completed : int; timeouts : int; waiting : int }

val idle : report

(** Read off a request's fields; a field absent is nothing. *)
val report_of_json : (string * Yojson.Safe.t) list -> report

type t

val create : unit -> t

(** Seconds between renewals, told to each lessee in its reply. *)
val interval : unit -> float

(** A renewal from [pid]. What it reports is kept for the next {!split} and
    summed for the next {!drain}. *)
val record : t -> now:float -> pid:int -> report -> unit

(** Lessees heard from within three intervals, with what they last said. *)
val live : t -> now:float -> (int * report) list

(** Bytes in flight across live lessees. *)
val in_flight : t -> now:float -> int

(** Completed bytes and timeouts reported since the last call, across every
    lessee, and zeroed: what the law is fed once a tick. *)
val drain : t -> int * int

(** Split [total] bytes per second between the owner's own writes, described
    by [self], and the live lessees; each is granted at least [min_rate].
    Remembered, so {!rate_for} answers with it until the next split. *)
val split : t -> now:float -> total:float -> min_rate:float -> self:report -> unit

(** The owner's own grant from the last {!split}, or [total] before any. *)
val own_rate : t -> float

(** [pid]'s grant from the last {!split}. A lessee not in that split, having
    renewed for the first time since, is granted an even share of the last
    total at once: a job started beside a daemon does not start cold. *)
val rate_for : t -> now:float -> pid:int -> float

(** Every live lessee as a report shows it: [pid], [rateBytesPerSec],
    [inFlightBytes], [waiting]. *)
val json : t -> now:float -> Yojson.Safe.t list
