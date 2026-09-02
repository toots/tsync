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

(** What the composite needs of the layer below: the settling every deferred
    target registers with, the batched reads a fan-out goes through, and the
    hook a process about to exit waits on. *)
module type DRAIN = sig
  type 'a io

  val on_drain : (unit -> unit io) -> unit
end

module Over
    (Io : Io.S)
    (Queues : Deferred.QUEUES with type 'a io := 'a Io.t)
    (Lock : Lock.S with type 'a io := 'a Io.t)
    (_ : DRAIN with type 'a io := 'a Io.t)
    (_ : sig
      type slots

      module Batched (_ : Backend.S with type 'a io := 'a Io.t) : sig
        val get_many :
          ?slots:slots ->
          entries:Backend.file_entry list ->
          unit ->
          (Stored_key.t * Bigstring.t option) list Io.t
      end
    end) : sig
  module Dt : module type of Deferred.Over (Io) (Queues) (Lock)

  module type Store = Backend.S with type 'a io := 'a Io.t

  type sub = { name : string; backend : (module Store) }

  (** A target is given the store to catch up from — the mains alone, see
      {!Deferred.make} — supplied here rather than by the caller, since only
      this module knows which members are authoritative.

      Whether reads may reach the resulting target is the caller's to say,
      through {!Deferred.make}'s [reads_reach]. *)
  val make :
    mains:sub list ->
    targets:(source:(module Store) -> (module Dt.S)) list ->
    archives:sub list ->
    (module Store)

  (** Wait for every deferred target in this process to catch up. Registered
      with {!Drain.on_drain} by {!make}, so callers normally reach it through
      [Backend_lwt.drain]; exposed for tests that assert on what a target holds.
  *)
  val drain : unit -> unit Io.t
end
