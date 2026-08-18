(** Bytes the run expects to handle, as a plan hands them over whole.

    Counts of files cannot answer how far along a command is: six thousand files
    is not a size, and the file a run has been on for two hours is not a
    fraction. A command records what it handles through the calls here and
    {!Job_report} samples them, so the rate and the estimate are derived in one
    place however many commands come to want them. Recording works before a
    report is started and with no daemon to send one to, and a command that
    counts entries rather than bytes records nothing and reports no progress at
    all.

    [basis] is which figure the estimate extrapolates from: [`Sent] for a
    transfer, [`Handled] for a run whose entries are mostly in place already and
    which therefore has no throughput to divide by — see {!json}. *)
val plan : basis:[ `Sent | `Handled ] -> bytes:int64 -> unit

(** An entry is picked up, at the size the plan counted it as. *)
val start_entry : size:int64 -> unit

(** Another [bytes] of the entry in flight are done, [sent] saying whether they
    reached a store or were already there. Ignored between entries. *)
val advance : bytes:int64 -> sent:bool -> unit

(** An entry a run is done with, [bytes] of the plan behind it and [sent] of
    them having reached a store.

    For a run holding several entries at once, where {!start_entry} would name
    whichever of them started last and {!finish_entry} would charge its size to
    that one. A mirror examines objects by the dozen. *)
val settle : bytes:int64 -> sent:int64 -> [ `Done | `Skipped | `Failed ] -> unit

(** {!settle} for the entry in flight, its bytes routed by what became of it.
    [`Done] carries the size actually handled, which is not always the size
    planned for.

    [`Skipped] is behind the run without being throughput: an entry needing no
    work finishes at once, and a [`Sent] estimate counting it would report a
    rate nothing can sustain. *)
val finish_entry : [ `Done of int64 | `Skipped | `Failed ] -> unit

(** What {!Job_report} puts in its payload, empty where nothing was recorded.
    Absent figures are absent keys: an unknown estimate is not zero seconds, and
    no entry in flight is not an empty one.

    [bytesDone] counts the entry in flight, and [bytesHandled] counts everything
    behind the run whatever became of it — which is what a fraction of the plan
    means, a resumed import being most of the way through its tree with nothing
    uploaded.

    [bytesPerSecAvg] is what the run's [basis] got through over the time it has
    been getting through it, [ratedOn] names which of the two it is, and
    [etaSeconds] is [bytesRemaining] at that rate. A rolling window is not it,
    since an estimate divided by the last few seconds swings by hours between
    reports and the report's [traffic] figures are already rolling.

    Under [`Sent] that is bytes that reached a store, timed from the first of
    them, and deliberately not [bytesDone] over the whole run: a resumed import
    opens by finding files and chunks it already has, and dividing by that
    answers with a rate no transfer ran at — the estimate would promise hours
    for work that has not started. So a [`Sent] run that sends nothing shows no
    estimate at all: what it is doing costs hashing rather than transfer.

    Under [`Handled] it is the plan itself over the time since {!plan}, which is
    what a run examining what a store already holds is spending its time on —
    round trips, not bytes. A mirror mostly finds objects in place, and an
    estimate against what it happened to copy would answer with hours of
    transfer for a run that has minutes of checking left. *)
val json : unit -> (string * Yojson.Safe.t) list
