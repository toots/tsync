(** The text rendering of a machine report (spec 07 §5.5). Pure, so it is
    snapshot-tested on fixtures; a clean state prints nothing, and a row
    appearing is the signal. *)

(** [now] (wall seconds) ages the warnings' times. *)
val render : now:float -> Status_report.machine -> string
