(** Commands running beside the daemon, as they last described themselves.

    A one-shot command pushes a report on a timer (see [Job_report]); this keeps
    the latest one per process so [tsync status] can list what is running.
    Advisory: a job that never reports is absent rather than missing, and a row
    is dropped once its process is gone or has stopped reporting.

    [record] keeps the latest report for the reporting pid, replacing any
    earlier one, and ignores a report naming no pid. The fields it decides with
    are passed apart from the payload, which it only stores: what a row means is
    this module's, and what a reader is shown is the sender's. *)
val record :
  pid:int ->
  started:float ->
  interval:float ->
  finished:bool ->
  Yojson.Safe.t ->
  unit

(** Jobs still worth showing, oldest first. Finished ones linger briefly; dead
    and silent ones are dropped here rather than by a caller. *)
val live : unit -> Yojson.Safe.t list
