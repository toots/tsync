(** Targets filled behind the write rather than in it, as one {!Backend.S}
    wrapping the authoritative backends.

    A write returns once the mains have it; each target then catches up on its
    own lane, so a slow, metered or unreachable store never sets the pace of a
    copy into the mount. It receives chunks as they are written, and a manifest
    only once every chunk that manifest names is confirmed present — so it never
    holds a manifest referencing blocks it lacks, which is what a copy of a
    deduped file would otherwise leave behind.

    Two roles ride on this. A [replica] is a full second copy, read from when no
    main is reachable ({!Fallback_backend} places it after the mains, so a
    failover read is behind by whatever its lane still owes). A [backfill]
    target starts empty and covers only what is written from then on, is never
    read from, and gives {i partial coverage, never partial files} — for when
    copying what the mains already hold is impractical.

    Writes to a target are ordered, since a rename is a copy followed by a
    delete of the source. Chunk pushes are not, and are dropped when too many
    are in flight: the manifest step re-fetches whatever is missing.

    A queued job names a key and carries no body; the worker re-reads from the
    mains when it runs it. So the queue is small enough to keep on disk, and it
    survives a restart: an offline target catches up when the link returns. A
    job is retried for as long as the failure is {!Backend.Transient}, and
    dropped only on a permanent one — which marks the lane degraded, the one
    state needing [tsync resync-remote --source <main>] rather than patience.
    Resync is also the initial fill for a target added to an existing domain. *)

type sub = {
  name : string;
  backend : (module Backend.S);
  skip_prefixes : string list;
      (** Keys never forwarded to this target: the journal and the cursor for a
          backfill target, which has no use for either, and nothing for a
          replica — a peer reading one needs both. *)
}

(** How far behind one target is: jobs waiting, chunk pushes in flight, and
    whether the queue overflowed or dropped a write — the one state needing
    [tsync resync-remote] rather than patience. *)
type lane_stats = { queued : int; in_flight : int; degraded : bool }

(** The composite, plus a live view of each target by name. Returned rather than
    global, so a process serving several domains cannot confuse two targets
    sharing a name. *)
type t = {
  backend : (module Backend.S);
  lanes : (string * (unit -> lane_stats)) list;
}

(** [make ~chunk_prefix ~chunk_keys ~log_dir ?resume ~inners ~targets ()].

    [inners] are the authoritative backends: the head serves every read and a
    write fans out over all of them, which is what {!Backends.Make} states.
    [chunk_keys] returns the bare ["<h1>-<h2>"] keys a manifest body names, and
    the empty list for a body that is not a manifest — injected so this library
    does not need to know the manifest format. [log_dir] is where the lanes keep
    what they still owe, one directory per target; it should be per domain,
    since the keys are the domain's.

    [resume] picks up what a previous run left in [log_dir]. The daemon passes
    it; a one-shot command does not, so two processes cannot run one lane's jobs
    at once and reorder a rename's copy and delete. A one-shot command still
    records and drains its own. *)
val make :
  ?resume:bool ->
  chunk_prefix:string ->
  chunk_keys:(string -> string list) ->
  log_dir:string ->
  inners:(module Backend.S) list ->
  targets:sub list ->
  unit ->
  t

(** Wait for every target in this process to catch up. Stops waiting on a target
    that has started failing, and on everything after a bounded wait: what is
    left is on disk and resumes on the daemon's next start, so holding a command
    open for a store that is down buys nothing. {!make} registers this with
    {!Backend.on_drain}, so callers normally reach it through [Backend.drain];
    exposed for tests that assert on what a target holds. *)
val drain_all : unit -> unit Lwt.t
