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

(** Another [bytes] of the entry in flight are done. Ignored between entries. *)
val advance : bytes:int64 -> unit

(** The entry in flight is finished, its bytes routed by what became of it.
    [`Done] carries the size actually handled, which is not always the size
    planned for.

    Only [`Done] bytes feed the rate: an entry needing no work finishes at once
    and would otherwise report a throughput nothing can sustain. *)
val finish_entry : [ `Done of int64 | `Skipped | `Failed ] -> unit

(** What {!Job_report} puts in its payload, empty where nothing was recorded.
    Absent figures are absent keys: an unknown estimate is not zero seconds, and
    no entry in flight is not an empty one. *)
val json : unit -> (string * Yojson.Safe.t) list
