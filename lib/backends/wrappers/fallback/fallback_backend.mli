(** The readable backends composed into one {!Backend.S}, in role order, with
    how far a read may look.

    [sync] is the mains. A write goes there and nowhere else, and returns once
    it has landed — the source of truth. Empty for a read-only domain, where
    every write fails rather than silently landing nowhere.

    [deferred] is the replicas. Read behind the mains, never written here:
    {!Lane_backend} carries them, so a slow or unreachable replica cannot hold
    up a write. A replica holds the same content as the mains eventually, which
    is why a read may fall through to one — and why a definitive "not found"
    from the first reachable backend still ends the read. A read served by a
    replica is behind by whatever its lane still owes.

    [fallbacks] is the read-only stores. They hold different content (an old
    bucket still worth serving, never worth writing), so they are consulted both
    when the source of truth says no and when none of it is reachable.

    When nothing answers, the last error is re-raised rather than reported as a
    miss: an unreachable backend must not reach a caller as a confident ENOENT.
*)

type sub = { name : string; backend : (module Backend.S) }

val make :
  sync:sub list -> deferred:sub list -> fallbacks:sub list -> (module Backend.S)
