(** One store's bucket-side function as this machine knows it
    (object-store-common §3): the saved confirmation and the probe in flight. *)

type t

(** The confirmation is saved at [path]. *)
val open_ : path:string -> t

(** A confirmation younger than FUNCTION_PROBE_VALIDITY (7 days). *)
val confirmed : ?now:float -> t -> bool

val confirmed_at : t -> float option

(** Unconfirmed, or confirmed for less than another day: probed again before the
    confirmation lapses. *)
val due : t -> bool

(** Runs [check] and saves a confirmation when it answers [true]. Every probe
    writes the same request, so one asked for while another runs waits for that
    one's answer instead. *)
val probe : t -> (unit -> bool) -> bool
