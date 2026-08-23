(** A domain's stores presented as one {!Backend.S}.

    Three kinds of member, and each answers a different question:

    - [mains] — the source of truth. A write goes here and returns once it has
      landed; the head serves every read.
    - [targets] — copies filled behind the write ({!Deferred}). A read falls
      through to one only if it is {!Deferred.S.readable}, and then only after
      the mains, so a failover read is behind by whatever that target still
      owes.
    - [archives] — read-only stores holding different content: an old bucket
      still worth serving, never worth writing. Consulted both when the source
      of truth says no and when none of it is reachable.

    A domain of archives alone is readable but not writable, which is what makes
    a read-only domain work without a second code path.

    When nothing answers, the last error is re-raised: swallowing it into [None]
    would hand a caller a confident ENOENT from an unreachable store. *)

type sub = { name : string; backend : (module Backend.S) }

(** A target is given the store to catch up from — the mains alone, see
    {!Deferred.make} — supplied here rather than by the caller, since only this
    module knows which members are authoritative.

    Whether reads may reach the resulting target is the caller's to say, through
    {!Deferred.make}'s [reads_reach]. *)
val make :
  mains:sub list ->
  targets:(source:(module Backend.S) -> (module Deferred.S)) list ->
  archives:sub list ->
  (module Backend.S)

(** Wait for every deferred target in this process to catch up. Registered with
    {!Backend.on_drain} by {!make}, so callers normally reach it through
    [Backend.drain]; exposed for tests that assert on what a target holds. *)
val drain : unit -> unit Lwt.t
