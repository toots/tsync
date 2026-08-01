(** Lazily-filled backfill targets, as one {!Backend.S} wrapping the
    authoritative backends.

    A backfill target is a converging copy, not a replica: never read from,
    never in the way of a foreground write. It receives chunks as they are
    written, and a manifest only once every chunk that manifest names is
    confirmed present — so it never holds a manifest referencing blocks it
    lacks, which is what a copy of a deduped file would otherwise leave behind.

    The role is for when copying what the source of truth already holds is
    impractical — a very large dataset whose full integrity is a nice-to-have.
    The target starts empty and covers what is written from then on, giving
    {i partial coverage, never partial files}. Use [`Replica] when the copy has
    to be a guarantee.

    Writes to a target are ordered, since a rename is a copy followed by a
    delete of the source. Chunk pushes are not, and are dropped when too many
    are in flight: the manifest step re-fetches whatever is missing.

    Nothing here is durable. A daemon exit loses what is queued, and a target is
    only filled with writes made while it was configured, so
    [tsync resync-remote --source <main>] is both the initial fill and the
    repair. *)

type sub = { name : string; backend : (module Backend.S) }

(** How far behind one target is: jobs waiting, chunk pushes in flight, and
    whether the queue overflowed and dropped writes — the one state needing
    [tsync resync-remote] rather than patience. *)
type lane_stats = { queued : int; in_flight : int; degraded : bool }

(** The composite, plus a live view of each target by name. Returned rather than
    global, so a process serving several domains cannot confuse two targets
    sharing a name. *)
type t = {
  backend : (module Backend.S);
  lanes : (string * (unit -> lane_stats)) list;
}

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
  t

(** Wait for every target in this process to catch up, giving up after a bounded
    wait so an unreachable one cannot hang a command. {!make} registers this
    with {!Backend.on_drain}, so callers normally reach it through
    [Backend.drain]; exposed for tests that assert on what a target holds. *)
val drain_all : unit -> unit Lwt.t
