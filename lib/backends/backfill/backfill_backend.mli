(** Lazily-filled backfill targets, as one {!Backend.S} wrapping the
    authoritative backends.

    A backfill target is a converging copy, not a replica: never read from,
    never in the way of a foreground write. It receives chunks as they are
    written, and a manifest only once every chunk that manifest names is
    confirmed present on it — so it never holds a manifest referencing blocks it
    does not have, which is what a copy of a deduped file (a file copy, an
    incremental re-upload) would otherwise leave behind.

    The role is for when copying the data already in the source of truth is
    impractical or not worth it — a very large dataset whose full integrity is a
    nice-to-have rather than a requirement. The target starts empty and covers
    what gets written from then on, giving
    {i partial coverage, never partial files}: what it holds is whole and
    restorable, what it lacks is whole files. Use [`Replica] instead when the
    copy has to be a guarantee.

    Writes to a target are ordered, because a rename is a copy followed by a
    delete of the source. Chunk pushes are not, and are dropped when too many
    are already in flight: the manifest step re-fetches whatever is missing, so
    dropping one costs a fetch and nothing else.

    Nothing here is durable. A daemon exit loses what is queued, and a target is
    only ever filled with writes made while it was configured, so
    [tsync resync-remote --source <main>] is both the initial fill and the
    repair. *)

type sub = { name : string; backend : (module Backend.S) }

(** [make ~chunk_prefix ~chunk_keys ~skip_prefixes ~inners ~backfills].

    [inners] are the authoritative backends: the head serves every read and a
    write fans out over all of them, which is what {!Backends.Make} states.
    [chunk_keys] returns the bare ["<h1>-<h2>"] keys a manifest body names, and
    the empty list for a body that is not a manifest — injected so this library
    does not need to know the manifest format. [skip_prefixes] are keys never
    forwarded to a target, namely the journal and the cursor. *)
val make :
  chunk_prefix:string ->
  chunk_keys:(string -> string list) ->
  skip_prefixes:string list ->
  inners:(module Backend.S) list ->
  backfills:sub list ->
  (module Backend.S)

(** Wait for every target configured in this process to catch up, giving up
    after a bounded wait so an unreachable target cannot hang a command. {!make}
    registers this with {!Backend.on_drain}, so callers normally reach it
    through [Backend.drain]; it is exposed for tests that assert on what a
    target holds. *)
val drain_all : unit -> unit Lwt.t
