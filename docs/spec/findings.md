# Findings

While the spec was being extracted, the subsystem readers flagged behaviour that looked wrong. A second,
adversarial reading then checked each flag against the code at commit `4c32fa96`, trying to find the
guard that makes it safe. Nothing was run except where noted (G11 was reproduced with a copy of the glob
matcher). The verdicts are:

- **CONFIRMED**: the claim holds, with a concrete interleaving or input.
- **PARTIAL**: part of it holds, and the entry says which.
- **REFUTED**: something in the code makes it safe.

A rewrite should decide on each finding rather than reproduce the current behaviour. Each spec's
open-questions section lists further inconsistencies that were not verified.

## Ranked summary

| ID | Area | Finding | Verdict | Severity |
|---|---|---|---|---|
| S1 | Android | Auto Backup is on by default and copies `config.json` (shared secret, cloud keys) to the user's Google backup | CONFIRMED | security |
| S2 | share | The share browse page embeds the shared folder's name as unescaped JSON inside `<script>`: stored XSS on the share origin | CONFIRMED | security |
| S3 | http-proxy + local | A signed key containing `..` escapes a local store's root: any domain's secret reads, writes and deletes files outside the store as the proxy's user | CONFIRMED (reproduced) | security |
| S4 | config | Domain names are not validated: `shares`, `corrupted`, `verify-jobs`, `gc-jobs`, or names with `/` or `..`, break prefix confinement (a domain named `gc-jobs` can queue deletes of another domain's chunks) | CONFIRMED (reading) | security |
| S5 | http-proxy | Any domain's secret can read, write or delete every share manifest in its store, and publish a link to another domain's files in the same store | CONFIRMED (reading) | security |
| S6 | macOS | The daemon accepts arbitrary `staging` and `dest` paths from socket clients: a compromised sandboxed extension reads and writes outside its sandbox | CONFIRMED (reading) | security |
| F7 | checkout | Several processes write one cache root with only per-process locks; a peer delete applied by the daemon parent can discard a staged edit just made through FUSE | CONFIRMED | data-loss |
| F9 | checkout | A staged edit deletes the old body before writing the new sidecar; a crash in between drops the whole staged edit | CONFIRMED | data-loss (crash) |
| F2 | GC | http-proxy clients never promote chunks; with the session dedup memo, a chunk they reuse during a GC run can be reclaimed | CONFIRMED | data-loss |
| F1 | GC | A writer checks for an open GC run once, before publishing; a run opening in between can reclaim a deduplicated chunk | CONFIRMED | data-loss (narrow) |
| H7 | Android | Camera backup saves the pass-start MediaStore generation, so unsettled and failed photos are never retried | CONFIRMED | data-loss |
| H9 | Android | Child-by-name lookups read only 1000 entries; share-sheet numbering can overwrite an existing file | CONFIRMED | data-loss |
| F10 | checkout | `tsync cache --prune` reaps the bodies of set-aside (`.bad`) edits | PARTIAL | data-loss (on demand) |
| F8 | checkout | No fsync for cache sidecars, WAL records or the durable queue (the local backend and export do fsync) | PARTIAL | data-loss (power loss) |
| F4 | sync | The size-capped applied-log prune can drop the newest shard; re-applied deletes can remove a file a later peer write restored | CONFIRMED | correctness |
| F6 | sync | Reading a journal entry turns every error into "no entry"; in crash recovery this can publish a stale delete over a peer's file | CONFIRMED | correctness |
| F3 | sync | The daemon never detects that the journal was pruned past its mark; missed changes stay missed until `tsync sync` | CONFIRMED | correctness |
| G2 | config | Duplicate backend names are accepted; two targets with the same name share one on-disk deferred queue | CONFIRMED | correctness |
| G5 | backends | `put_if_absent` against an older http-proxy server overwrites the real winner and reads as "won" | CONFIRMED | correctness (mixed versions) |
| G7 | Android | Deferred replica/backfill jobs left by a killed app process are never replayed | CONFIRMED | correctness |
| G8 | daemon | `tsync pause` does not stop the parent from applying peer changes, and is not persisted | CONFIRMED | correctness |
| G11 | core | Glob `**/.git` also matches `foo.git`; `import --exclude` skips too much | CONFIRMED | correctness |
| H8 | Android | `isChildDocument` rejects every subfolder, so tree grants reach only the top level | CONFIRMED | correctness |
| H10 | Android | The Kotlin side drops error codes: "not found" and "unreachable" look alike | CONFIRMED | correctness |
| H11 | Android | Folder "make available offline / online only" does nothing but reports success | PARTIAL | correctness |
| F5 | sync | The dedupe set is loaded once per process; a daemon and a manual `tsync sync` can re-apply each other's entries | PARTIAL | robustness |
| G9 | CLI | The CLI's IPC client has no timeout; a wedged daemon hangs `stop`, `pause`, `cache`, `versions` | CONFIRMED | robustness |
| G10 | macOS | The File Provider frontend's stop has no grace bound and can hang with a backend down | CONFIRMED | robustness |
| G12 | core | Stall timeout, health and metrics use the wall clock; a clock step at boot marks backends unhealthy | CONFIRMED | robustness |
| G4 | ops | `rsync` holds its entry list in memory; an in-domain rename can fail on a store-only manifest | CONFIRMED | robustness |
| H3 | macOS | A file's contentVersion changes when its upload finishes, so the system re-fetches it (from cache) | CONFIRMED | robustness |
| H4 | macOS | `tsync fileprovider reset` stops the daemon and never restarts it | CONFIRMED | robustness |
| H5 | macOS | Evicting or restoring the domain root reports success but changes nothing | CONFIRMED | robustness |
| H6 | macOS | The Swift IPC client has no timeout; one flag is shared across tasks without a lock | CONFIRMED | robustness |
| H12 | Android | No journal poller; a folder with a stuck metadata record is never re-read | PARTIAL | robustness |
| H2 | macOS | Router errors omit `code`; they are retried as `internal`, never mis-reported as unreachable | PARTIAL | robustness |
| G3 | GC | The in-process GC guard races, but nothing runs two collections in one process today | PARTIAL | latent |
| G1 | config | The docs say unknown keys pass through; the parser refuses them, except inside frontend objects | PARTIAL | docs / robustness |
| G6 | backends | The proxy's HEAD drops the etag; nothing reads it today | CONFIRMED | latent |
| H1 | macOS | Routing by display name vs a dashed identifier | REFUTED (only a name-collision edge remains) | robustness |

---

## S3 — Path traversal through the http-proxy into a local store

**CONFIRMED by reproduction** against an isolated proxy over a scratch local store. Domain confinement
(`within`, `lib/app/frontends/http_proxy/http_proxy_frontend.ml:525`) only checks that a key starts with
the domain's root. `Stored_key.listed` is the identity (`lib/core/stored_key.ml:19`), and the local
driver joins the key onto its root without normalising `..` (`resolve`,
`lib/backends/drivers/local/local_backend.ml:142`). A signed request for
`tsync/<domain>/../../<path>` therefore reads, writes or deletes `<path>` relative to the store, with the
proxy's privileges. A key outside the domain root was correctly refused. Together with S1, a leaked
phone config becomes write access on the proxy host. The same root cause probably affects mirror,
backfill and GC writes into a local store from keys listed on another store (not checked).

Fix: reject keys with empty, `.` or `..` segments or a leading `/` at the proxy and in `Stored_key`, and
make the local driver refuse any path that resolves outside its root.

## S4–S6 and other security gaps (verified by reading)

- **S4:** `conf_parsing.ml:259` does not validate domain names.
- **S5:** the share prefix is routed to any verifying route; the lambda share handler does not check a
  manifest's `key` against its `domain` (`lambda/handler.py:368`).
- **S6:** `ipc_handler.ml:680-712`, `data.ml:1017,1206,1251`.
- **S2 impact:** the status page keeps the secret in `sessionStorage` (`tsync-secret`); injected script
  reads it only if the status page was used earlier in that tab, otherwise it can show a fake login on
  the genuine origin.
- Request bodies are read whole before routing, authentication and admission
  (`http_proxy_frontend.ml:1038`); the server has no inbound request timeout.
- `/stats` accepts any route's secret and reports every domain (`:968-983`).
- FUSE `allowOther` mounts without `default_permissions` and never checks the caller: every local user
  gets read, write and delete.
- Replay within the ±300 s window is not harmless when requests interleave (a replayed DELETE or PUT
  undoes a later write). Responses are not authenticated; over plain HTTP a man-in-the-middle can forge
  content, listings and journal entries. Android allows cleartext traffic.
- Chunk keys (two seeded XXH3-64) are not cryptographic, and normal read paths do not verify them.
- The HMAC secret is never generated or strength-checked.
- The wizard writes `config.json` before chmod 0600 (`wizard.ml:876-881`); masking fails open for field
  names the spec does not know (`field_spec.ml:14`).
- `tsync share --token` accepts any non-empty hex and overwrites an existing link; there is no revoke.
- The proxy always binds all interfaces.

What holds: constant-time HMAC compare with a ±300 s window over method, path, query and body hash; TLS
clients verify certificates and hostnames; share tokens are 16 random bytes and share paths reject `..`;
terraform blocks public bucket access and scopes function roles by prefix.

## S1 — Android Auto Backup copies the config with its secrets

**CONFIRMED.** No `android:allowBackup` attribute and no backup-rules XML exist under `android/`, so
Auto Backup uses its default of enabled. The app writes its config to
`filesDir/.config/tsync/config.json` (`android/app/src/main/java/org/feverdreamtv/tsync/Config.kt:30`),
and Auto Backup includes the files directory. The http-proxy shared secret, and any S3/GCS keys in the
config, are copied to the user's Google Drive backup and to new devices during a device-to-device
transfer. Fix: `android:allowBackup="false"`, or backup rules that exclude the config.

## S2 — Stored XSS in the share browse page

**CONFIRMED** by reading both implementations. The browse page template contains
`const DATA = __SHARE_DATA__;` inside a `<script>` element (`lambda/browse.html:243`). Both
servers substitute a JSON object holding the share's title, which is the shared folder's name:
- the http-proxy share server uses `Yojson.Safe.to_string` (`lib/app/frontends/http_proxy/share_server.ml:575-586`);
- the lambda handler uses `json.dumps` (`lambda/handler.py:477-486`).

Neither escapes `<` or `/`, so a folder named `x</script><script>…</script>` closes the script
element and runs arbitrary script on the share origin for anyone opening the link. An attacker
needs to control a folder name that is later shared: the sharer, or any client writing to the
domain. On the http-proxy server, the same origin also serves the status page that the shared
secret unlocks. The `__OG_*` substitutions are HTML-escaped, but they run before `__SHARE_DATA__`,
so a title containing the literal text `__SHARE_DATA__` is also substituted inside the meta tag.

Fix: escape `<`, `>`, `&`, U+2028 and U+2029 as `<`-style sequences when embedding JSON in
HTML, or deliver the data in a non-executable `<script type="application/json">` element read with
`textContent`, and substitute in a single pass.

## Storage, sync and checkout


### F1 — `promote_all` checks the GC marker once, before `put_manifest`

**Verdict: CONFIRMED.**

Evidence:
- `lib/domain/remote/remote.ml:202-203`: `Space.promote_all ~count chunk_key` runs, then `St.put_manifest`. Nothing between them and nothing after rechecks.
- `lib/domain/remote/store/gc/collection.ml:294-305`: `promote_all` reads the marker once (`read_run`). If it gets `None` it returns without promoting anything.
- The writer and GC share no lock. The GC lockfile (`gc.ml:185-199`, `lock_path`) only excludes other collectors.
- The GC open sequence is in `gc.ml:636-653`: it saves the `Opening` marker, then `open_space` renames `chunks/` to `chunks.from/`, then `namespaces root` does a readdir, then it saves `Marking`. Marking lists each namespace only when it reaches it.

Interleaving:
1. The writer dedups chunk X (a memo hit, or `head` found it in `chunks/`).
2. `promote_all` calls `read_run` and gets `None`.
3. GC writes the marker and renames the whole root, so X is now under `chunks.from/`.
4. GC either enumerates namespaces (a new folder-id namespace is missed) or marks the manifest's namespace.
5. The writer's `put_manifest` lands.
6. Closing (`orphans_in_shard`, `gc.ml:319-345`) does `head` on X in the surviving space, misses it, and deletes it.

The window is small: it runs from the writer's marker read to the moment its main-store write lands. Nothing closes it.

- Test: no. `tests/scenario/gc/gc.ml` (lines 91-128) only covers writes made while a run is already open.

### F2 — http-proxy clients promote nothing during a run

**Verdict: CONFIRMED.**

Evidence:
- The client side has no promotion path:
  - `collection.ml:85-88`: `local_root` is taken from the main's `local_path`.
  - `http_proxy_backend.ml:396`: that path is `None` for a proxy.
  - `collection.ml:258-260`: `promote` therefore returns `false` without renaming anything.
  - `read_run` still goes through the proxy and sees the marker, so `promote_all` loops and does nothing.
- The server side has no promotion path either:
  - `http_proxy_frontend.ml:645-650`: `Put` is a plain `B.put`.
  - No code under `lib/app/frontends/http_proxy` references `Collection`, `Space` or `promote`. A grep over `lib` finds no other promotion path.
- Refinement of the claim:
  - `head` through the proxy is *safe*. The client's `Space.head` falls to `B.head_opt (L.key …)` (`collection.ml:173-174`), and the server answers with a raw `head` on `chunks/…`. A chunk only in `chunks.from/` therefore reads as absent and gets re-uploaded into the surviving space.
  - The unsafe path is the session memo (`chunk_store.ml:22-26`). `Dedup.known` is process-lifetime, capped at 100k keys and reset only when full.
- Interleaving:
  1. A daemon talking to a proxy uploads chunk X before a run.
  2. GC opens, which moves X to `chunks.from/`.
  3. The same daemon publishes another file containing X, for example a copy. The memo hits, so no upload happens.
  4. `promote_all` is a no-op.
  5. The manifest lands in a namespace that marking has already passed, or in a new folder-id namespace.
  6. Closing reclaims X.

  The window lasts as long as marking does (minutes to hours), not milliseconds.
- `gc.mli` says an http-proxy *main* is refused. That applies to the collector, not to remote writers of a local main.
- Test: no.

### F3 — the daemon never checks `cannot_bridge`

**Verdict: CONFIRMED.**

Evidence:
- The only caller is `lib/domain/ops/resync.ml:232`, which `Resync.run` uses (`tsync sync`, `cmd_sync.ml`).
- `lib/domain/sync/replay.ml:249-322` (`apply_foreign`, the poller's pass) lists the journal and applies what is unhandled within the 30-day horizon. It never compares its mark with the oldest key.
- `sync_poller.ml` and `domain_engine.ml:166-170` (`converge`) run no resync at start.
- `retention.mli:12-15` states such a client "must resync". The only surface that could hint at it is diagnostics (`diagnostics.ml:175-208`), which reports "behind" but has no pruned-gap signal.

After `tsync expire` prunes past a long-offline client's mark, the daemon applies the surviving entries and permanently misses the pruned ones: missed deletes, renames and puts. The mirror is the source of truth for reads, so the divergence persists until `tsync sync --full`, or a plain `tsync sync`, which does run the check.

- Severity: correctness. It can escalate: a later local edit of a stale file publishes over the peer's newer version, which is kept only in version history.
- Test: none for the daemon path.

### F4 — the byte-capped applied-log prune drops newest or in-window shards

**Verdict: CONFIRMED (both parts).**

Evidence:
- `lib/domain/journal/applied_entries.ml` (`prune`, end of file) folds newest-first. A shard is dropped when `mtime < cutoff || held + size > keep_bytes`, and the fold continues past a drop.
- The cap is `applied_keep_bytes = 64 MiB` (`maintenance_lwt.ml:62`), applied daily (`Periodic 86400`).
- Trace:
  - Sorted `[prev 40 MiB, cur 70 MiB]`: `cur` is dropped (0+70 > 64), then `prev` is kept (0+40 ≤ 64). The *newest* shard goes and an older one stays, which contradicts the "never a hole" comment.
  - `[prev 40, cur 40]` drops `prev` while its keys are still inside the 30-day window.
- Holes deeper in the past cannot happen in practice. The mtime cutoff removes every shard older than the previous month.
- Consequence:
  - `handled_set` (`replay.ml:213-223`) is loaded once from `Js.applied_keys`. After a restart, the pruned keys that are still ≥ horizon and still in the journal are re-applied.
  - A re-applied `Put` is idempotent: `fetch_peer`/`R.fetch_manifest` reads the *current* store manifest (`file.ml` Foreign).
  - A re-applied `Delete` is not. `Resolve.Arrival.Delete {staged=false} -> Apply [Remove_file]` (`resolve.ml:65`) consults nothing in the store. If a later peer `Put` on the same path is still in the set (newer shard kept), the old delete removes the file locally and nothing brings it back. The same applies to renames.
- Trigger: a month with more than 64 MiB of applied-log records, which a large import produces.
- Test: `tests/unit/applied_entries/applied_entries_test.ml:164` only tests `keep_days:0`. The byte cap is untested.

### F5 — the dedupe set is loaded once per process

**Verdict: PARTIAL.** The mechanism is real, but the named process pair is wrong.

Evidence:
- `replay.ml:213-223` loads `handled` once and never re-reads it. Another process's `note_applied` appends are therefore invisible.
- The FUSE child does *not* apply peer entries:
  - `Domain.start` (`domain_engine.ml:143-150`) starts only Sq/Mq.
  - The poller runs only in `converge` (`domain_engine.ml:166-170`), which runs only in the launcher parent (`launcher.ml:253-340`). The "FUSE child vs converging parent" example therefore does not apply.
- The real pair is the daemon parent and a one-shot `tsync sync`. `Resync.incremental` calls `Rp.apply_foreign` (`resync.ml:184-188`), and `cmd_sync.ml` has no running-daemon guard.
- Harm is limited. The daemon re-applies an entry the CLI already applied. Puts refetch the current manifest, and entries are replayed in key order, so re-applying *both* an older and a newer entry converges. Divergence needs the F4 shape: an older entry unknown while a newer one on the same path is known, for example a late-visible entry.
- The concurrent overlap of the two passes is the F7 problem.
- Severity: robustness, with low-probability correctness impact.
- Test: no.

### F6 — `get_journal_entry` swallows every error as `None`

**Verdict: CONFIRMED.** The impact is larger than stated.

Evidence:
- `file_store.ml:208-214` uses `Io.catch … (fun _ -> Io.return None)`. That also swallows `Shutdown.Stopping` and `Retry.Cancelled`.
- In `apply_foreign` (`replay.ml:294-296`), `None` becomes `return_unit`:
  - The entry is not remembered, so it is retried on a later pass. The retry comes only at the ≤60 s sweep, because `last_version` is recorded after the "clean" pass (`sync_poller.ml:59-60`).
  - The mark still advances past it (`replay.ml:314-316`), and the entry is never recorded in `stepped_aside`. A persistently unreadable entry is therefore invisible in `unappliedEntries`.
- Second caller, not in the finding: `overridden_since` (`replay.ml:49-66`), used by `replay_unpublished` during reconcile.
  - A transient read failure hides a peer's *newer* entry, so our stale unpublished op is not filtered.
  - It is re-applied and published over the peer's change. Example: our crashed `Delete` of P is published after the peer re-created P, which deletes the peer's file from the store. Recovery is only possible through version history.
- Severity: correctness, with an overwrite risk in the recovery path.
- Test: no.

### F7 — locks are per process, and several processes write one cache root

**Verdict: CONFIRMED.**

Processes that write the same cache root concurrently:
1. **Launcher parent** (`launcher.ml:253-340`, `converge`), once per machine per domain:
   - `start_queue`: its own Sq/Mq, plus `Rp.reconcile` over *all* WAL records and `adopt_unrecorded` over all staged sidecars.
   - The poller (`apply_foreign` → mirror, staged discard, applied log, last-sync mark).
   - Maintenance: applied prune, chunk cap, metadata retry.
2. **Each frontend child** (`launcher.ml:358-398`; one process per binding when the topology is `Process_per_binding`):
   - Local mutations under its own `meta_mutex` and `with_key`.
   - Its own Sq/Mq over the shared WAL dir.
3. **One-shot CLI commands run alongside the daemon**:
   - `tsync sync` runs reconcile and the drains, then either `apply_foreign` or a full mirror rebuild. There is no daemon guard; `refuse_if_metadata_owed` only checks WAL records.
   - Imports behave the same way.

The launcher comment admits these are shared "and arbitrated between none of them" (`domain_engine.ml:20-25`, `launcher.ml:245-252`). The only cross-process locks in `lib` are the GC lockfile and the `durable_queue` claim (deferred replica jobs, `durable_queue.ml:21-80`). The mirror, staged tree and metadata WAL have none. `meta_mutex` (`file.ml:184`) and `with_key` (`data.ml:415`) are in-process Lwt mutexes.

Concrete data-loss interleaving (parent applies a peer `Delete A`, child writes A):
1. Parent, in `apply` under *its own* meta lock (`file.ml:978-988`), runs `gather` for `Delete`: `Mfs.exists A` returns false (`file.ml:824-828`).
2. The decision is `Remove_file` (`resolve.ml:65`), and parent `enact` calls `cancel_upload` (a no-op for the child's queue), then `clear_local A` → `evict` (I/O yield) (`file.ml:230-233`).
3. Child: the FUSE write → `File.write` → `D.write` → `with_key` (child's mutex) → `write_locked` stages a body and sidecar for A (`data.ml:640-701`).
4. Parent: `D.discard_staged A` (`with_key` in the parent, a different mutex) deletes the child's staged bytes and sidecar (`data.ml:763-770`).

The user's unpublished edit is gone. The designed outcome for a peer delete against a staged local edit is `Skip Ours_publishes_later` (`resolve.ml:64`).

Note: `File.write` does not take `meta_mutex` even in-process (`file.ml:1143-1147`), so this check-then-act also races *within* one process. A per-domain file lock around foreign apply would not close it on its own.

Other cross-process effects:
- `cancel_upload` (`file.ml:75`) only reaches the calling process's queue. An upload resumed by the parent's reconcile is not cancelled by a child's write.
- A `tsync sync` reconcile can `redo_local` or `resume_meta` a child's in-flight `Intent`/`Prepared` record, and `adopt_unrecorded` can re-queue a staged file whose record the child has not yet written.

- Severity: data-loss.
- Test: none found. The forked tests cover ids and folder ids, not mirror mutation.

### F8 — nothing fsyncs

**Verdict: PARTIAL.** It holds for the cache, the WAL and the queue, but not repo-wide.

Evidence:
- `lib/local/io/fs.ml:90-101`: `with_temp_rename`/`atomic_write` is a temp file plus rename. `write_file` (`io_lwt.ml:96-99`) is `Lwt_io.with_file`, with no fsync. `atomic_write_at` (`fs.ml:128-141`) has none either.
- This is used by staged sidecars (`staged_manifest.ml:189`), WAL records, and `durable_queue.ml:134`.
- The claim that *nothing* fsyncs is wrong:
  - The local backend fsyncs before rename (`local_backend.ml:25-38`, `stage`), so the store side is covered.
  - Export fsyncs (`export.ml:379-394`).
- `staged_body`/sidecar/WAL crash claims hold for a process crash, not a power loss. A new WAL record or sidecar can be left zero-length or torn. The staged sidecar decoder then sets the file aside as `.bad` (see F10), and the WAL decodes garbage as an empty Intent that reconcile deletes (spec 04 §9.9).
- Severity: data-loss on power loss only.
- Test: no.

### F9 — staged edits delete the old body before writing the new sidecar

**Verdict: CONFIRMED.**

Evidence:
- `data.ml:572-637` (`ensure_group_body`, slow path):
  1. It creates a new body and copies members into it.
  2. At its end it calls `Sb.forget` on stale bodies (`data.ml:633-637`).
  3. `write_locked` then writes the rest of the chunk data, and only at its end calls `Mfs.write key (mutated st)` (`data.ml:697-698`). The window spans the remaining `Sb.write`s plus the sidecar rename.
- `truncate_locked` (`data.ml:704-718`) forgets the dropped bodies before the final `Mfs.write` (`data.ml:747`).

A crash in that window leaves:
- the on-disk sidecar naming a deleted body, and
- the new body holding the previously staged bytes, referenced by nothing (it becomes an orphan).

Escalation:
- A read of those members fails with ENOENT.
- The upload reading the staged bodies raises `Unix_error ENOENT`. `sync_queue.ml:81-82` treats that as "staged bytes gone, nothing owed" and **abandons the record**. The whole staged edit is lost, not only that group.
- On the next start, `adopt_unrecorded` re-queues the sidecar, and it fails the same way.

This contradicts the comment on `write_locked` ("Bytes land before the staged manifest…").

- Severity: data-loss on process crash.
- Test: none. The crash scenarios in `tests/scenario/sync` (`CrashBeforeCommit`) do not cover this window.

### F10 — the orphan sweep reaps bodies that a `.bad` sidecar names

**Verdict: PARTIAL.** The mechanism is confirmed, but "the 1 h sweep" is not periodic.

Evidence:
- `staged_manifest.ml:215-224`: `fold` skips names ending in `.bad`, and also silently skips any sidecar that fails to parse (`exception _ -> acc`).
- `uuids ()` (`staged_manifest.ml:256-263`) therefore omits their bodies.
- `staged_orphans.ml` (`run`) unlinks every body not in `live` whose mtime is older than the cutoff.
- `read` (`staged_manifest.ml:151-172`) renames an unreadable sidecar to `.bad`, with the comment "Unsynced user data: set aside rather than dropped". The bodies that hold that data are then reclaimable once they are more than an hour old.
- Correction: the sweep's trigger is `` [`On_demand] `` only (`maintenance_lwt.ml:84-90`). The daemon's `run_maintenance` schedules only `` `Periodic `` tasks (`domain_engine.ml:110-129`). The reaping therefore happens on `tsync cache --prune` (`cmd_cache.ml:94-124`), not every hour. The 1 h figure is the grace (`default_staged_grace = 3600.`).
- Severity: data-loss of set-aside edits (when the prune command runs).
- Test: no. `staged_codec_test.ml:50` only skips `.bad` files when listing.

## Ops, config, backends and daemon


### G1 — DOCUMENTATION.md says unrecognised fields pass through; parser refuses them
**PARTIAL.**
- The docs say it in two places: `DOCUMENTATION.md:142-143` and `:1042`.
- The top-level config, domain and uplink/link objects refuse unknown keys:
  - `refuse_unknown` is defined at `lib/domain/config/parsing/conf_parsing.ml:85-100`.
  - It is called at `:399` (config), `:262` (domain) and `:325` (uplink/links).
  - It came in with commit 5e532514 ("config: a key nothing reads is refused").
- Backend keys are refused only when the driver's spec is known (`:154-160`). That comes through `driver_fields`, which is set from `Backend_lwt.spec_for` at `lib/domain/config/domain/domain.ml:45-50`.
- Parts of the docs sentence are still true:
  - **Frontend options are not checked.** `parse_frontend` (`conf_parsing.ml:190-208`) keeps every key as an option. `{"type":"fuse","mountPoin":"/x"}` is accepted, and `mount_point_of` then silently uses `~/tsync/<domain>`.
  - A backend or frontend value that is a float, object or null is silently dropped (`:165-173`, `:201-206`).
- So the docs are stale for the config, domain, uplink and backend levels, and still accurate for frontend objects.
- **Test:** `tests/unit/conf/conf_test.ml` covers the refusal. Nothing covers frontend keys passing through.

### G2 — Duplicate backend names not rejected; builder keys tables by name
**CONFIRMED, and worse than stated.**
- Neither `parse_domain` nor `validate_roles` (`conf_parsing.ml:241-301`) checks for unique names.
- `build_backends` (`domain.ml:58-109`) keys three tables by `bc.name` with `Hashtbl.replace`: `traffic`, `admissions` and `built`. Each leaf's store still gets its own counters (`make_backend ~traffic:t`, `:72`). Everything that reads the tables back gets the last duplicate's entry:
  - The member's `?traffic`, `?pending`, `?in_flight`, `?degraded` and `readable` (`:128-157`).
  - The target's `~room_for` gate (`:94`). That is the wrong link's admission when the two duplicates sit on different links.
- **More serious:** the deferred queue's directory is `log_dir ~root ~name` = `<data>/deferred-pending/<domain>/<escaped name>` (`lib/backends/api/deferred.ml:138`, `:249-250`). Two replica or backfill targets with the same name share one durable log:
  - In the daemon (`resume:true`), each queue's rescan recovers the other's records and runs them against its own backend.
  - `Durable_queue.claim` merges in-process (`lib/core/durable_queue.ml:32-43`), so nothing detects the clash.
- `Backend.named_exn` (`lib/backends/api/backend.ml:170-183`) does report "ambiguous", but only when a command names the backend (`--source`, mirror).
- **Test:** none.

### G3 — gc `held` set only after an await; same-process collections not excluded
**PARTIAL: the mechanism is real, but nothing reaches it.**
- `take_lock` (`lib/domain/ops/gc.ml:181-196`) checks `!held` and then awaits `Files.ensure_parent` and `Lockfile.take`, which runs `Lwt_unix.openfile`/`lockf` as pool jobs (`lib/lwt/domain/ops/gc_lwt.ml:6-19`). Only after that does it set `held := true`.
- So two `start` calls on one `Make(C)` instance could both pass the check. Both `lockf` calls would then succeed, because POSIX record locks merge within a process. Also, `drop_lock` closing either fd releases both.
- **Refutation of reachability:**
  - `held` lives inside `Make (C)` (`gc.ml:66`, `:171`), so each functor application has its own flag.
  - The only production caller is `tsync gc` (`lib/app/cli/cmd_gc.ml:146`). It applies `Gc_lwt.Make` once per process run and starts at most one collection.
  - Neither the daemon nor any IPC path runs gc.
- Cross-process exclusion via `lockf` holds.
- Latent: it becomes real only if gc is ever driven in-process, for example from the daemon.
- **Test:** none for same-process exclusion.

### G4 — rsync holds its entry list in memory; `Rename_in_domain` does `Option.get` on the mirror manifest
**CONFIRMED (both parts).**
- **Memory:** `entries_of` (`lib/domain/ops/rsync.ml:327-363`) builds the full `(rel, kind)` list in RAM for both the Local and Domain sources. Import and mirror use `Listing` spools instead (for example `import.ml:74-77`).
- **`Option.get`:**
  - `manifest_at` (`rsync.ml:162-166`) falls back to `R.fetch_manifest` from the store when `Mf.published` is `None`. So `decide` can yield `Rename_in_domain` with `move=true` on a store-only manifest (`:66`).
  - `act` then re-reads only the mirror (`:398`) and calls `Option.get m` (`:403`). That raises `Invalid_argument "option is None"`.
  - The manifest already carried in the decision (`` `Key src ``) is ignored.
- **Impact:** the raise happens before any write. It is caught per entry by `Io.catch ... Failed (Printexc.to_string exn)` (`:494-497`), so the `--move` of that file reports an opaque failure. No data is lost.
- It is reachable when the mirror lacks a published manifest the store has: a peer's publish not yet applied, or an unreadable mirror file, since `published` returns `None` on a parse exception (`lib/domain/checkout/manifests/manifests.ml:101-121`).
- **Test:** `tests/unit/rsync_plan` covers `decide` only. Nothing covers `act` with a store-only source.

### G5 — `put_if_absent` against an older http-proxy server reads as "won"
**CONFIRMED. The code acknowledges it in a comment.**
- The client sends `PUT ...?if_absent=1` and returns the reply body (`lib/backends/drivers/http_proxy/http_proxy_backend.ml:72-80`). The comment at `:72-75` says an old proxy "reads as 'you won'".
- An older server (before c51dba7f/284521fd, 2026-08-07) ignores the query parameter. It does a plain put, which overwrites the existing marker, and answers `""`. The current plain `Put` also answers `""` (`lib/app/frontends/http_proxy/http_proxy_frontend.ml:648-652`).
- In `claim_name` (`lib/domain/remote/store/store/store.ml:100-135`), `Folder.marker_of_string ""` gives `None`, which leads to `` `Held ``. So the client believes it won after already clobbering the real winner's marker.
- No capability advertises claim support. `capabilities` asks only for share_url, chunk_size, max_concurrency and verified (`http_proxy_backend.ml:280-305`), so the client cannot detect an old server.
- **Effect:** concurrent creation of one directory can strand files, but only in mixed-version deployments.
- **Test:** none.

### G6 — http-proxy HEAD drops the etag
**CONFIRMED as a fact. No consumer is affected today.**
- The server's `Head` reply sends only `x-tsync-size` and `x-tsync-last-modified` (`http_proxy_frontend.ml:630-637`). The client hard-codes `etag = None` (`http_proxy_backend.ml:106-130`).
- Etags are consumed only from **listings**, by `inode_tree.ml:89-103` and `folder_index.ml:13-34`. The proxy's list wire format does carry the etag (`lib/backends/api/http_proxy.ml:69-80`).
- No `head_opt` caller reads `.etag`: `mirror.ml:69` and `:273`, `retention.ml:108`, `gc.ml:352`, `collection.ml:111,175`, `file_store.ml:217`.
- Latent inconsistency only: HEAD answers differ between drivers.
- **Test:** none.

### G7 — Android builds its domain with `resume = false`; deferred jobs may never be replayed
**CONFIRMED.**
- `load_domain` calls `Domain.of_config ?domain ~paths cfg` with no `~resume` (`lib/app/frontends/android/jni/android_jni.ml:41-47`). The default is `false` (`domain.ml:194`).
- With `resume=false`, `Deferred.make` starts the queue immediately via `Q.start ~recover:false` (`deferred.ml:258-263`).
- `start ~recover:false` calls `claim dir` and never registers a rescan (`durable_queue.ml:594-601`). The claim also makes `with_claim` skip any later rescan in this process (`:65-66`).
- Nothing on Android calls `Domain.start_resumed`. The only call site is `launcher.ml:295`, and a grep of `android/` finds nothing.
- So records left in `deferred-pending/<domain>/<target>` by a killed app process are never read again on the phone. The target misses those writes until someone runs `tsync mirror`, which has no path on the phone.
- The main write path (WAL and replay via `E.start_queue` / `Rp.reconcile`) is not affected. Only replica and backfill targets are.
- **Test:** none.

### G8 — `tsync pause` holds only frontend queues; the poller in the parent keeps applying; not persisted
**CONFIRMED.**
- `tsync pause` sends `"pause"` to `Domain.target`'s per-domain socket (`cmd_pause.ml:9-11`, `domain.ml:251-257`). That socket is served by a frontend's `Ipc_handler`, which calls its own `Pause.set` (`ipc_handler.ml:980-981`).
- The poller runs in the parent. `launcher.ml:253-300` builds its own `Domain_engine.Make (C)` and calls `Cv.start`, which is `E.converge`. That calls `Sp.start ~paused:Pause.held` (`domain_engine.ml:166-170`) with the **parent's** `Pause` instance.
- Nothing sets the parent's `Pause`. The parent's sync-socket handler knows only `stats`, `report`, `rescan`, `uplink` and `stop` (`launcher.ml:150-243`).
- So peers' changes keep being applied. That contradicts the help text "what peers did is not applied" (`cmd_pause.ml:20-22`).
- Under `` `Process_per_binding `` or several frontends, only the frontend behind that one socket is held.
- `Pause.switch` is a plain `ref` (`lib/domain/sync/pause.ml:18-25`) and the queue's `paused` is an in-memory `bool ref` (`durable_queue.ml:248`, `:621-623`), so nothing persists across a restart.
- **Test:** `tests/scenario/pause/pause_test.ml` covers only the single-process upload queue. Nothing covers the poller or the cross-process case.

### G9 — The CLI's blocking IPC client has no timeout
**CONFIRMED.**
- `Ipc.send` (`lib/core/ipc.ml:1-10`) is a blocking `Unix.connect` followed by `input_line`. There is no `SO_RCVTIMEO`, no `select` and no timeout. Separately, the fd leaks if an exception is raised.
- A daemon whose Lwt loop is wedged still gets its connections accepted by the kernel backlog, so `input_line` blocks forever.
- Callers:
  - `cmd_stop.ml:13`
  - `cmd_pause.ml:11`
  - `cmd_cache.ml:79`
  - `cmd_versions.ml:34`
  - `location.ml:141`: resolving a local path not under a known root, so `item`-taking commands as well.
  - `file_provider_frontend.ml:40`
- The Lwt variant, by contrast, has `?(timeout = 2.)` (`ipc.ml:46-53`).
- `cmd_stop` handles only `ECONNREFUSED`/`ENOENT`/`Failure`. It prints "relying on signal" but sends none.
- **Test:** none.

### G10 — file-provider stop has no grace bound or stop signal and drains sequentially
**CONFIRMED.**
- In `lib/app/frontends/file_provider/file_provider.ml`:
  - `on_stop = (fun () -> ())` (`:109`).
  - After `Ipc_lwt.serve` returns, it runs `Lwt_list.iter_s (fun r -> r.drain ()) domain_runtimes` (`:303-304`). There is no `Lwt_unix.on_signal`, no `Shutdown.request` and no `Domain_engine.drain_for_stop`.
- Contrast fuse (`fuse_fs.ml:511-521`), http-proxy (`http_proxy_frontend.ml:1171-1233`) and the launcher (`launcher.ml:278-327`). All three set up signals, call `Shutdown.request` and use `drain_for_stop`, which runs `iter_p` raced against `Shutdown.grace` (`domain_engine.ml:229-251`).
- Because `Shutdown` is never requested:
  - `D.drain` does not race its grace (`domain_engine.ml:183-188`).
  - The queue loop keeps running every queued job (`durable_queue.ml:455-460`).
  - `Nap.sleep` backoffs of up to 300 s are not interrupted (`:510-515`, `shutdown.ml:38-50`).
- So a `stop` with an unreachable backend can hang indefinitely. SIGTERM uses the default action and kills without draining. The work is on disk, so it resumes later.
- **Test:** none.

### G11 — Glob `**/.git` matches `foo.git`
**CONFIRMED. I ran it.**
- `lib/core/glob.ml:17-30`: after `**/`, `try_from` tries the rest of the pattern at **every** character offset `i`, not only at segment starts (offset 0 or right after a `/`).
- I ran a copy of `glob.ml` with a small driver (`scratchpad/globt.ml`):
  ```
  **/.git    foo.git        true
  **/.git    a/repo.git     true
  **/node_modules a/my_node_modules true
  ```
- **Use sites:** only `tsync import --exclude/--only` (`lib/domain/ops/import.ml:48-51`, `:96-97`; `lib/app/cli/cmd_import.ml:20-23`). Each pattern is also matched against the basename. No config-level ignore rules use Glob.
- **Impact:**
  - `--exclude '**/.git'` silently skips bare repositories (`project.git`) and anything whose name ends in `.git`.
  - `--only '**/X'` over-selects.
- **Test:** `tests/unit/glob/glob.ml:28-31` covers only the positive cases and `a/b/c`. There is no suffix-collision case.

### G12 — Stall timeout, health and metrics use wall clock although a monotonic clock exists
**CONFIRMED.**
- The monotonic clock exists: `lib/local/io/clock_stubs.c:26-34` (`CLOCK_MONOTONIC`), used by `Io_lwt.Clock.now` (`lib/lwt/local/io/io_lwt.ml:49`).
- The same module's `with_stall_timeout` uses `Unix.gettimeofday` (`io_lwt.ml:53-60`). It backs `Http_client` (`http_client.ml:100`).
- Health uses `let now = Unix.gettimeofday` (`lib/core/health.ml:46`) for `held_until`, `failing_since` and `last_lost`.
- Metrics use `now_sec () = int_of_float (Unix.gettimeofday ())` (`lib/core/metrics.ml:16`).
- **Consequences:**
  - A backward step (NTP correction) extends a backend's hold, and suppresses its probe, by the size of the step.
  - The same backward step delays stall detection by the step.
  - A forward step, such as fake-hwclock at boot on RTC-less arm boxes, can satisfy `at - failing_since >= trip_span` at once. That trips health early and fires stall timeouts spuriously.
  - Metrics rate buckets skew.
- **Test:** none.

## Frontends, macOS and Android


### H1. The router keys by display name while the app registers a lowercased, dashed identifier

**Verdict: REFUTED.** Routing never uses the identifier.

- The app registers `NSFileProviderDomain(identifier: domainIdentifier(name), displayName: name)`, where `name` is the config's domain name, unchanged (`macos/TsyncApp/AppDelegate.swift:80-86`). `domainIdentifier` does lowercasing and space-to-dash (`:7-9`).
- Every client sends the **display name**, never the identifier:
  - extension: `DaemonClient(domain: domain.displayName)` (`macos/TsyncFileProvider/Extension.swift:31`)
  - relay: the same (`macos/TsyncApp/SignalRelay.swift:23`)
  - menu: `DaemonClient(domain: $0)` over the config names (`StatusMenu.swift:50`, `AppDelegate.swift:34-38`)
- `sendSync` fills `request.domain = domain` (`macos/Shared/DaemonClient.swift:362`). The OCaml router matches `r.name = domain` with `name = C.domain_name` (`lib/app/frontends/file_provider/file_provider.ml:211,278`). The subscribe topic is `C.domain_name` on both ends (`file_provider.ml:28`, `ipc_handler.ml:1120`).
- The other places that spell the domain are also consistent:
  - the reset marker is written with `C.domain_name` and mapped through the same `domainIdentifier` when read (`file_provider_frontend.ml:74`, `AppDelegate.swift:236`)
  - the menu's folder lookup is keyed by `displayName` (`StatusMenu.swift:98`)
  - the CloudStorage folder is found by alnum-folding the display name (`conf_parsing.ml:493-505`)
- With a single domain, a name that does not match still routes, through the `None, [only]` fallback (`file_provider.ml:286`).

**Real residual (not the claimed bug):** two config names that fold to the same identifier (`"My Docs"` and `"my-docs"`) collide:
- `surviving` is not updated inside the add loop (`AppDelegate.swift:78-96`), so the second `add` reuses the first's identifier.
- The alnum folder match (`conf_parsing.ml:505`) also collides for `"mydocs"`.
- Severity: robustness. It needs a pathological config. No test covers it.

### H2. The router's own errors omit `code`

**Verdict: PARTIAL.** The missing code is real. The mis-mapping is not.

- `error_json` emits only `ok` and `error` (`file_provider.ml:195-197`). It is used for "invalid JSON", "expected JSON object" and "cannot tell which domain" (`:263,293-297,300`).
- Swift maps a missing code to `"internal"` (`DaemonClient.swift:373-374`, and `:414` for subscribe). `FileProviderError.from` sends `"internal"` to the `default` branch, `NSFileWriteUnknownError`, which is transient and retried (`macos/Shared/DaemonError.swift:64-67`).
- Only an explicit `"unreachable"` produces `serverUnreachable` (`:59-62`). So none of these can latch the domain off, and no unreachable condition is hidden by them.
- Practical effect: when the daemon serves several domains and one is missing (the config changed and the daemon was not restarted), every extension call fails as a retried "unknown error" forever, and the message tells the user nothing. The menu poll uses `try?`, so it simply stays stale.
- Severity: cosmetic / robustness.
- Tests: `DaemonErrorTests.testUnexplainedFailuresAreRetried` (`macos/TsyncTests/DaemonErrorTests.swift:47`) pins the default mapping. Nothing tests the router's error shape.

### H3. `contentVersion` changes when an upload finishes

**Verdict: CONFIRMED by reading.** The runtime effect on macOS cannot be observed here.

- `TsyncItem`: `content = etag.isEmpty ? "size:mtime" : etag` (`macos/TsyncFileProvider/Item.swift:80-82`).
- A write replies before the upload finishes: `Extension.createItem` and `modifyItem` call `client.write` with no `await` (`Extension.swift:244-248`, and the matching `modifyItem` branch). The row returned carries `etag:""` and `isUploaded:false` (`lib/app/cli/runner/daemon/engine/item_row.ml:172-178`). So the version the system records is `"size:mtime"`.
- When the upload publishes, `on_upload_done` calls `notify_changed` (`file_provider.ml:170-175`). The relay then signals the working set (`SignalRelay.swift:75-76`), and the row now has `etag = h1` (`item_row.ml:137-141`). The `contentVersion` has changed.
- The item's own comment says a changed `contentVersion` "brings new bytes down on its own" for a materialised file under `.downloadLazily` (`Item.swift:16-19`). By the code's own model, then, the file is fetched again. The fetch is served from the promoted chunks, so it costs local I/O rather than network.
- The comment at `Item.swift:77-78` ("a finished upload refreshes the item without re-downloading") holds for `metadataVersion` only. It is contradicted by `contentVersion` also moving.
- Severity: robustness. It is wasted I/O proportional to file size, plus a window during which the system is replacing a file the user just saved.
- Tests: `testDirectoryVersionIsStable` covers directories only (`macos/TsyncTests/DaemonProtocolTests.swift:312`). Nothing covers the file transition.

### H4. `tsync fileprovider reset` leaves the daemon stopped

**Verdict: CONFIRMED.**

1. `reset` calls `restart_app`, which runs `pkill -f /Applications/TsyncApp.app` (`lib/app/frontends/file_provider/file_provider_frontend.ml:58-61,73-81`).
2. The daemon's command line is `/Applications/TsyncApp.app/Contents/MacOS/tsync start` (`macos/install-agent.sh:36-40`), so the pattern matches it and it gets SIGTERM.
3. SIGTERM is handled as a graceful stop (`lib/app/cli/launcher.ml:277-285`), so the daemon exits 0.
4. The agent has `KeepAlive{SuccessfulExit=false}` (`install-agent.sh:45-49`), so launchd does not restart it. `open -a` restarts only the app.

- Compare `Runtime.restart_service`, which does the same pkill and then `launchctl kickstart -k` (`lib/local/runtime/macos_runtime.ml:41-48`). `reset` lacks that kickstart.
- The CLI survives only when it is invoked through the `/usr/local/bin/tsync` symlink (argv keeps the symlink path). Invoked by its in-bundle path, it kills itself.
- After the reset, the extension's calls fail with a transport error that is retried, not latched, so the domain stays empty until the user runs `tsync restart`. The memory note `fileprovider-reset-gotchas` records this seen live.
- Fix: call `Runtime.restart_service` from `reset`, or add the kickstart to it.
- Severity: robustness. No test covers it; `tests/e2e/macos` does not exercise `reset`.

### H5. The relay does not translate `root` on evict/restore

**Verdict: CONFIRMED.**

- `evict` and `restore` accept the root: `ref:"root"` resolves through `Ir.parse`, and `rel:""` becomes `Lk.root` (`ipc_handler.ml:783-799,910-923`).
- The hook runs `act`, and `H.item_ref root` gives `` `Root ``, which is `Item_ref.to_string`, which is `"root"` (`item_row.ml:147-158`, `lib/core/item_ref.ml:9`). That string is published as `ref` (`file_provider.ml:49-54`).
- The relay passes it raw: `NSFileProviderItemIdentifier(ref)` (`SignalRelay.swift:79,87-88`). Only `ItemID.wire` translates, and only in the other direction (`macos/Shared/ItemID.swift:47-49`).
- The system knows the root as `.rootContainer` (`NSFileProviderRootContainerItemIdentifier`), not `"root"`. So `evictItem` / `requestDownloadForItem` fail, and the failure is only logged.
- Meanwhile the daemon has already answered `ok`, because `delivered > 0` (`file_provider.ml:44-45`). So `tsync evict <domain root>` reports success while the replica is untouched. The chunk-store half still ran.
- Fix: map `"root"` through `ItemID.parse(ref)?.identifier` in `SignalRelay.handle`.
- Severity: robustness. It is a silent no-op on the replica. No test covers it.

### H6. The Swift IPC client has no request timeout

**Verdict: CONFIRMED.**

- The client has no `SO_RCVTIMEO`/`SO_SNDTIMEO`, `poll`, deadline or timer (`DaemonClient.swift:196-386`; a grep for timeout, `RCVTIMEO` or `poll(` finds nothing in `macos/`). `recv` blocks until the daemon answers or closes.
- The async path can be cancelled (`CancellableSocket`, `:280-381`), so the system's own cancellation frees a callback.
- The public `sendSync(_:as:)` hands in a fresh `CancellableSocket` that nobody can cancel (`:354-358`). It is the path the extension's `readOnly` probe takes (`Extension.swift:20-27`). The probe runs from `resolve` and every mutation entry point, so a wedged daemon blocks that thread with no way out. The extension's `readOnly` probe itself is not bounded in time.
- Side finding: `readOnlyAnswered` is an unsynchronised `var` read and written from concurrent Tasks (`Extension.swift:19-27`). That is a data race.
- The menu poll uses `polling` as a latch (`StatusMenu.swift:78-88`). One hung `menu` request therefore freezes the menu's state forever, and it never shows "unreachable", because a hang is not a transport failure.
- Severity: robustness. No test covers a wedged daemon; `DaemonCancellationTests` covers cancellation only.

### H7. Android API 30+ stores the pass-start generation, skipping unsettled and failed rows forever

**Verdict: CONFIRMED.**

- `generation` is read once, before the queries (`android/app/src/main/java/org/feverdreamtv/tsync/backup/BackupSweep.kt:69`). It is stored unconditionally when the volume finishes (`:135`), whatever was skipped or failed.
- The next query is `GENERATION_MODIFIED > watermark.generation` (`backup/MediaScan.kt:107-108`).
- **UNSETTLED** (not pending, but `DATE_MODIFIED` within 10 s; `BackupPlanner.kt:61-63`):
  - The sweep sets `more = true` (`BackupSweep.kt:109`), and the worker returns `Result.retry()` (`BackupWorker.kt:85`).
  - The retry cannot see the row, whose generation is ≤ the stored one. The photo is lost unless it is modified again.
  - This is reachable. The content trigger coalesces a burst for up to `TRIGGER_MAX_DELAY_SECONDS = 300` (`BackupSchedule.kt:35-36`), so continuous shooting fires mid-burst. The 6-hour periodic run and "run now" can also land within 10 s of a capture.
- **Failed upload** (copy mismatch, no space, mkdir or network failure): a `FAILED` record is written (`BackupSweep.kt:183-193`) and `more` is not set. Nothing ever re-reads `FAILED` records: `UploadRecords` only parses the state (`UploadRecords.kt:75`), and the planner acts only on rows returned by the query.
- **STILL_PENDING** is mostly moot on API 30+. MediaStore hides other apps' pending rows by default, and clearing `IS_PENDING` bumps the generation, so those come back.
- Below API 30, the 24-hour `DATE_ADDED` lookback re-covers rows only while they stay within 24 h of the watermark.
- Severity: data-loss (camera photos never backed up, silently; the UI reports the sweep "settled" only when `failed == 0`, `BackupWorker.kt:83`).
- Tests: `BackupPlannerTest` is pure planner logic. `MediaScanTest.aWatermarkAheadOfEverythingFindsNothingNew` pins the cut itself. Nothing covers the sweep's watermark after a skip or failure.

### H8. `isChildDocument` misses nested folders and files inside them

**Verdict: CONFIRMED, and broader than stated.**

- `isChildOf(ref, folderId) = ref.startsWith("f:$folderId/") || ref == "d:$folderId"` (`android/core/src/main/kotlin/org/feverdreamtv/tsync/Cli.kt:38-39`). It is called with the parent's folder id (`TsyncProvider.kt:147-151`).
- A `d:<id>` reference carries no parent, so **even a direct subfolder** is rejected, not only deeper descendants. The one `d:` accepted is the folder itself.
- Example: tree root is `root`, so `parentId = ".tsync-root"`. Then `isChildDocument("root", "d:abc")` is false for every top-level folder.
- `FLAG_SUPPORTS_IS_CHILD` is advertised (`TsyncProvider.kt:74`). `DocumentsProvider.enforceTree` throws `SecurityException` when a tree-URI document is neither the tree root nor `isChildDocument`.
- So an app holding an `ACTION_OPEN_DOCUMENT_TREE` grant can open the tree's top level and its files, but no subfolder and nothing below one.
- Fix: answer from the daemon, by walking `stat(...).parentRef` up to the parent.
- Severity: correctness (tree grants unusable below one level). No test covers it; `KeysTest`/`CliProtocolTest` do not exercise `isChildOf`.

### H9. Child-by-name lookups read only the first 1000 entries

**Verdict: CONFIRMED.**

- `Cli.list(parent)` with no limit gets `default_page_limit = 1000` (`ipc_handler.ml:159-166`), in name order, with `next` set when more remain (`:195-206`).
- These callers never follow `next`:
  - `Ingest.children` (`android/app/src/main/java/org/feverdreamtv/tsync/Ingest.kt:116-122`)
  - `Ingest.childRef` / `folderFor` (`:82-89,97-100`)
  - `TsyncProvider.childRef` (`TsyncProvider.kt:297-304`)

  Only `queryChildDocuments` pages (`:114-131`).
- Share-sheet saves go through `freeName` then `commit` (`MainActivity.kt:377-378`), and `writeWhole` replaces a same-named file (`Ingest.kt:103-104`).
- Concrete case: a folder holds `a0000.jpg`…`a0999.jpg` plus `b.jpg`, and the user shares `b.jpg`. `taken` is only the `a*` names, so `freeName` returns `b.jpg` and the existing `b.jpg` is overwritten. The same happens to `b (1).jpg` when only `b.jpg` is visible.
- Other effects:
  - `folderFor` on a parent with more than 1000 entries: the child is not found and `mkdir` runs again (answering the existing folder). `childRef` still misses it, so it throws "could not create". Backup fails for that path.
  - `createDocument` / `renameDocument` throw after succeeding.
- Severity: data-loss (overwrite; recoverable only if a `revert` history keeps the old version). No test covers it; `CliProtocolTest."a folder is listed a page at a time"` tests the paging wire, not these callers.

### H10. Kotlin drops the error code

**Verdict: CONFIRMED.**

- `Cli.reply` throws `Error(response.optString("error"))`. `code` is never read and `Cli.Error` has no field for it (`Cli.kt:20,97-109`). Callers cannot tell `not_found` from `unreachable`, `invalid` or `internal`.
- Consequences:
  - `Ingest.children` turns **every** `Cli.Error` into "no children" (`Ingest.kt:116-122`). A transient list failure then makes `freeName` return the original name, and the write overwrites. That is a second route into H9.
  - `queryChildDocuments` reports "could not reach the server" for every failure, a deleted folder included (`TsyncProvider.kt:132-141`).
- Severity: correctness. No test covers it; `CliProtocolTest` asserts only `is Cli.Error` (`:198,286`).

### H11. Android evict/restore act on one key while FUSE walks the subtree

**Verdict: PARTIAL.** The difference is intended, but its stated precondition has already been met.

- The Android hooks are `evict = E.F.evict` and `restore = E.F.ensure_cached`. They carry a `ponytail:` comment: "lift that if a client ever offers the same gesture" (`lib/app/frontends/android/android_frontend.ml:44-48`). FUSE uses `on_subtree` (`lib/app/frontends/fuse/fuse_fs.ml:174-195`).
- The Android app **does** offer the gesture on folders. `offerActions` hides only "Open" for a directory; "Make available offline" and "Make online only" appear for folders too (`MainActivity.kt:234-253`, since commit ed257a22).
- On a directory key, `ensure_local` goes through `fetch_plan` and `Mf.current`. `of_file` fails on a directory and yields `None`, which leads to `R.fetch_manifest` for the dir key, which finds nothing and returns `None` (`lib/domain/checkout/content/data.ml:1158-1182,1193-1202`). `forget_chunks` sees `published = None` and does nothing (`:1265-1269`).
- The toast still says "… is available offline" / "… is online only" (`MainActivity.kt:261-268`). If that backend manifest probe errors, the user sees "Failed" instead.
- In the shared handler contract, the hook type allows either behaviour. The inconsistency is between the Android UI and its hook.
- Severity: correctness (a silent no-op on a user action). No test covers it.

### H12. Android runs no journal poller, so a folder with pending uploads shows stale contents

**Verdict: PARTIAL.**

**What holds:**
- Android starts no poller. `run` calls `start_queue`/`init` then `drain` (`android_frontend.ml`, `Make.run`).
- Freshness comes from pull-on-read: each `list_children` pulls that folder's children from the store's inode tree and prunes (`lib/domain/checkout/lazy_checkout/lazy_checkout.ml:87-100`).

**What is wrong:** pending **uploads** do not block the pull.
- The skip happens only when `owed_under` is true (`:71-82,91`).
- `owed_under` looks at `W.owed_metadata`, which keeps only records with no `` `Put `` (`lib/domain/checkout/wal/wal.ml:7,195-197`).
- A folder with files still uploading is re-read and pruned normally. `prune` drops only published manifests, and staged bodies stay (`lazy_checkout.ml:50-66`).

**Exact staleness window:**
- A folder `P` is not re-read while the WAL holds a pure-metadata record (`mkdir`/`rmdir`/`delete`/`rename`, src or dst) naming a key whose **immediate** parent is `P`. Deeper descendants do not count (`in_prefix` compares `dirname`).
- The window runs from `W.record` (`file.ml:~250`) until the metadata queue discharges the record.
- Records are retried with no attempt cap: `attempts` is incremented but never checked (`wal.ml:160`), and `Retry` just fails and requeues (`file.ml:1492-1493`).
- So in the normal case the window lasts seconds. With a record that keeps failing (a persistent clash, or a store refusing the op), it is **indefinite**, and peer changes in `P` stay invisible for as long as it lasts. Folders not named by the record are unaffected.
- Offline, the pull cannot read the store anyway, so being offline adds nothing to the window.

**Severity:** robustness.

**Tests:** `tests/scenario/lazy_owed/lazy_owed.ml` pins the intended skip ("survives a browse … once it is published, the browse reads the store again"). Nothing covers a record that never discharges.


## Second wave: suspected, not verified

Flagged while writing the per-implementation and abstract specs, from reading the code. None was given an
adversarial second reading. Grouped by where they were found; details are in the corresponding spec's
gaps section at this commit.

**Data loss or corruption**
- Staged body that fails to open with EMFILE/EIO is filled with zeros and published (`Data.fill_from_staged`).
- Two concurrent range fills of one chunk at non-adjacent offsets make the partial record claim the gap; readers get zeros.
- The cache cap drops a body and its record but not the in-memory intervals; a later fill records bytes that are gone.
- A crash after an upload's promotion but before its WAL record reaches Executed completes the record without publishing the journal entry.
- The daemon's 60 s metadata retry re-queues Prepared records another process is running: double publication, lost ordering.
- The WAL's Executed state keeps the original ops, not the rewritten ones; recovery publishes the originals.
- GC: a writer's move-back landing after closing checked a chunk; the dedup memo surviving a completed collection; rename, in-domain copy and revert skip promotion; queued deletes applied late without re-check.
- Replication: GC deletes on copies bypass the ensured-chunks memo, so manifests can reach a copy without chunks; a one-shot command and the daemon can run one copy's log concurrently.
- Conflicts: B renames x over f while A deletes f; A renames onto the destination of B's pending rename.
- FUSE: `rmdir` removes non-empty directories; deleting or replacing a file another process holds open loses its content; rename flags (NOREPLACE, EXCHANGE) are ignored; fsync is a no-op.
- S3: AWS's retryable 409 `ConditionalRequestConflict` is permanent, and the claim caller then falls back to a plain PUT.
- Folder claims: moves write the destination marker with a plain put after a separate check; a stale marker is deleted unconditionally before reclaiming; the claim writes the marker before the anchor.
- A client stopped for more than 30 days skips unpruned journal entries older than the horizon.
- Android share sheet closes before committing staged copies.

**Correctness**
- Client error mapping: corrupt and not-yet-synced errors map to `unreachable` (latching macOS offline); a down store or revoked credential maps to `internal`.
- http-proxy client: `delete_multi` is never paged but the server refuses more than 1024 keys (permanent); empty bulk lists get 400; `get_many` has no fallback for old servers; a path in `url` is dropped; an unserved domain reads as an empty store; read-only refusals arrive as plain 403.
- Local driver: deleting a directory-marker key removes the subtree; `delete` ignores unlink errors; the same errno is transient on `put` and permanent on `get`; no directory fsync.
- `get_range` at or past the end fails with 416 on S3 and GCS instead of returning empty.
- 429 and 503 "busy" count against a member's health.
- Uplink: the decrease floor never applies; baseline drift makes a standing queue the baseline after 10 minutes; retries bypass the budget.
- Trash expiry deletes the entry before its subtree; purge leaves anchors; the collector keeps orphaned subtrees' chunks; member-to-member mirror copies manifests before chunks; expired shares are never deleted.
- S3 `region` is required although documented as defaulting; S3 has no request or stall timeout.
- GCS: a revoked key is transient; a token revoked early is not dropped on 401.
- Replication: the degraded flag is in memory only; a failure on a later main leaves earlier mains with an unowed write.
