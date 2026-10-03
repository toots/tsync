# 09 — Conformance — OCaml implementation notes

Companion to the language-neutral spec [../09-tests.md](../09-tests.md). See [README.md](README.md) for how these notes are organised.


Section numbers in parentheses (§n) refer to the spec.

## B0. The current suite against the conformance spec

`tests/` (about 32k lines, about 180 test directories), plus `lambda/test_*.py` (which read two golden
files) and the Android unit tests, surveyed read-only at `4c32fa96`.

### B0.1 Where each subject is checked today

| Subject (§3) | Test directories |
|---|---|
| Hashing, keys, layout, references, codecs, temp names, globbing, framing | `unit/hash` (+ `lambda/test_chunk_key.py`), `unit/folder_id`, `unit/id`, `unit/item_ref`, `unit/logical_key`, `unit/stored_key`, `unit/layout`, `unit/gc_job` (+ `lambda/test_gc_job_key.py`), `unit/temp_names`, `unit/spool_reap`, `unit/sweep_scope`, `unit/manifest_naming`, `unit/staged_codec`, `unit/wire_bodies`, `unit/listing`, `unit/glob`, `unit/field_spec` |
| Remote model, dedup, versions, retention, GC, corruption, repair, integrity, resync, upload | `scenario/base`, `scenario/upload`, `scenario/staged_fanout`, `scenario/upload_gone`, `scenario/versioning`, `scenario/expire`, `scenario/gc`, `scenario/corruption`, `scenario/resync`, `ops/rename`, `ops/integrity_tree`, `content/verified_fetch`, `content/corruption`, `backends/gc_cost`, `backends/gc_queued`, `backends/gc_targets`, `unit/gc_report`, `unit/dedup`, `unit/mirror_probe`, `unit/mirror_pools`, `unit/upload_fanout` |
| Journal, cursor, poller, applied log, change feed, offline metadata, ordering, WAL recovery, conflicts, resync | `scenario/sync`, `scenario/meta_offline`, `scenario/conflicts`, `scenario/ipc`, `scenario/pause`, `work/queue_order`, `unit/cursor_debounce`, `unit/cursor_watch`, `unit/applied_entries`, `unit/import_batching`, `unit/resolve`, `ops/resync`, `frontends/stop_publishes_cursor` |
| Checkout, staged writes, promotion, read path, read-ahead, fetch bounds, chunk cache, cache cap, ranges, progress, lazy browse, folder index | `scenario/staged`, `scenario/staged_groups`, `scenario/read_offline`, `scenario/lazy_owed`, `scenario/rename_listing`, `content/*` (`absent_probe`, `demand_paging`, `promote_race`, `read_ahead`, `fetch_fanout`, `read_fanout`, `chunk_cache`, `partial_local`, `cache_cap`, `fetch_range`, `download_progress`, `pulling`), `unit/demand_ranges`, `unit/folder_index`, `unit/folder_ids`, `frontends/android_lazy` |
| Config, import, export, rsync planning, shares | `unit/conf`, `scenario/import_export`, `unit/import_listing`, `unit/import_progress`, `ops/export`, `unit/export_record`, `unit/rsync_plan`, `live/rsync`, `unit/share` |
| Store contract, composite, failover, deferred targets, traffic, batching, HTTP, governor | `conformance`, `backends/*` (`claim`, `get_range`, `durable_writes`, `local_watch`, `backend_failure`, `held_failover`, `fallback`, `main_down`, `write_guard`, `deferred*`, `backfill`, `http_reuse`, `http_stall`, `proxy_permanent`, `proxy_watch_client`, `probe_deadline`), `unit/health`, `unit/backend_traffic`, `unit/batched`, `unit/batch_nesting`, `unit/bounded`, `unit/chunk_pools`, `unit/status_cost`, `unit/status_held`, `unit/uplink*`, `unit/backend_capped` |
| Queues, stop, status, jobs, IPC server, CLI, desktop integration, memory bounds | `work/*`, `unit/queue_claim`, `unit/queue_stop`, `unit/drain_for_stop`, `unit/shutdown`, `unit/fork_reap`, `unit/ipc_serve`, `unit/subs`, `scenario/queue_bytes`, `unit/status_*`, `unit/job`, `unit/job_registry`, `unit/progress_eta`, `unit/completion`, `unit/export_cli`, `unit/ls_listing`, `unit/desktop_mounts`, `unit/menu`, `unit/fuse_subtype`, `unit/walk_fanout`, `unit/hashtbl_mmap` |
| Frontends | `frontends/presenting_domain`, `frontends/http_proxy`, `frontends/proxy_bound`, `frontends/proxy_watch`, `frontends/share_server`, `unit/zip`, `frontends/android`, `frontends/android_bridge`, `frontends/preview` (dead verb), `e2e/harness`, `e2e/linux`, `e2e/macos`, `e2e/stress` |

### B0.2 Gaps against the spec

- **No crash-at-every-step or power-loss harness (§7.2, §7.3).** Crash windows are hand-built:
  bytes uploaded with the WAL at Executed and no entry; a legacy pending record naming unstaged data;
  orphan staged bodies; an interrupted promotion; a queue log held by a SIGKILLed child; stress's random
  SIGKILL. There is no filesystem capability to wrap, and nothing fsyncs WAL records, sidecars or queue
  records.
- **No multi-process ownership checks (§7.5).** Ownership is not a concept in the code; several
  processes write one cache root with per-process locks only.
- **No property-based conflict run (§8).** `unit/resolve` pins the tables (65 + 23 situations) as fact
  → decision; `scenario/conflicts` hand-picks pairs.
- **§9 items not reached**: all of them, as listed there.
- **Counted-check discipline (§10.1).** Suites that print checks but never call the count report, so
  only the golden diff catches a failure: `unit/bounded`, `cursor_watch`, `folder_ids`, `item_ref`,
  `subs`, `queue_claim`, `frontends/proxy_bound`, `proxy_watch`. Suites reporting without an expected
  count: `completion`, `manifest_memo`, `sweep_scope` (0 checks), `fetch_fanout`, `pulling`,
  `queue_stall`, `known_chunks`. `job`'s "does not raise" checks are the constant `true`.
- **Environment-dependent zeros (§10.1).** A missing `lsof` makes `fetch_fanout`'s open-file count 0;
  `/proc/self/fd` reads 0 off Linux (`export`); unsupported `fallocate` makes reserve pass trivially.
- **Fixed scratch paths (§10.6).** `chunk_cache`, `promote_race`, `staged`, `rename_listing` and
  several unit tests hard-code a `/tmp` path.
- **Two-client ordering depends on mint time.** Journal order in two-client snapshots is mint order,
  and the cursor is "whatever the last writer stored".

### B0.3 Pinned outcomes that disagree with the normative spec

These golden files pin current behaviour that the conflict, GC and versioning specs replace; they must
be re-baselined when the code changes, not defended:
- an rmdir racing an add inside the folder keeps the added file only inside the trashed folder (d1);
- adds rescued from a removed folder are flattened to the root (d8);
- rename vs rename of one file keeps both names (f6), while stale comments promise a conflicted copy;
- stale folder markers after d2/d4; trash anchors surviving `expire all` and `purge`;
- revert does not version the content it replaces;
- a symlink's tree etag equals another file's name-hash prefix;
- a scrambled same-size chunk is not re-copied by resync; plain reads return corrupted bytes.

Stale comments contradicted by golden files: the sync race scenarios promise conflicted-copy names that
do not appear; import/export says export "fills the cache"; the resync step doc says it prints copied
keys (it prints counts); a stats scenario titled "cache filled" pins `cache=0`; the runner says folder
ids are printed raw (they are aliased).

### B0.3b Implementation tests outside conformance (P6)

Pool widths, fan-out bounds, slot-before-resource ordering and per-item memory bounds are resource
strategy, not specification. `unit/bounded`, `chunk_pools`, `batch_nesting`, `content/fetch_fanout`,
`read_fanout`, `upload_fanout`, `mirror_pools`, `walk_fanout`, `hashtbl_mmap`, `import_listing`,
`bigstring` stay as regression tests of this implementation (they caught real bugs: data-sized
`Lwt_list.*_p`, one promise per item, heap-resident listings), but a rewrite is not required to pass
them. Memory-mapped reads are allowed and encouraged by the spec; `unit/bigstring` pins the mapping
semantics this implementation relies on.

### B0.4 Load-sensitive and timing-margin tests (§10.3)

Known and measured (a few percent of CI runs under load on Linux, never on macOS; memory note
*tsync-load-sensitive-tests*): `content/download_progress` (needs ≥ 3 samples during an operation),
`unit/import_listing` (a live-words threshold), `scenario/sync` (its first scenario loses B's tree and
content lines while the store dump is right), `scenario/pause` and `scenario/queue_bytes` (the queue is
sampled one step early), `scenario/meta_offline`. Timing margins: `queue_stall`, `fetch_fanout`,
`read_fanout`, `read_ahead`, `read_offline`, `progress_eta` (real clock), `fork_reap`, `drain_for_stop`,
`cursor_debounce` (real 0.5 s timer), `demand_ranges`, `batch_nesting`, `ipc_serve`, `http_stall`,
`local_watch`, and `chunk_cache`'s 5 s timeout. Golden lines that count requests or order two queues'
publishes race under load (read-ahead; upload versus metadata queue): assert a count above 0, or
sequence the queues with a metadata-only drain. First move on a red run is a rerun; an A/B against main
comes next, only if the rerun fails the same way.

## B1. Runtime-independent (valid under Lwt or OCaml 5 direct style)

### B1.1 Registering tests with dune

- **One test = one directory with one `(executable (name X))` stanza.**
  - `tests/gen-dune.sh` emits the rules into the committed `tests/dune.inc`.
  - With `X.expected`: rule 1 runs `./X.exe` with stdout to `X.output` and **stderr ignored**; rule 2 is `(diff X.expected X.output)`.
  - Without it: the rule is `(run ./X.exe)`, so the exit status is the assertion.
  - A `(test)` or `(library)` stanza is skipped. So are `e2e/linux`, `e2e/macos`, `e2e/stress`, `conformance` and `live/*`.
- **The generator guards itself.** `tests/dune` regenerates into `dune.inc.gen` and diffs it on both `@runtest` and `@gentests`. A new test that was never registered fails `runtest`, rather than silently never running.
  - Sorting is done with `LC_ALL=C`, because macOS and Linux collate `_` against `/` differently.
- **Per-test knobs live only in the generator**, so the exceptions can be counted:
  - `env_for`: `TSYNC_CHUNK_SIZE`, `TSYNC_MAX_CACHE`, `TSYNC_CACHE_CHUNK_SIZE`, and `TZ=UTC` for tests that render local time.
  - `deps_for`: `%{exe:../../../bin/tsync.exe}` for tests that spawn the binary, or `@runtest` may run them before it exists.
  - `platform_for`: `enabled_if (= %{system} macosx)` for preview. A gated test names no executable in its default alias, because dune would otherwise build it on every platform.
- **Workflow.**
  - `dune build @gentests --auto-promote` registers a new test.
  - `dune build @runtest --auto-promote` writes `.expected`.
  - The promoted file is the review artefact. Keep wall-clock values out of fixtures.
- **Non-hermetic tiers** run through `make -C linux e2e|stress|conformance` and `make -C macos e2e`. Stress takes `TSYNC_STRESS_SEED`, `TSYNC_STRESS_OPS`, `TSYNC_STRESS_KEEP` and `TSYNC_STRESS_FAULT`. Live takes `TSYNC_LIVE_CONFIG` and `TSYNC_BIN`.

### B1.2 Traps that made suites read green

- **`dune build` compiles neither the scenario runner nor, reliably, the content test executables.** The runner is only a dependency of the scenario `runtest` rules.
  - A removed library API can leave tests broken while every default build is green.
  - A stale `.exe` from an earlier build then runs and matches its golden file.
  - After touching a library signature, run the affected suites' aliases, for example `dune build @tests/scenario/base/runtest @tests/content/chunk_cache/runtest`, and capture *that* command's exit code (not through a pipe).
  - `dune build @check` type-checks every test executable and the runner. It is the cheap per-commit guard; it caught a new `Remote.S` member that two test doubles lacked.
  - Memory note *dune-default-alias-skips-scenario-runner*.
- **`dune build --force @<suite>/runtest` re-runs only the diff.** The `X.output` rule has a target, so its action is replayed from cache.
  - To really re-run, execute the built `.exe` with `TZ=UTC` and diff against `.expected` yourself.
  - This does not work for suites with env knobs (demand_paging, cache_cap, fetch_range, staged_groups): they must go through dune.
  - Environment variables such as `ASAN_OPTIONS` are not tracked dependencies either, so a sanitized run needs `--force`.
- **A golden diff that does not change after you added a print line means the binary is stale.**
- **stderr is ignored by the snapshot rules.** A test that fails an `assert` prints nothing useful into the diff: it just loses its trailing "ok".
- **A scenario step failure is caught and printed, and the process exits 0.** Only the diff can fail it.
- **`Scratch.dir` puts the pid in the path**, so N concurrent instances are safe. That is how load-sensitive tests are reproduced: 8 instances at a time under `nproc` CPU hogs, each diffed against `.expected`.
  - To A/B against main, use `git worktree add --detach <sha>` and build it first. A `git stash` or `git checkout` forces a rebuild, and the rebuild is what loads the box.
  - Run every iteration of one side, then every iteration of the other.
- **Spawned binaries and HOME.** `HOME` alone does not re-home a spawned `tsync` on Linux: `XDG_CONFIG_HOME` and related variables win, and CI sets them. A test that only exports `HOME` reads the runner's config, and passes on a developer machine where those are unset.
  - `Android_home.env` sets both.
  - `Android_home.paths` *asks the binary* where it keeps its config and cache, rather than hard-coding the XDG or group-container layout.
  - The e2e harness keys everything off `HOME` alone, and resolves paths by swapping `HOME` in-process.
- **Unix socket paths are capped at 104 bytes on macOS.** The e2e scratch root is kept short (`/tmp/<prefix>-<6hex>`).
- **Cross-language golden files.** `unit/hash/hash.expected` and `unit/gc_job/gc_job.expected` are parsed by `lambda/test_chunk_key.py` and `lambda/test_gc_job_key.py`. Changing their line format breaks the Python side, not the OCaml side.
- **Memory assertions use `Gc.stat`.**
  - `live_words` counts unswept garbage, so a major slice landing mid-walk flips the result; this is what makes import_listing load-sensitive.
  - `top_heap_words` is a process high-water mark, so walk_fanout's measurement is only valid as the process's first listing.
  - The fixes that made these bounds hold are runtime-independent: disk-spilled listing spools, mmapped hashtables, manifest bodies in Bigstrings, streaming instead of materialising.
- **Bigstring and mmap semantics are tested explicitly** (unit/bigstring):
  - a MAP_PRIVATE mapping survives unlink and republish-by-rename;
  - mapping a short file raises and does not extend it;
  - on filesystems that can clone, the mapping is taken from a clone, so the source can be truncated safely; without clones, SIGBUS is still possible and asserted.
  
  Anything mapping cache files must preserve this.
- **`Eintr.retry`** must also recognise `Sys_error` messages ending in `": " ^ strerror EINTR`, because the stdlib turns EINTR into a string.
- **Fork reseeding.** `Random` state is inherited by `fork`. Ids drawn in a child must reseed (unit/id).

## B2. Lwt- and functor-specific (tied to the monadic, cooperative style)

### B2.1 How the harness binds the engine

- The scenario runner (`tests/support/runner/test_runner.ml`) instantiates the engine's functors directly over a first-class `Conf_lwt.S` module:
  - `File_lwt.Make(C)`
  - `Sync_queue.Make(C)(F)` and `Meta_queue.Make(C)(F)`
  - `Pause.Make(Sq)(Mq)`
  - `Ipc_handler.Make(C)(F)(Sq)(Pause)`
  - `Replay.Make(C)(F)`
  - `Sync_poller.Make(C)(F)`
  - `Wal_lwt.Make(C)`
  - `Gc_lwt.Make(C)`, and so on.
- It calls `H.handler hooks line` in-process: there is no socket, and everything shares one `Lwt_main.run` per scenario.
- `Fixture.conf` builds through `Domain.of_config`, then grafts doubles by `include B` and overriding `store`/`members`. This is the "a double has no config to be parsed from" pattern.
- **Doubles are functors over the store** (`Outage (Real)`, `Flaky (Real)`), and `Memory ()` is generative. Each application has its own module-level state (the `up` flag, counters), so every application is a separate double.
- **Process-global state crosses functor applications.** The cursor debouncer is keyed by cursor name alone.
  - Two-client scenarios therefore use the domain name `test-<scenario>`. With a shared name, one scenario handed the next a bump aimed at a deleted backend root, and `Sync` read a gate still shut.
  - Other process-global state leaks between cases in one test process: health `trip_span` and `hold_initial` refs, `Uplink_budget` refs, `Remote.set_max_known`, `Log.recent`, the stall-warning interval, `Shutdown.grace`, and the per-domain pool registry.
- **The scenario runner never stops the queues it starts** (`stop` is `Lwt.return_unit`). Background workers from earlier scenarios keep living in the same process, harmlessly only because each scenario has its own scratch root and module instances.

### B2.2 What cooperative scheduling makes deterministic, and what OCaml 5 domains would break

Many assertions rely on Lwt's single-threaded, run-until-yield scheduling.

- **Exact-width assertions.** Pools peak at exactly 4, batch pools at exactly 3, and the uplink "settle 5 pauses". These are measured by counters incremented between yields, after a fixed number of `Lwt.pause ()`. Under Lwt, "all ready work has run" is reachable by pausing; under domains it is not, and a counter needs atomics.
- **Busy-wait loops.**
  - `Drain` spins `Lwt.pause ()` until both queues report 0 pending.
  - `Fake_clock.advance` wakes sleepers with `Lwt.wakeup_later`, so a test pauses once or twice before reading what they did.
  
  Direct-style equivalents need an explicit "run until quiescent" on the scheduler, or condition variables. They cannot simply yield.
- **Race tests only hit interleavings at yield points.**
  - promote_race, the racing `put_if_absent` in claim and conformance, and "concurrent reads of one group make one GET" all run in one Lwt process.
  - The interleavings they can reach are those at `Lwt` binds, and code between binds is atomic by construction.
  - Under OCaml 5 domains, every shared mutable table becomes a data race unless guarded: the in-flight fetch table, the known-chunks memo, per-domain memos, counters, the WAL log object shared per domain, and the debouncer.
  - Those tests would pass while missing real races. They need new coverage: stress with real parallelism, TSan, or deterministic schedulers.
- **Cancellation semantics.**
  - Several invariants are about Lwt cancellation:
    - a caller's deadline cancels the retry ladder, and no background attempt continues;
    - `pick` cancels losers;
    - `drain_for_stop` abandons without cancelling;
    - `Fake_clock` drops cancelled sleepers from `pending`.
  - Under effects these become structured-concurrency questions: which fiber owns the cancellation scope. The tests encode the *required* outcome; the mechanism must be re-derived.
- **Unbounded fan-out.** The bounded tests (bounded, chunk_pools, fetch_fanout, read_fanout, upload_fanout, batch_nesting) exist because `Lwt_list.*_p` and `Lwt.all` over data-sized lists were the recurring bug.
  - Under direct style the same bug is unbounded fibers, and a pool becomes a semaphore.
  - The rules the tests pin carry over unchanged:
    - take the slot before the resource;
    - never take a second slot from the same pool while holding one (batch_nesting's deadlock);
    - per-read pools are separate from the global budget.
- **Memory high-water marks of promises.** The upload_fanout and mirror_pools "< N words per item at first completion" checks were aimed at Lwt laying out one promise per item up front. With fibers the analogous failure is one fiber per item, and the test shape transfers.
- **The in-process Android bridge test** drives OCaml from 8 foreign pthreads, each entering and leaving the runtime around every call. Under Lwt this serialises on the runtime lock. Under OCaml 5 with domains, the bridge's registration and the shared handle table would need their own concurrency review; the test only proves "no crash, exact bytes" under the current model.
