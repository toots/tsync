(** A copy filled behind the write rather than in it.

    A write returns once the mains have it; a deferred target then catches up on
    its own, so a slow, metered or unreachable store never sets the pace of a
    copy into the mount.

    A manifest reaches the target only once every chunk it names is confirmed
    present, so the target never holds a manifest referencing blocks it lacks:
    {i partial coverage, never partial files}.

    Work owed is kept on disk ({!Durable_queue}), so an offline target catches
    up when the link returns rather than needing a resync. A job is retried for
    as long as the failure is {!Retry.Transient} and dropped on a permanent one,
    which marks the target degraded — the one state needing
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
  | Put of { key : Stored_key.t; data : Bigstring.t }
  | Copy of { src_key : Stored_key.t; dst_key : Stored_key.t }
  | Delete of Stored_key.t
  | Delete_multi of Stored_key.t list

(** How far behind: jobs waiting, chunk pushes in flight, and whether work was
    dropped or the log overflowed. *)
type stats = { queued : int; in_flight : int; degraded : bool }

module Over
    (Io : Io.S)
    (_ : Durable_queue.S with type 'a io := 'a Io.t)
    (_ : Lock.S with type 'a io := 'a Io.t) : sig
  module type Store = Backend.S with type 'a io := 'a Io.t

  module type S = sig
    val name : string

    (** The leaf store under this target. *)
    val backend : (module Store)

    (** Take one write, to catch up on later. Returns once the work is durable,
        not once it has landed. *)
    val accept : op -> unit Io.t

    (** Keys this target has no use for, and which are never forwarded to it. *)
    val skip : Stored_key.t -> bool

    (** The store, when a read may fall through to this target; [None] when it
        is write-only. Also what decides whether a share link may be served from
        it: a link into a target nobody reads could point at a file it will
        never have. *)
    val readable : (module Store) option

    val stats : unit -> stats
  end

  (** [make ~name ~backend ~source ~chunk_prefix ~chunk_keys ~journal_prefix
       ~cursor_key ~root ()].

      [source] is where the worker re-reads a job's body from, and must be the
      authoritative store rather than any read path that can fall through to
      another copy: a job is consumed once it succeeds, so a body read from a
      target that is itself behind would be written here and never corrected.

      [chunk_keys] returns the bare ["<h1>-<h2>"] keys a manifest body names,
      and the empty list for a body that is not a manifest; injected so this
      library stays below the manifest format.

      [root] is where work owed is kept, one directory per target beneath it. It
      should be per domain: the jobs name domain keys, and a shared root would
      replay one domain's against another's stores.

      [resume] picks up what a previous run left in [dir]. The daemon passes it;
      a one-shot command does not, so two processes cannot run one target's jobs
      at once and reorder a rename's copy and delete. A one-shot command still
      records and drains its own.

      [chunk_from_prefix] is where the source keeps chunks it has not finished
      collecting — see {!Collection} — and a read falls through to it, though
      what is written to the target is always the ordinary chunk key. Omit it
      for a source that is never collected.

      [excluded] names the keys no target carries, whatever it is for. The
      caller decides which those are: this knows only that some keys describe
      the store that wrote them, so a copy would match nothing where it lands.

      [reads_reach] is whether reads may fall through to this target. One they
      reach carries the journal and cursor too, a peer reading it needing both;
      one they never reach has no use for either.

      [max_chunk_forwards] bounds the chunk pushes this target runs at once. A
      forward keeps its body alive after the write that carried it has returned
      and released its chunk buffer, so this is the memory that path costs, and
      the caller passes the budget it holds those buffers under. A push offered
      past it is dropped for the manifest job to fetch later, never queued.
      Values below [1] are read as [1].

      [room_for] is the link's answer to the same question: whether a body of
      that many bytes may go now. A [false] drops the forward as the count
      does, for the same reason, that a body is not held in memory waiting
      for a link; the store's own gate then takes the room on the write with
      nothing between, which is what the answer is good for. Omitted, there
      is always room. *)
  val make :
    ?resume:bool ->
    ?chunk_from_prefix:string ->
    ?max_chunk_forwards:int ->
    ?room_for:(bytes:int -> bool) ->
    name:string ->
    backend:(module Store) ->
    source:(module Store) ->
    chunk_prefix:string ->
    chunk_keys:(string -> string list) ->
    journal_prefix:string ->
    cursor_key:Stored_key.t ->
    excluded:(Stored_key.t -> bool) ->
    reads_reach:bool ->
    root:string ->
    unit ->
    (module S)

  (** Give up this process's claim on a target's log, so another may take what
      it left owed without waiting for this one to exit. *)
  val release : root:string -> name:string -> unit
end
