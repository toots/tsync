(** Commands running beside the daemon, as they last described themselves.

    A one-shot command pushes a report on a timer (see [Job_report]); this keeps
    the latest one per process so [tsync status] can list what is running.
    Advisory: a job that never reports is absent rather than missing, and a row
    is dropped once its process is gone or has stopped reporting.

    [record] keeps the latest report for the reporting pid, replacing any
    earlier one, and ignores a report naming no pid. *)
val record : Yojson.Safe.t -> unit

(** Jobs still worth showing, oldest first. Finished ones linger briefly; dead
    and silent ones are dropped here rather than by a caller. *)
val live : unit -> Yojson.Safe.t list

(** Empties the table, for a test that needs a known starting point. *)
val forget_all : unit -> unit
