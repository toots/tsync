# 09 — Conformance — OCaml implementation notes

Companion to the language-neutral spec [../09-tests.md](../09-tests.md). Not normative. Section numbers
in parentheses (§n) refer to the spec; pitfall IDs to [../../pitfalls/](../../pitfalls/README.md);
finding numbers to [the 2026-10-01 review](../../review/2026-10-01-rewrite.md).

## T.1 The harness: one executable, one snapshot

- A test is an executable that prints what it checked. Its `dune` file holds two rules: one runs it
  with stdout to `<name>.output`, one diffs that against the committed `<name>.expected` under the
  `runtest` alias. The diff is the verdict (§4, §10.5); there is no assertion library and no check
  counter.
- A change of behaviour reads as a diff of the snapshot. `dune build @runtest --auto-promote` writes
  the new `.expected`, which is the review artefact.
- Only stdout is captured. A test that expects a failure prints its kind (`Fail.kind_name`) or the
  exception as a line; an exception that escapes ends the run rule with a non-zero status before any
  diff (pitfall B-12.4).
- A test that needs fibers enters the runtime with `Rt.run_sync`; tests of pure modules
  (`formats_test`, `plan_test`, `uplink_law_test`) do not. A test with local state builds its scratch
  root under the temporary directory with its pid in the name, so concurrent runs do not share it
  (§10.6, pitfall B-12.11).
- A test that cannot run on a platform is reported, not skipped (§10.1): its rules carry `enabled_if`,
  and a second `runtest` rule echoes "`<name>`: not run, …" where the first is disabled
  (`mapped_pages_test`, `config_test`, `wizard_test`; pitfall B-12.12).

| Directory | Subject |
|---|---|
| `tests/unit` | the runtime (`rt_test`, `rt_fd_test`, `rt_class_test`), core codecs (`core_test`), `dqueue_test`, `dqueue_raise_test`, cache group states, the uplink budget, law and modes, mapped pages; `hash` and `gc_job` are golden files |
| `tests/store` | the store contract over each driver, the composite, the copy memo, the chunk spaces, the proxy wire, watches, share serving |
| `tests/remote` | manifest and marker codecs, the folder index, the remote layer |
| `tests/sync` | formats and both conflict tables (`formats_test`), recovery, two clients, offline work, the poller, the change feed, import, export, rsync, rebuild races |
| `tests/gc` | `Gc_plan`, the collector, resume, queued discards, verify, retention, integrity, mirror, shares |
| `tests/http`, `tests/ipc` | the HTTP client and server over both TLS implementations, the IPC server and client |
| `tests/owner`, `tests/status`, `tests/config` | the request handler, jobs, the supervisor, the menu, status rendering, config parsing, the wizard |
| `tests/android` | the bridge called from foreign threads (`stress_stubs.c`), the command group, the lazy tree |
| `tests/support` | `Test_support.remove_root` |
| `tests/bench` | manual measurements (`rebuild_mem`, `class_bench`): built by the default alias, run by nothing |

## T.2 Harness seams

- **Domain configuration as a value (§5.1).** A test builds a module `C : Engine_ctx.S` by hand (a
  `Local.create` store in the scratch root, wrapped in `Composite.create`) and applies `Engine.Make`;
  `tests/sync/two_clients_test` applies it once per client over one store. `max_uploads = 1` keeps the
  applied log deterministic, and a store built without a link is never governed (`Uplink.none`).
- **Direct engine surface (§5.5).** Steps call the engine: `E.create`, `write`, `close`, `rename`,
  `E.apply_pass` for one pass without the poller's timer, `E.drain`, `E.set_paused` to hold the queues,
  `E.resync`, `E.bridge`.
- **Request interface (§5.4).** `tests/owner/protocol_test` checks the request codecs; `owner_test` and
  `shared_test` serve a real socket and call it.
- **Processes (§5.8).** `tests/gc/lock_holder.exe` is a second process holding the run lock;
  `supervisor_test` runs the supervisor over a child that fails to start, and the Android `cli_test`
  spawns the `tsync` binary once per call.
- **Clock (§5.6).** The uplink budget, law and split, and `Gc_plan`, are pure and handed `now`;
  `Health.create ?now` takes a clock. The engine, the queues and the cursor debouncer have no clock
  seam: their tests run on the real clock.
- **Filesystem (§5.7).** There is no filesystem capability to wrap.

## T.3 The store contract

`tests/store/contract.ml` is a library with one entry, `Contract.run ?domain_name store`: it prints the
generic conformance of [06 §10](../06-backends.md) for a snapshot, with keys under `tsync/<domain>/`
that the output never shows, so every driver is diffed against the same lines.

- It runs over the local driver (`local_test`), the proxy client against an in-process store server
  (`proxy_test`), and S3 and GCS (`s3_test`, `gcs_test`).
- The cloud tests run against a fake by default: a `Tsync_http.Server` on a loopback port that the
  test itself implements. With the `TSYNC_CI_*` variables set they run against a real bucket; those
  variables are `env_var` dependencies of the rule, so a cached run against the fake is never replayed
  as a real one. `TSYNC_CI_REQUIRE_REAL` lists the stores that must be real (`Contract.real_required`).
- `gcs_test` is `(optional)` and links the native TLS implementation; its rules are enabled only
  where that library is built, and CI checks that it is (finding 36, pitfall B-11.1).

## T.4 Doubles

- `Store.t` is a record of functions, so a double is a real store with a few fields replaced:
  `{ s with list_prefix = … }`. There is no module of named doubles; each test writes the one it
  needs (`flaky`, `staged` in `tests/sync/poller_retry_test`, `flaky` in `tests/gc/integrity_test`).
- A double refuses or holds on a condition the test controls: an `Atomic` counter of failures left, or
  an `Rt.Promise` the call waits on. A refusal names its verb and its key prefix, so background work
  does not consume it (§5.3).
- The double wraps the member's store before `Composite.create`, never the composite alone: chunk
  reads and copy jobs reach members, and a double above them sees none of it (pitfall B-12.9).
- Cross-language golden files: `tests/unit/hash/hash.expected` and `tests/unit/gc_job/gc_job.expected`
  are read by `lambda/test_chunk_key.py` and `lambda/test_gc_job_key.py`. Their line format belongs to
  the Python side as well (§4.4, pitfall B-11.11).
- `tests/store/gc_scoping` is a snapshot of a `grep` over `lib/`: the sources that name the outgoing
  chunk space. A new line is a caller that learned a collection exists.

## T.5 Traps that are real in this tree

- **A plain `dune build` compiles no test.** The root `default` alias builds `bin`, `lib`, `vendor`
  and `tests/bench`. After touching a library signature, build `@runtest` (or one directory's alias,
  `@tests/sync/runtest`) and read that command's exit status, not a pipe's (pitfall B-12.3).
- **`--force` replays a cached `.output`.** The run rule has a target, so forcing the alias re-runs
  the diff, not the executable. An environment variable that is not a declared dependency does not
  invalidate it either (pitfall B-12.3).
- **A snapshot that does not change after a print was added means a stale binary** (pitfall B-12.3).
- **`(optional)` hides a broken stanza.** An executable whose library is missing is silently not built,
  and its `enabled_if` rules then run nothing (pitfall B-11.1).
- **Deferred work outlives a case.** A composite's `settle_later` can write a lock file under a scratch
  root the test is removing; `Test_support.remove_root` retries the removal (pitfall B-12.11).
- **A wait on a duration is a verdict from elapsed time** (§10.3, pitfall B-12.5). Tests wait on a
  state (`Dqueue.idle`, a promise the double resolves) with a bounded poll; the ones that still sleep a
  fixed time are listed below.
- **Order under parallelism.** Fibers run on a pool of domains, so two jobs finish in either order.
  A test that prints an order holds the component (`E.set_paused`, one upload worker) or sorts what it
  prints (pitfalls B-12.6, B-12.7).
- **Snapshots must hold on every machine**: no line states a filesystem's capability, a readdir order
  or a locale's collation (pitfall B-12.8).

## T.6 Gaps against the spec

- **No crash-at-every-step or power-loss harness (§7.2, §7.3).** Crash windows are built by hand
  (`tests/sync/recover_test`, `tests/gc/resume_test`); nothing kills at a labelled durable step, and
  no seam orders fsync against publish.
- **No property-based conflict run (§8).** `formats_test` prints both tables exhaustively, fact to
  decision; the two-client tests pick pairs by hand.
- **Fixed sleeps as negative waits** (finding 158): `tests/store/spaces_test`, `tests/unit/dqueue_test`,
  `tests/gc/queued_test`. Under load a broken guard passes.
- **Tests that cannot fail for their reason.** The Dqueue "cancels the running one" case gives the
  same log when the job ends normally (finding 105); "callbacks one at a time" in `remote_test`
  depends on a `Thread.yield` window (finding 106); the proxy watch test passes at the 2 s polling
  floor (finding 103); the S3 signature verifier uses the product's own canonicaliser (finding 159).
- **Native TLS** (findings 99, 100, 152). Body bytes are not checked against position-dependent data,
  multi-record writes are untested, system trust is seen to succeed only in the dispatch-only
  conformance job, and the piecewise-read test hangs on an early end of file instead of failing.
- **Cleanup hides the cause** (finding 153): an exception in the cloud tests' cleanup masks the
  contract's failure. `s3_test` scopes real objects by pid alone (finding 154).
- **Environment-dependent snapshots** (finding 157): `gc_scoping` sorts without a pinned locale, and
  `config_test.expected` lists the backends and frontends of the build.
