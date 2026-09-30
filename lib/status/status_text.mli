(** The text rendering of a machine report (spec 07 §5.5). Pure, so it is
    snapshot-tested on fixtures; a clean state prints nothing, and a row
    appearing is the signal. *)

(** [now] (wall seconds) ages the warnings' times. *)
val render : now:float -> Status_report.machine -> string

(** Binary units, one decimal: 1.5 KiB, 3.0 MiB. *)
val size : float -> string

(** 3m 12s, 2h 5m, 4d 3h. *)
val duration : float -> string
