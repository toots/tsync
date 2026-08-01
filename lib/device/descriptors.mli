(** How many files this process may hold open.

    A companion to {!Device}: both are ceilings the platform imposes rather than
    anything tsync chooses, and both have to be discovered at runtime instead of
    assumed. *)

(** The soft limit in force, or [None] where the platform will not say. *)
val current : unit -> int option

(** [raise_to ~target] raises this process's soft limit toward [target] and
    returns what is now in force. Never lowers it.

    A process may raise its own soft limit up to the hard one without privilege,
    which is what makes this worth doing at start-up: launchd hands the macOS
    daemon 256 descriptors against an unlimited hard limit, low enough that a
    burst of concurrent work fails [accept] with [EMFILE]. Descriptors are
    allocated on use, so asking for more costs nothing.

    [target] is a request: the real per-process cap is not visible in the hard
    limit on every platform, so an over-large ask is stepped down until the
    kernel accepts one. This removes an arbitrary ceiling; holding too many open
    is {!Lwt_bounded}'s problem. *)
val raise_to : target:int -> int
