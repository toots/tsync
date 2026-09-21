(** Waiting out a failure that will clear on its own.

    The vocabulary every retrying caller shares — what a failure is, whether it
    is worth another attempt, what to say about it in a log line — and the curve
    they all wait on. Callers differ in how patient they are, not in the shape
    of the wait: a request has someone waiting on it, a queue does not.

    A caller that recognises more of its own failures than {!classify} does
    answers first and defers here for the rest. The loop around the wait is its
    own: what a caller does between attempts — give up, poison a record, report
    — is not shared and is not here. *)

include module type of struct
  include Retry_intf
end

val failed : kind:kind -> op:string -> string -> exn
val string_of_kind : kind -> string

(** [Transient] for anything unrecognised, so a failure mode nobody classified
    is waited out rather than abandoning the work. *)
val classify : exn -> kind

(** {!classify} for work done in order, where a failure that will not clear
    holds up everything behind it. A request's failure leaves {!LOOP.with_retry}
    as {!Failed}, saying whether the link caused it; anything else was raised on
    this side of the link, and is [Permanent]. *)
val classify_in_order : exn -> kind

(** What to put in a log line. {!Printexc.to_string} would repeat the operation
    name the caller has already printed. *)
val reason : exn -> string

(** How long to wait before attempt [n] (1-based): [base] doubling to [cap].

    One formula, so the several things that wait out a transient failure differ
    only in how patient they are, not in shape. *)
val backoff : base:float -> cap:float -> int -> float

(** The failure of a request not made, its member being held down: transient,
    and a {!Failed}, so a queue behind it keeps what it was asked to do. *)
val held : name:string -> op:string -> Health.t -> exn

module Make (Io : Io.S) (Clock : Clock.S with type 'a io := 'a Io.t) :
  LOOP with type 'a io := 'a Io.t
