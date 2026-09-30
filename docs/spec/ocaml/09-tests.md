# 09 — The test suite as the acceptance suite for a rewrite — OCaml implementation notes

Companion to the language-neutral spec [../09-tests.md](../09-tests.md). See [README.md](README.md) for how these notes are organised.


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
