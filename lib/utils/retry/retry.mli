(** Waiting out a failure that will clear on its own.

    The vocabulary every retrying caller shares — what a failure is, whether it
    is worth another attempt, what to say about it in a log line — and the curve
    they all wait on. Callers differ in how patient they are, not in the shape
    of the wait: a request has someone waiting on it, a queue does not.

    A caller that recognises more of its own failures than {!classify} does
    answers first and defers here for the rest. The loop around the wait is its
    own: what a caller does between attempts — give up, poison a record, report
    — is not shared and is not here. *)

(** Whether a failure is worth trying again. A 503, a dropped socket and a full
    disk clear on their own; a 403, a bad key and a read-only target do not, and
    retrying those only delays the report. *)
type kind = Transient | Permanent

exception Failed of { kind : kind; op : string; detail : string }

(** Raised through a retry loop without being retried: the work is no longer
    wanted, so another attempt would be one nobody reads. *)
exception Cancelled

val failed : kind:kind -> op:string -> string -> exn
val string_of_kind : kind -> string

(** [Transient] for anything unrecognised, so a failure mode nobody classified
    is waited out rather than abandoning the work. *)
val classify : exn -> kind

(** What to put in a log line. {!Printexc.to_string} would repeat the operation
    name the caller has already printed. *)
val reason : exn -> string

(** How long to wait before attempt [n] (1-based): [base] doubling to [cap].

    One formula, so the several things that wait out a transient failure differ
    only in how patient they are, not in shape. *)
val backoff : base:float -> cap:float -> int -> float
