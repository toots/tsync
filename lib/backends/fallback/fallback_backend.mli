(** The readable backends composed into one {!Backend.S}, in role order, with
    how far a read may look.

    [writable] is the mains followed by the replicas. Every write fans out over
    all of them, so they hold the same content and any reachable one speaks for
    the source of truth — which is why a definitive "not found" from the first
    reachable one ends the read. Empty for a read-only domain, where every write
    fails rather than silently landing nowhere.

    [fallbacks] is the read-only stores. They hold different content (an old
    bucket still worth serving, never worth writing), so they are consulted both
    when the source of truth says no and when none of it is reachable.

    When nothing answers, the last error is re-raised rather than reported as a
    miss: an unreachable backend must not reach a caller as a confident ENOENT.
*)

type sub = { name : string; backend : (module Backend.S) }

val make : writable:sub list -> fallbacks:sub list -> (module Backend.S)
