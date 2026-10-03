# Failure model — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/failure-model.md](../../algorithms/failure-model.md).
See [../README.md](../README.md) for how these notes are organised.

## 1. Where each abstraction lives

| Abstract | OCaml | Notes |
|---|---|---|
| TRANSIENT / permanent | `Retry.Failed {kind = Transient \| Permanent; op; detail}` (`lib/core/retry.ml`) | `link`, `load` and `local` are not distinguished; neither are the permanent kinds |
| CANCELLED | `Retry.Cancelled`; runtime cancellation via `Clock.is_cancelled` | |
| STOPPING | `Shutdown.Stopping`, `Shutdown.request`, `grace = 10` | |
| UNEXPLAINED default | `Retry.classify` (→ `Transient`) for requests, `Retry.classify_in_order` (→ `Permanent`) for ordered work | |
| CORRUPT and UNPREPARED | both `Backend.Backend_error msg`, raised in `chunk_store.ml`, `chunk_cache.ml`, `data.ml`, `file.ml`, `gc/collection.ml`, `Backend.checked_range` | one constructor for two kinds |
| REFUSED/read_only | `Backend.Not_writable`; `EROFS` | |
| store classifier | `Backend.classify` | |
| HTTP detection | `Http_client.failed` (transient iff status ≥ 500 or 429), `call_retry`, `with_stall_timeout` | |
| S3 / GCS detection | `Throttled`, `Failed exn` → transient; `Forbidden`, `Not_found`, `Unknown`, `Redirect` → permanent; `Backend.absent_code` | |
| ladder | `Retry.Make.with_retry`, `default_attempts = 8` | |
| breaker | `Health`, `Health_wait.until_held`, `Retry.held` | |
| composite aggregation | `Domain_store.make`: `read`, `walk`, `ask_member`, `stop_on_miss`, batch re-ask | |
| writes to a copy while a main is down | `Write_guard.ensure` | |
| queue policy | `Durable_queue.ordered` / `keyed`, `Poison.Stop` / `Drop` | |
| own metadata ops | `Meta_queue` (ordered, `classify_in_order`, `Stop`, parked set re-armed every 60 s by `Domain_engine` maintenance) | |
| uploads | `Sync_queue` (keyed, `Backend.classify`, `Stop`; `Retry.Cancelled` or `ENOENT` completes the record) | a permanently failed upload leaves the queue and is re-offered only at the next start |
| replica/backfill jobs | `Deferred` (ordered, `Drop` → degraded) | |
| peer entries | `Replay.apply_foreign` / `stepping_aside`, `stepped_aside`; poller `retry_floor = 2 s`, sweep 60 s | |
| read deadline | `Chunk_cache.read_deadline = 15`, `within_deadline` | only uncached reads are wrapped |
| client codes | `Ipc_error.of_exn`, `Ipc_handler.error_code_json` | |
| FUSE mapping | errno passes through `on_loop`; anything else → `EIO` plus the failure ring | |
| peer server mapping | 404 / 409 / 500 / 503 / 403 / 401 / 400 in the http-proxy frontend | |
| macOS client | `DaemonError`, `FileProviderError.from`: only `unreachable` → `serverUnreachable`, latched until `signalErrorResolved`; missing code → `internal` | |
| Android client | `Cli.reply`, `Cli.Error` | |
| CLI exit | `main.ml`: `Failure` / `Retry.Failed` → 1; anything else → 125; some commands 1 or 2 | |
| stop | `drain_for_stop` raced against the grace; queue drain 0.8 × grace; reaper grace + 2 s; systemd `TimeoutStopSec=30` | |
| durable failure state | WAL `note_failure`; `.bad` sidecars; `tsync/corrupted/<domain>/` markers; `degraded` in queue stats | |

## 2. Where the code departs from the spec

- **Client code mapping.** `Ipc_error.of_exn` maps `Backend.Backend_error` (used for corrupt data
  and for "run `tsync sync`" preconditions) to `unreachable`, and maps `Retry.Failed` (a held
  member, an exhausted transient ladder, a 403) to `internal`. A corrupt chunk or an operation
  under a folder without an id therefore latches a macOS domain offline, while a store that is
  down or a revoked credential is retried as an unknown error and never latches. A `` `Bad ``
  item reference is answered `not_found`.
- **Codes on every reply.** The File Provider router's own refusals ("invalid JSON", "expected
  JSON object", "cannot tell which domain") carry no `code`; Swift reads them as `internal`. The
  Android bridge (`Cli.kt`) drops `code` entirely: `Ingest.children` turns every error into "no
  children", which lets name allocation overwrite an existing file, and the provider reports
  "could not reach the server" for a deleted folder.
- **Staged bodies.** `Data.fill_from_staged` (`lib/domain/checkout/content/data.ml`) treats any
  failure to open a staged body as a missing body and fills zeros, so `EMFILE` or `EIO` uploads
  and publishes zeros as the file's content.
- **Journal entry reads.** `File_store.get_journal_entry` catches every exception, including
  `Shutdown.Stopping` and `Retry.Cancelled`, and answers `None`. `apply_foreign` then advances
  the mark past the entry without recording it as stepped aside, and `overridden_since` (used by
  startup recovery) can miss a peer's newer entry and publish a stale unpublished op over it.
- **Last-sync mark.** `File_store.read_last_sync_key` answers `None` on any error, so a transient
  local read error makes the next pass consider the whole journal (a full rebuild for a manual
  sync).
- **Integrity readers.** Integrity and corruption readers turn read errors into "no good copy" or
  "no marker"; they only report, so nothing is deleted on their say-so.
- **Breaker evidence.** Every `Transient` failure calls `Health.lost`, including 429, 503 `busy`
  and exceptions nobody classified inside a request.
- **Peer permanent kinds.** The http-proxy server maps every permanent kind to 409 with prose;
  the client reads it as a generic permanent failure.
- **Deadlines.** `Ipc.send` (CLI) and Swift `sendSync` have no deadline; a wedged daemon hangs
  `tsync stop`, `pause`, `cache`, `versions`, item resolution in the CLI, and the extension's
  read-only probe. A single-member domain asks its only member through the full ladder; only
  uncached reads are deadline-wrapped, so `ensure_cached` and listings can wait many minutes
  (up to about 40 min against a stalled peer with a 300 s stall window).
- **Frontend stop.** The File Provider frontend's stop does not request `Shutdown` and drains its
  domains sequentially, so with a store down it can hang.
- **Clocks.** Stall timeout, breaker and metrics windows use the wall clock
  ([../01-core.md](../01-core.md) B.3.4).
- **CLI exit.** The store's considered-answer error exits 125 as "internal error, uncaught
  exception" with a stack trace, although it is user-actionable.
- **S3 conditional conflicts.** AWS's retryable 409 `ConditionalRequestConflict` is treated as
  permanent, and the claim caller then falls back to a plain PUT.
- **Local driver errno table.** The same errno is transient on `put` and permanent on `get`.
- **Revoked GCS keys** are classified transient.

## 3. Lessons worth keeping

- A result type per call, rather than exceptions, would make "absent" and "could not look"
  different constructors, so a catch-all could not turn one into the other. Most of the
  departures above are `with _ -> None` handlers.
- Drains are raced against the grace rather than cancelled: cancellation once reached the
  metadata queue as a failure and degraded it.
- 409 for permanent refusals at the peer replaced 5xx, which made clients climb the ladder eight
  times for a name that would never exist (commit 48e797b4).
- A one-second daemon restart used to latch a macOS domain offline; that is why only
  `unreachable` latches and transport failures never do.
- An ordered queue blocked by one `ENOTEMPTY` stalled for eight hours before unexplained
  failures in ordered work were made to park (memory note *foreign-rename-enotempty-loop*).

## 4. Further departures from the round-2 spec

- There are no `busy` or `paused` codes; `Ipc_error` has the eight original codes, and a paused
  domain or a throttling store surfaces as `internal` or `unreachable`.
- Deferred replica/backfill jobs that fail permanently are dropped (`Poison.Drop`) with an
  in-memory degraded flag, not parked with a durable marker.
- The File Provider router answers an unserved domain with a code-less error, read as
  `internal`.
- Bulk-delete per-key errors and network-filesystem errnos are not classified as the spec
  requires; a local store has no breaker cell of its own.
- The http-proxy server sends no `x-tsync-kind`, and the client does not read it.
