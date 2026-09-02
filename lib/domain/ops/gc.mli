(** Collect chunks nothing references any more.

    {!Expire} drops the references — old versions, trashed folders, journal
    entries — and this reclaims the chunks that leaves behind; run one then the
    other, neither does the other's job.

    {b How it works.} A run moves the chunk root aside to [chunks.from/] and
    lets the live set accumulate under [chunks/], the name every writer already
    uses; marking then {i moves} each chunk a live root names back into
    [chunks/]. So what is left in [chunks.from/] once marking is done is the
    garbage itself, named rather than inferred, and closing has only to delete
    it.

    Writes need no cooperation: a client that has never heard of a run still
    writes to the space that survives. The one thing a writer must do is
    {!Collection.Make.promote_all} before publishing a manifest, which
    {!Remote.publish} does.

    {b Where it runs.} Only on a main that keeps its objects here
    ({!Backend.S.local_path}), a directory rename within the store being the
    whole of what this rests on; an s3, gcs or http-proxy main is refused rather
    than half-served.

    {b The copies.} Replicas and backfill targets are never renamed. Closing
    deletes off each of them the same keys it discards here, batched by key
    count across as many shards as it takes to fill one — the copies before the
    main, so an interruption leaves keys to delete again rather than keys
    nothing will ever name.

    A copy whose bucket runs the delete function is {i told} rather than
    deleted: {!Backend.S.discard} writes the batch as a request the bucket's own
    notification delivers, and the request being durably stored is what stands
    in for the delete having happened. So the ordering above holds either way,
    but a copy whose function never runs keeps its garbage — see
    {!Make.outstanding}, which is the only thing that will ever say so.

    What this does {i not} do is fill a copy that has fallen behind, or find
    chunks a copy holds that the main never had. That is {!Checkout.resync} —
    [tsync mirror] — and asking for it here meant walking every shard there
    could be on every target, whatever the store held.

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

(** No per-copy figures: every copy is sent the same keys, so a count against
    each would be one number repeated. Which copies were talked to is logged
    when closing starts, and a copy that refused a delete raises rather than
    being tallied. *)
type stats = {
  outcome : outcome;
  roots_marked : int;
  chunks_promoted : int;
  chunks_verified : int;
      (** Live chunks held against their own names, under [~verify]. Zero
          otherwise: a collection is renames and listings, and reads nothing. *)
  chunks_corrupt : int;  (** of those, the ones that were not what they say *)
  chunks_unreadable : int;
      (** Live chunks the store would not hand over. Filed as corrupt too, and
          on a failing disk this is the commoner half: bit rot surfaces as [EIO]
          on read rather than as wrong bytes. *)
  chunks_cleared : int;
      (** Chunks that carried a marker and turned out to be fine, so it was
          removed. A repair someone made elsewhere, noticed. *)
  chunks_reclaimed : int;
  bytes_reclaimed : int;
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

(** One collection per machine, and the kernel is what enforces it: a run holds
    an exclusive lock on a file under the store's own directory.

    [take] answers [None] when another process holds it, rather than raising, so
    that what a busy machine is told stays this module's sentence to write. The
    kernel drops the lock when the holder dies, which is what makes a crashed
    collection leave a run that resumes rather than one nobody may touch. *)
module type LOCKFILE = sig
  type 'a io
  type t

  val take : string -> t option io
  val drop : t -> unit io
end

module Over
    (Io : Io.S)
    (_ : Fs.S with type 'a io := 'a Io.t)
    (_ : Syscalls.S with type 'a io := 'a Io.t)
    (Pools : Bounded.S with type 'a io := 'a Io.t)
    (_ : LOCKFILE with type 'a io := 'a Io.t)
    (_ : Clock.S with type 'a io := 'a Io.t)
    (_ : Collection.OVER with type 'a io := 'a Io.t) : sig
  module Make (C : Conf.S with type 'a io = 'a Io.t) : sig
    (** {1 Stepping}

        The pacing seam under {!run}, for a caller that has to hold one
        collection across many steps and watch it; anything driving a collection
        to get it done wants {!run}.

        A unit of work is one namespace while marking — a folder's worth of
        manifests, or of versions — and one shard while closing, though closing
        pools several shards into one delete. They are not the same size, so a
        caller pacing itself should think in seconds spent rather than in units
        done. *)

    type session

    (** Open a run, or pick up the one already open. Lists the work outstanding,
        which is the one expensive thing here, and takes the collection lock.

        [concurrency] caps the syscalls in flight within a step; the main's
        {!Backend.caps.max_concurrency} by default, and 1 to be as unobtrusive
        as possible. The work is I/O bound, so this and not the batch size
        decides how hard a step leans on the device.

        [delete_batch] is how many keys go into one delete against a copy
        (default 1000, which is what s3 and gcs both cap a bulk delete at).
        Raise it for a store that takes more, lower it for one that chokes.

        [keep] makes this an abandonment rather than a collection: see {!abort}.

        [verify] holds every live chunk against its own name as marking promotes
        it, filing what fails under {!Corruption}. Opt-in because it reads every
        live byte where the rest of a collection touches only metadata — the
        same reason [tsync data-integrity] is.

        Live chunks only: what marking never reaches is the garbage closing is
        about to delete. A chunk that fails is promoted and marked, never
        discarded — a manifest names it, so dropping it would take a file's only
        copy with it.

        Raises {!Unsupported} when no main can collect, {!Busy} when a
        collection is already under way. *)
    val start :
      ?concurrency:int ->
      ?delete_batch:int ->
      ?keep:bool ->
      ?verify:bool ->
      unit ->
      session Io.t

    (** Do up to [units] units (default 1) and report whether any remain. Saves
        enough as it goes that dropping the session — or the process — loses at
        most the last step.

        [`Done] means the run is closed and the store is back to one space. *)
    val step : ?units:int -> session -> [ `More | `Done ] Io.t

    (** Give up the collection lock. A caller driving {!step} itself must call
        this when it stops, whether or not the run finished — the run is meant
        to outlive the process and be resumed, the lock is not; {!run} does it
        for you.

        Not needed for correctness after the process exits: the kernel drops the
        lock with the process, which is why a crash leaves a resumable run. *)
    val release : session -> unit Io.t

    (** What the session is doing and how far along, for a caller driving
        {!step} itself. [total] is the units this phase started with. *)
    val phase : session -> string

    val done_ : session -> int
    val total : session -> int

    (** What has been reclaimed so far. [outcome] is meaningful once {!step} has
        answered [`Done]. *)
    val stats : session -> stats

    (** {1 Driving it for them} *)

    (** {!start} then {!step} to completion.

        [units] per step (default 256), [concurrency] within a step and [pause]
        seconds of sleep between steps (default none) are the pace. [budget] is
        a wall-clock limit in seconds, after which the run is left open and
        {!Suspended} is returned. It is checked between units, not merely
        between steps: a unit can run for a while, and a limit only honoured at
        the end of a batch of them is not much of a limit.

        Both progress callbacks are throttled to about one call a second, per
        phase, and carry running totals rather than per-item deltas. The last
        call of a phase is not throttled, so a phase shorter than the interval
        still reports where it ended.

        [at] is the namespace or shard being worked on, set as it is picked up
        rather than once it is done, which is what a caller saying where a
        collection has got to wants. *)
    val run :
      ?budget:float ->
      ?units:int ->
      ?pause:float ->
      ?concurrency:int ->
      ?delete_batch:int ->
      ?keep:bool ->
      ?verify:bool ->
      ?on_open:(unit -> unit) ->
      ?on_mark:
        (namespaces:int ->
        total:int ->
        roots:int ->
        promoted:int ->
        at:string ->
        unit) ->
      ?on_close:(shards:int -> reclaimed:int -> at:string -> unit) ->
      unit ->
      stats Io.t

    (** {1 Getting out of one} *)

    (** Abandon an open run, keeping everything: every chunk still in the space
        on its way out is given a name in the surviving one first, so nothing is
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
      ?on_mark:
        (namespaces:int ->
        total:int ->
        roots:int ->
        promoted:int ->
        at:string ->
        unit) ->
      ?on_close:(shards:int -> reclaimed:int -> at:string -> unit) ->
      unit ->
      stats Io.t

    (** The run in progress, for a caller that wants to report one rather than
        continue it. *)
    val status : unit -> Collection.run option Io.t

    (** Delete requests a copy has not consumed: its name, how many, and how
        long the oldest has been sitting there. Anything here is a copy holding
        chunks nothing references — the keys are already gone from the main, so
        no later collection meets them again and only {!Checkout.resync} would
        find them.

        Outlives the run that queued them, so a caller reporting this must do so
        whether or not {!status} found one open. *)
    val outstanding : unit -> (string * int * float) list Io.t

    (** Deliver every outstanding request again, by copy name and count. The
        store's notification fired once when the request was written and will
        not fire again on its own, so a function that was absent or broken then
        does not pick one up by being fixed — this is what gives it a second
        delivery.

        Safe to repeat: a request the function has already consumed is gone, and
        one it consumes twice deletes keys that are already deleted. *)
    val retry_outstanding : unit -> (string * int) list Io.t

    (** An age from {!outstanding} as the report says it. Shared so a log line
        and [--status] cannot answer the same question differently. *)
    val show_age : float -> string
  end
end
