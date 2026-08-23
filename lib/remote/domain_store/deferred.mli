(** A copy filled behind the write rather than in it.

    A write returns once the mains have it; a deferred target then catches up on
    its own, so a slow, metered or unreachable store never sets the pace of a
    copy into the mount.

    A manifest reaches the target only once every chunk it names is confirmed
    present, so the target never holds a manifest referencing blocks it lacks:
    {i partial coverage, never partial files}.

    Work owed is kept on disk ({!Durable_queue}), so an offline target catches
    up when the link returns rather than needing a resync. A job is retried for
    as long as the failure is {!Backend.Transient} and dropped on a permanent
    one, which marks the target degraded — the one state needing
    [tsync mirror --source <main>] rather than patience.

    A queued job names a key and carries no body, the worker re-reading from the
    mains when it runs: repeated puts to one key converge on the latest, and a
    put whose key has since been deleted reads back nothing and is skipped.

    {1 Two roles, one behavior}

    A target that is read from and one that is not differ in exactly one thing,
    which is why [reads_reach] is a flag rather than two implementations:

    - a [backfill] target never is: no use for the journal or cursor, since
      nothing reads those from it either;
    - a [replica] is: a full second copy, read when no main is reachable, and
      carrying the journal and cursor a peer reading it needs.

    So promotion of a resynced backfill is which functor its config spells,
    rather than a different code path. *)

type op =
  | Put of { key : string; data : Bigstring.t }
  | Copy of { src_key : string; dst_key : string }
  | Delete of string
  | Delete_multi of string list

(** How far behind: jobs waiting, chunk pushes in flight, and whether work was
    dropped or the log overflowed. *)
type stats = { queued : int; in_flight : int; degraded : bool }

module type S = sig
  val name : string

  (** The leaf store under this target. *)
  val backend : (module Backend.S)

  (** Take one write, to catch up on later. Returns once the work is durable,
      not once it has landed. *)
  val accept : op -> unit Lwt.t

  (** Keys this target has no use for, and which are never forwarded to it. *)
  val skip : string -> bool

  (** The store, when a read may fall through to this target; [None] when it is
      write-only. Also what decides whether a share link may be served from it:
      a link into a target nobody reads could point at a file it will never
      have. *)
  val readable : (module Backend.S) option

  val stats : unit -> stats
end

(** [make ~name ~backend ~source ~chunk_prefix ~chunk_keys ~journal_prefix
     ~cursor_key ~root ()].

    [source] is where the worker re-reads a job's body from, and must be the
    authoritative store rather than any read path that can fall through to
    another copy: a job is consumed once it succeeds, so a body read from a
    target that is itself behind would be written here and never corrected.

    [chunk_keys] returns the bare ["<h1>-<h2>"] keys a manifest body names, and
    the empty list for a body that is not a manifest; injected so this library
    stays below the manifest format.

    [root] is where work owed is kept, one directory per target beneath it. It
    should be per domain: the jobs name domain keys, and a shared root would
    replay one domain's against another's stores.

    [resume] picks up what a previous run left in [dir]. The daemon passes it; a
    one-shot command does not, so two processes cannot run one target's jobs at
    once and reorder a rename's copy and delete. A one-shot command still
    records and drains its own.

    [chunk_from_prefix] is where the source keeps chunks it has not finished
    collecting — see {!Chunk_space} — and a read falls through to it, though
    what is written to the target is always the ordinary chunk key. Omit it for
    a source that is never collected.

    [excluded] names the keys no target carries, whatever it is for. The caller
    decides which those are: this knows only that some keys describe the store
    that wrote them, so a copy would match nothing where it lands.

    [reads_reach] is whether reads may fall through to this target. One they
    reach carries the journal and cursor too, a peer reading it needing both;
    one they never reach has no use for either. *)
val make :
  ?resume:bool ->
  ?chunk_from_prefix:string ->
  name:string ->
  backend:(module Backend.S) ->
  source:(module Backend.S) ->
  chunk_prefix:string ->
  chunk_keys:(string -> string list) ->
  journal_prefix:string ->
  cursor_key:string ->
  excluded:(string -> bool) ->
  reads_reach:bool ->
  root:string ->
  unit ->
  (module S)

(** Give up this process's claim on a target's log, so another may take what it
    left owed without waiting for this one to exit. *)
val release : root:string -> name:string -> unit
