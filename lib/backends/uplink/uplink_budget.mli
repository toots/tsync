(** What may be written to a link right now, at a rate.

    Two bounds, both in bytes. A bucket refilled at the rate and drawn on by
    each body admitted, so the long run holds the rate whatever the bodies'
    sizes: one larger than the bucket is admitted once the bucket is full and
    leaves it owing, and the next waits that debt out. And a window on what is
    in flight, against the stall timeout: a body is sent whole and unheard
    ({!Http_client_intf}), and one admitted behind others crosses the link only
    after them, so past the window it would be given up on before it arrived.

    One body is always admitted when nothing is in flight, however large. It
    goes alone at link speed, which is what it did before there was a budget,
    and nothing can wait on a window it can never fit.

    Pure: every entry point is handed the time, which is what lets a test read a
    decision without waiting for it. *)

(** The shortest stall any driver allows a request, in seconds; a body has to
    cross inside it. Defined here and read by the driver rather than the other
    way round, so the window and the deadline it guards cannot drift apart.
    Sixty seconds against a link that answers in 150 ms and would take about
    eight for a chunk at its worst observed rate: past the first retry a
    connection that has gone is already gone, and waiting longer buys nothing.
*)
val stall_timeout : float ref

(** The fraction of {!stall_timeout} the in-flight window fills. The rest is for
    a rate misjudged and for the store's own time with a body. *)
val window_safety : float ref

(** Depth of the bucket, in seconds of rate: a burst up to this is admitted at
    once, and a fresh bucket starts full. *)
val burst_seconds : float ref

type t

(** [rate] in bytes per second; below one byte per second is read as one. *)
val create : now:float -> rate:float -> t

(** What was earned at the old rate up to [now] is kept, then the new rate
    applies, to the refill and to the window both. *)
val set_rate : t -> now:float -> float -> unit

val rate : t -> float

(** Bytes the bucket holds; negative while a body larger than it is being paid
    off. *)
val tokens : t -> now:float -> float

val in_flight_bytes : t -> int

(** Bytes the window admits in flight at the current rate. *)
val window_bytes : t -> int

(** Whether [bytes] would be admitted now. Pure, and the fast path is
    synchronous: a caller that asks and then {!take}s does both in one turn. *)
val admits : t -> now:float -> bytes:int -> bool

(** Charge [bytes]: the bucket goes down, the window fills. *)
val take : t -> now:float -> bytes:int -> unit

(** [bytes] have left the link, however that ended. *)
val release : t -> bytes:int -> unit

(** Seconds until refill alone would admit [bytes]: [0.] now, [infinity] when
    only a {!release} could make room. *)
val wait_for : t -> now:float -> bytes:int -> float
