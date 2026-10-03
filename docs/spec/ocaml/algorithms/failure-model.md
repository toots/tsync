# Failure model — OCaml implementation notes

Companion to the language-neutral spec [../../algorithms/failure-model.md](../../algorithms/failure-model.md).
Not normative. Finding numbers refer to [the 2026-10-01 review](../../../review/2026-10-01-rewrite.md).

## Where each abstraction lives

| Spec | Code |
|---|---|
| Kinds, the failure value (§3) | `Fail.kind`, `Fail.t` (`kind`, `op`, `reason`, `repair`, `retry_after`, `stalled`), `exception Fail.E` (`lib/core/fail.ml`) |
| STOPPING, CANCELLED | `Stop.Stopping` (`lib/core/stop.ml`), `Rt.Cancelled` (`lib/core/rt.ml`); a job's own cancel is `Cancel.check`, `Cancel.race` |
| Classifying an exception | `Fail.classify`: `Fail.E` as it is, `Unix_error` through `Fail.kind_of_errno`, `Rt.Timeout` as a stalled LINK, anything else UNEXPLAINED |
| Local filesystem table (§4.1) | `Fail.kind_of_errno`, `Fail.of_unix` |
| HTTP object stores (§4.2) | `Object_store.status_failure`, `per_key_failure` (`lib/store/object_store.ml`); the drivers under `lib/store/s3`, `lib/store/gcs` |
| Peer store (§4.3) | `lib/store/http_proxy/http_proxy_client.ml`, reading `x-tsync-kind` through `Fail.of_wire_kind` |
| Stall detector | `Rt.with_stall_timeout` in `Client.request` (`lib/http/client.ml`), raising LINK with `stalled` |
| Ladder (01 §7) | `Retry.ladder`, `Retry.attempts`, `Retry.delay` |
| Breaker (01 §8), link evidence (§6) | `Health` (`lost`, `answered`, `probe_lost`, `check`, `timed_out`), fed only by `Retry.ladder`; `Retry.until_held` |
| Composite aggregation (§4.4) | `Composite`: `ask`, `walk`, `read`, `unreachable_of`, `guard` (`lib/store/composite.ml`) |
| Queue policy (§7.1) | `Dqueue.failed`: `Fail.retryable`, park otherwise; UNEXPLAINED parks an ordered queue and retries a keyed one |
| Inbound peer entry | `apply_pass` (`lib/sync/engine.ml`): a retryable kind aborts the pass, any other steps the entry aside (`stepped_aside`, `Engine.unapplied`) |
| Link failure seen by the queues | `Outbound.note_link_failure`, `close_gate`, `wait_gate` |
| Read deadline | `Cache.read_deadline`, `within_deadline` (`lib/checkout/cache.ml`): the wait ends DEADLINE, the fetch continues |
| Request deadlines (§8) | `Ipc.request_deadline`, `client_deadline`, `advisory_deadline`; `bounded` (`lib/owner/handler.ml`) |
| Client codes (§7.2) | `Fail.code`, `Fail.kind_of_code`; `Ipc.failure` puts the code on every failed reply |
| Kernel mapping (§7.3) | `Fail.errno`, used by `lib/frontends/fuse/fuse_mount.ml` |
| Peer server mapping (§7.4) | `Fail.wire_kind`; 409 with `x-tsync-kind`, 503 for load, 500 otherwise (`lib/frontends/http_proxy/store_server.ml`) |
| CLI exit (§7.5) | `run` in `bin/cli.ml`: 1 for a classified failure with its sentence, 125 for UNEXPLAINED |
| Stop | `Stop.request`, `Stop.grace`, `Stop.sleep`, `Stop.wait` |
| Durable failure state | the failure noted in a record by `'job Dqueue.kind.note` (`Wal.record.last_error`, the copy job's `last_error`); `<id>.bad` records; `Corruption_marker` |

One exception type carries every kind. A layer never matches on text: it reads `kind`, and the layer
with the evidence sets it.

## Where the code departs from the spec

- **The DEADLINE split always answers `internal`** (finding 126). `Fail.code Deadline` is `internal`,
  and `bounded` does not look at whether a store was silent for the whole wait, so a client never
  latches offline on a deadline.
- **An undecodable last-sync mark is read as no mark** (finding 125). `Mark.read` warns and answers
  `None`; the file is not set aside, and the next pass holds for a full rebuild.
- **Stalled queues look like busy ones** (finding 43). Status counts retrying and parked records; a
  worker waiting at a closed gate is not told apart from one that is working.
- **The supervisor asks an owner for its stats under the owner's own deadline** (finding 107), so a
  slow owner shows as "no answer" instead of its coded answer.
- **The poller retries a failed pass every few seconds and logs each one** (finding 145):
  `Outbound.retry_floor` with no backoff.
- **An unspawnable child is retried every 0.5 s** (finding 127).

## Learnings

- "Could not look" stays a raised failure all the way up. `Composite.read` raises the first
  candidate's failure as UNREACHABLE when nobody answered, and a copy's miss stands for the domain only
  when no main before it failed (pitfall A-4.1).
- A batch read of a member that is held down raises instead of answering nothing: read as "every key
  absent", it turned live folders into orphans (finding 26).
- A memo records only a considered answer. A clock-skewed 401 and an unparseable 2xx are not answers
  about the domain (findings 27, 60).
- A loop body in a background fiber catches everything except `Stop.Stopping`: an exception that
  escapes ends the fiber with one log line and nothing restarts it (findings 7, 8, 124).
- LOAD is an answer: the ladder calls `Health.answered` for it, and only LINK counts against the
  breaker. A stall is LINK with `stalled` set, which is what `Health.timed_out` tallies for the uplink
  governor (finding 56).
- The breaker runs on `Rt.now`, the monotonic clock; `Health.create ?now` replaces it in tests.
- `Retry` seeds `Random` at load: unseeded, every client draws the same jitter and retries in step
  (finding 116).
