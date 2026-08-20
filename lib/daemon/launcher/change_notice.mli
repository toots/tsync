(** Telling a domain's frontends what the poller applied.

    The process that converges a domain is not the one presenting it, so a
    foreign rename reaches a mount over the same socket everything else does.
    Advisory on the terms {!Job_report} uses: a frontend that misses a notice is
    stale until its next lookup rather than wrong, a frontend that is down is
    the ordinary case, and no failure here reaches the caller.

    Batched on a short timer. A replay is as long as what other clients did, and
    one round trip per key would make a catch-up of a hundred thousand entries a
    hundred thousand of them. *)

(** Note that [key] changed, for delivery to [sockets]. Returns at once; the
    send happens on the next flush. Fire-and-forget, so this is what a
    {!Domain_engine.Converging} passes as [on_changed]. *)
val send : domain:string -> sockets:string list -> string -> unit
