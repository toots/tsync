(** Waiting for what a step expects, not for a length of time.

    A scenario that sleeps, or that waits for a queue to have stopped moving,
    passes on the machine it was written on: a loaded runner takes longer than
    any figure chosen in advance, and a queue that has not started yet looks
    exactly like one that has finished. What a step expects is the one thing
    that says when to stop waiting for it. *)

(** Returns once [expected ()] holds, or after [bound] seconds (thirty) without
    failing: the report that follows then shows what was there instead, and the
    snapshot says so. *)
val reached : ?bound:float -> (unit -> bool) -> unit Lwt.t

(** {!reached}, for a state whose point is that it stays: the expectation has to
    go on holding for a moment after it is met, so work that was held only
    because nobody had got to it yet is given the chance to show itself. *)
val held : ?bound:float -> (unit -> bool) -> unit Lwt.t
