(** Collect chunks nothing references any more.

    {!Expire} drops the references — old versions, trashed folders, journal
    entries — and this reclaims the chunks that leaves behind; run one then the
    other, neither does the other's job.

    {b How it works.} A run moves the chunk root aside to [chunks.from/] and
    lets the live set accumulate under [chunks/], the name every writer already
    uses; marking gives each chunk a live root names a second hard link under
    [chunks/], and closing discards [chunks.from/] along with the inodes that
    never earned one, so reclaiming is the link count's doing rather than a
    delete's.

    Writes need no cooperation: a client that has never heard of a run still
    writes to the space that survives. The one thing a writer must do is
    {!Chunk_space.promote_all} before publishing a manifest, which
    {!Remote.publish} does.

    {b Where it runs.} Only on a main that answers {!Backend.caps.gc}, a rename
    and a link within the store being what the whole scheme rests on; an s3, gcs
    or http-proxy main is refused rather than half-served.

    {b The copies.} Replicas and backfill targets are never renamed: once the
    main has settled each is walked shard by shard — the target's own shards,
    since only it knows what it holds — and whatever the main no longer has is
    deleted. A replica is additionally filled where it falls short, being meant
    to be a complete copy; a backfill target is not, being incomplete by design
    and having its own queue for that.

    Filling a replica is the only part that sends bytes anywhere, so it goes out
    concurrently and can be interrupted between chunks; a shard stopped part-way
    is simply done again, reconciling one being idempotent.

    {b Pace.} Driven a step at a time so this can run without taking the machine
    over, {!run} being the impatient version of that loop. A run left open
    between steps, or between whole invocations, is safe indefinitely: reads
    look in both spaces and writes were never redirected.

    {b Scale.} The surviving root {i is} the record of what has been marked, so
    nothing is held in memory and a run interrupted at a root or shard boundary
    continues where it left off. *)

type outcome =
  | Completed
  | Suspended of { phase : string; cursor : string }
      (** Stopped at a boundary with the run still open. The next call continues
          from [cursor]. *)

(** What reconciling one copy came to. [uploaded] is always zero for a backfill
    target: being incomplete is its normal condition, so a gap there says
    nothing and is left to its own queue. *)
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

(** Something else is already stepping a run; carries a sentence for the user.
    Two collectors on one run lose chunks — they resume from the same cursor, so
    their root lists partition, and whichever finishes its share first starts
    discarding the old space while the other still has unpromoted roots.

    Exclusion is a lock file on the main, so the kernel releases it if the
    holder dies: a crashed collection leaves a run that resumes, never a run
    nobody may touch. *)
exception Busy of string

module Make (C : Conf.S) : sig
  (** {1 Stepping}

      The pacing seam under {!run}, for a caller that has to hold one collection
      across many steps and watch it; anything driving a collection to get it
      done wants {!run}.

      A unit of work is one namespace while marking — a folder's worth of
      manifests, or of versions — and one shard while closing or reconciling.
      They are not the same size, so a caller pacing itself should think in
      seconds spent rather than in units done. *)

  type session

  (** Open a run, or pick up the one already open. Lists the work outstanding,
      which is the one expensive thing here, and takes the collection lock.

      [concurrency] caps the syscalls in flight within a step; the main's
      {!Backend.caps.max_concurrency} by default, and 1 to be as unobtrusive as
      possible. The work is I/O bound, so this and not the batch size decides
      how hard a step leans on the device.

      [keep] makes this an abandonment rather than a collection: see {!abort}.

      Raises {!Unsupported} when no main can collect, {!Busy} when a collection
      is already under way. *)
  val start : ?concurrency:int -> ?keep:bool -> unit -> session Lwt.t

  (** Do up to [units] units (default 1) and report whether any remain. Saves
      enough as it goes that dropping the session — or the process — loses at
      most the last step.

      [`Done] means the run is closed and the store is back to one space. *)
  val step : ?units:int -> session -> [ `More | `Done ] Lwt.t

  (** Give up the collection lock. A caller driving {!step} itself must call
      this when it stops, whether or not the run finished — the run is meant to
      outlive the process and be resumed, the lock is not; {!run} does it for
      you.

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
      steps: a unit can run for a while, and a limit only honoured at the end of
      a batch of them is not much of a limit.

      All three progress callbacks are throttled to about one call a second and
      carry running totals rather than per-item deltas. [on_reconcile] names the
      target it is talking about and fires while a replica is being filled, that
      being the slowest thing a collection does. *)
  val run :
    ?budget:float ->
    ?units:int ->
    ?pause:float ->
    ?concurrency:int ->
    ?keep:bool ->
    ?on_open:(unit -> unit) ->
    ?on_mark:(namespaces:int -> total:int -> roots:int -> promoted:int -> unit) ->
    ?on_close:(shards:int -> reclaimed:int -> unit) ->
    ?on_reconcile:
      (name:string ->
      shards:int ->
      total:int ->
      deleted:int ->
      uploaded:int ->
      unit) ->
    unit ->
    stats Lwt.t

  (** {1 Getting out of one} *)

  (** Abandon an open run, keeping everything: every chunk still in the space on
      its way out is given a name in the surviving one first, so nothing is
      collected. A no-op when no run is open.

      This is {!run} with one difference — every chunk is treated as live — so
      it takes the same pacing arguments and is resumable a shard at a time.
      Coming back to an abandonment continues abandoning rather than resuming
      the collection. *)
  val abort :
    ?budget:float ->
    ?units:int ->
    ?pause:float ->
    ?concurrency:int ->
    ?on_open:(unit -> unit) ->
    ?on_mark:(namespaces:int -> total:int -> roots:int -> promoted:int -> unit) ->
    ?on_close:(shards:int -> reclaimed:int -> unit) ->
    ?on_reconcile:
      (name:string ->
      shards:int ->
      total:int ->
      deleted:int ->
      uploaded:int ->
      unit) ->
    unit ->
    stats Lwt.t

  (** The run in progress, for a caller that wants to report one rather than
      continue it. *)
  val status : unit -> Chunk_space.run option Lwt.t
end
