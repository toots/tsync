(** Bytes the run expects to handle, as a plan hands them over whole.

    Counts of files cannot answer how far along a command is: six thousand files
    is not a size, and the file a run has been on for two hours is not a
    fraction. A command records what it handles through the calls here and
    {!Job_report} samples them, so the rate and the estimate are derived in one
    place however many commands come to want them. Recording works before a
    report is started and with no daemon to send one to, and a command that
    counts entries rather than bytes records nothing and reports no progress at
    all. *)
val plan : bytes:int64 -> unit

(** An entry is picked up, at the size the plan counted it as. *)
val start_entry : size:int64 -> unit

(** Another [bytes] of the entry in flight are done, [sent] saying whether they
    reached a store or were already there. Ignored between entries. *)
val advance : bytes:int64 -> sent:bool -> unit

(** The entry in flight is finished, its bytes routed by what became of it.
    [`Done] carries the size actually handled, which is not always the size
    planned for.

    Only [`Done] bytes are throughput: an entry needing no work finishes at once
    and would otherwise report a rate nothing can sustain. *)
val finish_entry : [ `Done of int64 | `Skipped | `Failed ] -> unit

(** What {!Job_report} puts in its payload, empty where nothing was recorded.
    Absent figures are absent keys: an unknown estimate is not zero seconds, and
    no entry in flight is not an empty one.

    [bytesDone] counts the entry in flight, and [bytesHandled] counts everything
    behind the run whatever became of it — which is what a fraction of the plan
    means, a resumed import being most of the way through its tree with nothing
    uploaded.

    [bytesPerSecAvg] is [bytesSent] over the time since the first byte was sent,
    and [etaSeconds] follows from it. Deliberately not [bytesDone] over the
    whole run: a resumed import opens by finding files and chunks it already
    has, and dividing by that answers with a rate no transfer ran at — the
    estimate would promise hours for work that has not started. A rolling window
    is not it either, since an estimate divided by the last few seconds swings
    by hours between reports and the report's [traffic] figures are already
    rolling.

    So a run that sends nothing shows no estimate: what it is doing costs
    hashing rather than transfer, and there is no throughput to extrapolate. *)
val json : unit -> (string * Yojson.Safe.t) list
