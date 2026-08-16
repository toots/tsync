(** Assertions and the shape a test reports them in.

    Every test in this tree answered the same three questions its own way — how
    an assertion prints, whether anything counts them, and whether a failure
    reaches the exit status. A suite that can pass while asserting nothing is
    the failure mode worth designing against, so counting is not optional here
    and {!report} is what a test ends with. *)

(** [why] is called only on failure, for the detail that says what went wrong
    rather than merely that something did. *)
val check : ?why:(unit -> string) -> string -> bool -> unit

(** How many {!check} calls have run, and how many of them failed. *)
val checks : unit -> int

val failures : unit -> int

(** The tally, then [exit 1] if anything failed. [expected] additionally fails
    the run when the number of assertions is not the number the test claims to
    make: a test whose fixture stopped producing work still prints no failures,
    and only a count says so. *)
val report : ?expected:int -> unit -> unit

(** A section heading, and an indented line under one. *)
val case : string -> unit

val step : ('a, out_channel, unit) format -> 'a
