(** Collect chunks nothing references any more.

    {!Expire} drops the references — old versions, trashed folders, journal
    entries. What it leaves behind is chunks no manifest and no surviving version
    points at, and this reclaims them. Run one then the other; neither does the
    other's job.

    {b How it works.} A run moves the chunk root aside to [chunks.from/] and lets
    the live set accumulate under [chunks/], the name every writer already uses.
    Marking gives each chunk a live root names a second hard link under the new
    root, so nothing is copied and nothing is deleted; closing discards
    [chunks.from/], and the inodes that never earned a link go with it. Reclaiming
    is therefore the link count's doing, not a delete's.

    Writes need no cooperation, which is the point of collecting in this
    direction: a client that has never heard of a run still writes to [chunks/],
    the space that survives. The one thing a writer must do is
    {!Chunk_space.promote_all} before publishing a manifest, which
    {!Remote.publish} does.

    {b Where it runs.} Only on a main that answers {!Backend.caps.gc} — a
    filesystem, because a rename and a link within the store are what the whole
    scheme rests on. An object store gets neither, so an s3, gcs or http-proxy
    main is refused rather than half-served.

    {b The copies.} Replicas and backfill targets are never renamed. Once the main
    has settled, each is walked shard by shard — the target's own shards, since
    only it knows what it holds, and a shard the main never had is exactly where
    its orphans hide — and whatever the main no longer has is deleted. A replica is
    additionally filled where it falls short, being meant to be a complete copy; a
    backfill target is not, being incomplete by design and having its own queue for
    that. So a remote store sees deletes and puts, never a rename, and can sit on a
    storage class where renaming would be absurd.

    {b Pace.} Driven a step at a time rather than as one long call, because this
    is maintenance on a live filesystem and it should be possible to run it
    without taking the machine over. A caller decides how much to do and how long
    to wait in between; {!run} is the impatient version of that loop. A run left
    open between steps — or between whole invocations — is safe indefinitely:
    reads look in both spaces and writes were never redirected.

    {b Scale.} The surviving root {i is} the record of what has been marked, so
    nothing is held in memory and no live set is written down. A run is
    interrupted at a root or shard boundary and continues where it left off, which
    is what makes a multi-terabyte store a matter of several sittings. *)

type outcome =
  | Completed
  | Suspended of { phase : string; cursor : string }
      (** Stopped at a boundary with the run still open. The next call continues
          from [cursor]. *)

(** What reconciling one copy came to. [uploaded] is always zero for a backfill
    target: being incomplete is its normal condition, so a gap there says nothing
    and is left to its own queue. A replica is meant to be a full copy, so a gap
    there is drift and gets filled. *)
type member_stats = { name : string; deleted : int; uploaded : int }

type stats = {
  outcome : outcome;
  roots_marked : int;
  chunks_promoted : int;
  chunks_reclaimed : int;
  bytes_reclaimed : int;
  members : member_stats list;
      (** One entry per replica or backfill target that needed anything, in
          configuration order. *)
}

(** No main can collect: every one is an object store, or there is none. Carries
    a sentence for the user. *)
exception Unsupported of string

(** Something else is already stepping a run. Two collectors on one run lose
    chunks — they resume from the same cursor, so their root lists partition, and
    whichever finishes its share first starts discarding the old space while the
    other still has roots nothing has promoted. Carries a sentence for the user.

    Exclusion is a lock file on the main, so the kernel releases it if the holder
    dies: a crashed collection leaves a run that resumes, never a run nobody may
    touch. *)
exception Busy of string

module Make (C : Conf.S) : sig
  (** {1 Stepping}

      A unit of work is one namespace while marking — a folder's worth of
      manifests, or of versions — and one shard while closing or reconciling. They
      are not the same size, so a caller pacing itself should think in seconds spent
      rather than in units done.

      Nothing is enumerated whole up front. Marking reads the two directories that
      hold the namespaces and walks one at a time, so the cost of finding the work
      is spread through the work rather than paid before any of it starts — and paid
      again on every resume, which is what a budgeted collection would otherwise
      spend most of itself doing. *)

  type session

  (** Open a run, or pick up the one already open. Lists the work outstanding,
      which is the one expensive thing here, and takes the collection lock.

      [concurrency] caps the syscalls in flight within a step; the main's
      {!Backend.caps.max_concurrency} by default, and 1 to be as unobtrusive as
      possible. The work is I/O bound, so this and not the batch size is what
      decides how hard a step leans on the device.

      Raises {!Unsupported} when no main can collect, {!Busy} when a collection is
      already under way. *)
  val start : ?concurrency:int -> unit -> session Lwt.t

  (** Do up to [units] units (default 1) and report whether any remain. Saves
      enough as it goes that dropping the session — or the process — loses at most
      the last step.

      [`Done] means the run is closed and the store is back to one space. *)
  val step : ?units:int -> session -> [ `More | `Done ] Lwt.t

  (** Give up the collection lock. A caller driving {!step} itself must call this
      when it stops, whether or not the run finished — the run is meant to outlive
      the process and be resumed, the lock is not. {!run} does it for you.

      Not needed for correctness after the process exits: the kernel drops the
      lock with the process, which is why a crash leaves a resumable run. *)
  val release : session -> unit Lwt.t

  (** What the session is doing and how far along, for a caller driving {!step}
      itself. [total] is the units this phase started with. *)
  val phase : session -> string

  val done_ : session -> int
  val total : session -> int

  (** What has been reclaimed so far. [outcome] is meaningful once {!step} has
      answered [`Done]. *)
  val stats : session -> stats

  (** {1 Driving it for them} *)

  (** {!start} then {!step} to completion.

      [units] per step (default 256), [concurrency] within a step and [pause]
      seconds of sleep between steps (default none) are the pace. [budget] is a
      wall-clock limit in seconds, after which the run is left open and
      {!Suspended} is returned. It is checked between units, not merely between
      steps: a unit can run for a while, and a limit only honoured at the end of a
      batch of them is not much of a limit.

      Progress is reported because a run over a large store takes a long time and
      a silent process is indistinguishable from a wedged one. [on_mark] and
      [on_close] are throttled to about one call a second; [on_reconcile] fires
      for each target that needed anything in a shard. *)
  val run :
    ?budget:float ->
    ?units:int ->
    ?pause:float ->
    ?concurrency:int ->
    ?on_open:(unit -> unit) ->
    ?on_mark:
      (namespaces:int -> total:int -> roots:int -> promoted:int -> unit) ->
    ?on_close:(shards:int -> reclaimed:int -> unit) ->
    ?on_reconcile:(name:string -> deleted:int -> uploaded:int -> unit) ->
    unit ->
    stats Lwt.t

  (** {1 Getting out of one} *)

  (** Abandon an open run, keeping everything: every chunk still in the discarded
      space is promoted first, so nothing is collected. For getting a store back
      to one space without waiting for a mark to finish.

      A no-op when no run is open. *)
  val abort :
    ?on_mark:
      (namespaces:int -> total:int -> roots:int -> promoted:int -> unit) ->
    unit ->
    stats Lwt.t

  (** The run in progress, for a caller that wants to report one rather than
      continue it. *)
  val status : unit -> Chunk_space.run option Lwt.t
end
