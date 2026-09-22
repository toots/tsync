(** A clock a test turns by hand.

    Anything built over {!Tsync_io.Clock.S} can be run against this instead of
    the scheduler's clock: time passes only when the test says so, a sleep
    resolves the moment its deadline is reached and not before, and what a
    controller decided at a given instant can be read without waiting that
    instant out. The first such double in the tree; the modules it stands in
    for are functors over the signature, so nothing changes to accept it.

    One clock per process, since a test is one process: state is at module
    level, and {!reset} puts it back for a case that wants a fresh origin. *)

include Tsync_io.Clock.S with type 'a io := 'a Lwt.t

(** Move the clock forward by [seconds] and wake every sleep whose deadline
    has passed, earliest first. The wakers run on the next scheduler turn, so
    a test pauses ({!Lwt.pause}) once or twice before reading what they did. *)
val advance : float -> unit

(** Sleeps still waiting for their deadline. A sleep cancelled by
    [with_timeout] or [pick] is no longer counted. *)
val pending : unit -> int

(** Back to zero, with no sleepers. *)
val reset : unit -> unit
