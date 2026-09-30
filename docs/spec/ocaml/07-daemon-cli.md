# 07 — Daemon, process model, IPC and CLI — OCaml implementation notes

Companion to the language-neutral spec [../07-daemon-cli.md](../07-daemon-cli.md). See [README.md](README.md) for how these notes are organised.


## B.1 Runtime-independent OCaml learnings (still valid under OCaml 5 direct style)

- **Binary = registry filled at link time** (spec [08 §2.1](../08-frontends.md)). Each frontend/driver has a one-line
  `register ()` module; dune `(select ...)` picks `frontend_x.enabled.ml` or `.disabled.ml`
  depending on whether the optional library builds (`lib/app/frontends/dune`), and the runtime
  paths module is selected the same way per OS (`runtime.linux.ml` / `runtime.macos.ml`).
  Consequence: never resolve a registry entry at module-initialisation time (link order decides
  whether registration has happened yet); resolve at call time (`Daemons.frontend_for`,
  `Launcher.resolve`). A private `tsync_cli` library depends on the aggregators so their `select`
  is re-asked on each build of the binary.
- **Top-level error policy** (`main.ml`): `Cmd.eval ~catch:false`; `Failure msg` is a user
  sentence (print `tsync: msg`, exit 1) — every `failwith` under config parsing is phrased for a
  user; the retry layer's `Retry.Failed` prints `Retry.reason`; anything else prints like
  cmdliner's own catch plus backtrace, exit `Cmd.Exit.internal_error`. `Printexc.record_backtrace
  true` at start.
- **Exit codes outside the event loop**: calling `exit` inside the promise passed to the loop runs
  `at_exit` while the loop is still mid-run and skips the drain that follows; every command
  returns its code from the loop and exits after (`cmd_sync.ml`, `cmd_trash.ml`, ...). Under
  effects the same rule holds: `exit` from inside a fiber skips whatever the runner does after.
- **Loop death uses `Unix._exit 1`**, not `exit`: `at_exit` handlers would drain through the dead
  loop and hang (spec §3.7).
- **Backtraces across threads**: `on_loop` re-raises on the calling thread, which replaces the
  backtrace; the original is carried as `With_backtrace (exn, Printexc.raw_backtrace)` captured
  *before* re-raise, except for `Unix.Unix_error` (an answer, hot path, no capture).
- **Forked children**: module-level values are evaluated once in the launcher, so anything
  "per process" (diagnostics `started_at`, memtrace file) must be reset in the child
  (`Diagnostics.restart`, `Oneshot.trace_process` via `on_leaf`). Memtrace: one `.ctf` per process
  (`MEMTRACE=<dir>` → `<dir>/<name>.ctf`, `MEMTRACE_RATE` to raise the 1e-6 sampling) — two
  processes inheriting one trace fd drop about half their samples into a file that still reads
  clean.
- **Syslog binding is optional** (`log_syslog_provider.available.ml` / `.stub.ml`): with it, sink =
  syslog with `LOG_PERROR` only on a TTY; without, stderr. `build-info` reports which.
- **Config JSON via Yojson**, wire via `Yojson.Safe`; the wizard edits the raw `Yojson.Basic`
  tree so unknown per-link fields survive a round trip.
- **Cmdliner completion** (`Location.conv`, `Common.domain_name_conv`): completers read the config
  when the shell asks, not when the term is built, and fall back to plain file/dir completion on
  any error, so a missing config never errors on every keystroke. The same `Location.resolve`
  backs completion and parsing so the two cannot disagree (test `completion`).
- **Frontend-contributed commands take raw `string list` args**: teaching cmdliner every
  frontend's grammar would put it where the owning frontend cannot see it.
- **FUSE owns the main thread** (`Fuse.main ~loop_mode:Multi_threaded`): the OCaml event loop runs
  on a `Thread.t`, a Mutex/Condition handshake orders startup (`Domain_engine.handshake`), and the
  stop from inside must also unmount or `Fuse.main` never returns.
- **Embedding in Android** (`android_jni.ml`): the loop is detached on a thread
  (`start_detached`), JNI calls enter through `on_loop`; the serve body ends in a never-resolving
  promise because the loop must outlive `boot` (a sweep loop used to keep it alive by accident);
  failures map to errno integers for the platform callback.

## B.2 Lwt / functor-specific learnings (tied to the monadic style)

What the functor pattern bought here, and what each learning becomes under effects/domains.

- **Functor over a concurrency signature**: `Ipc.Make (Io) (Lock) (Clock) (Transport)`,
  `Job_report.Make (Io) (Clock) (Pools) (Send) (Link)`, `Shutdown.Sleep (Io) (Clock)` keep the core
  scheduler-agnostic; `lib/lwt/...` applies them to `Io_lwt` (`Ipc_lwt`, `Job_report_lwt`, ...).
  `lib/app` itself is **not** functorised (hundreds of direct `Lwt` references: `Domain_engine`,
  `Ipc_handler`, `Launcher`, `Diagnostics`). Under direct style the functors collapse to plain
  modules; the seam worth keeping is the *transport* (`TRANSPORT`: connect/read_line/write_line/
  flush/close/serve/shutdown) and the clock (so tests turn a hand-driven clock, `tests/unit/shutdown`).
- **Per-domain modules via first-class modules + functors** (`Domain_engine.Make (C)`,
  `Diagnostics.Make (C)`, `Ipc_handler.Make (C) (F) (Sq) (Pause)`): each functor application
  creates fresh module-level state — e.g. the mutation `Lwt_mutex` is per application, i.e. per
  domain per process, and `Pause`'s switch is per application too, which is exactly why the
  parent's poller and the frontend's queues hold **different** pause flags (B.4).
  In a rewrite make such state an explicit value owned by the per-domain engine instance.
- **The Lwt pitfalls that shaped this code**:
  - *Forking*: `Lwt_engine`/notification eventfd is created at module init; a plain `Unix.fork`
    shares it and the child's worker completions wake the parent. Use `Lwt_unix.fork` and touch
    nothing Lwt before forking (`launcher.ml` header). Under OCaml 5: never fork after domains or
    systhreads have started; fork first, then start schedulers.
  - *Engine*: default engine is `select`; above FD_SETSIZE it raises EINVAL and kills the loop.
    `Frontend.use_libev` requires `Lwt_sys.have \`libev` (checked, not assumed: `conf-libev`
    installed only means the C lib exists) — fails with a sentence otherwise.
  - *Blocking pool*: `Lwt_unix.set_pool_size` is a ceiling Lwt grows to and never shrinks from;
    set it in the leaf after forking (`cap_blocking_pool`). Under OCaml 5 the analogue is a fixed
    pool of systhreads/domains for blocking calls — still bound it by domain budgets.
  - *`Lwt_io.establish_server` / `open_connection` set TCP_NODELAY* on every socket unless
    `~set_tcp_nodelay:false`, tolerating only EOPNOTSUPP; on macOS an AF_UNIX socket whose peer
    hung up answers EINVAL, the exception escapes the accept loop and the server is dead while the
    process lives (`tsync status` hangs, File Provider looks deadlocked; d8f854af,
    `ipc_lwt.ml`). Any rewrite's transport must not set socket options that can fail on unix
    sockets, and must never let one connection's error end the accept loop.
  - *`Lwt.async_exception_hook`* defaults to exiting the process; every daemon host replaces it
    with a logger. Under effects: an unhandled exception in a detached fiber needs the same
    explicit policy.
  - *Exceptions outside any promise* (raised inside libev dispatch, e.g. an SSL read) escape
    `Lwt_main.run` and are invisible to `Lwt.catch` and the async hook → `loop_died`.
  - *Cancellation is a failure*: `Lwt.cancel` / `Lwt_unix.with_timeout` fail the promise with
    `Lwt.Canceled`, which queues record as a permanent job failure. Stops therefore **race**
    (`Lwt.choose [work; sleep grace]`) and leave the loser running to process exit. Under effects,
    cancellation semantics must be designed so a stop is distinguishable from failure (the
    `Shutdown.Stopping` exception exists for this).
  - *Waking a resolved wakener raises* (`Lwt.wakeup_later` twice): every stop path checks
    `Lwt.state` first or uses a `woken` flag.
  - *`Lwt_preemptive.run_in_main`* is the bridge for libfuse and JNI threads (`on_loop`).
  - *Signals*: `Lwt_unix.on_signal` for SIGTERM/SIGINT; libfuse may install its own handlers and
    override them.
- **Cooperative scheduling is load-bearing** (spec §7): the monad marks every point where
  another task may run (`let*`), and code like `Subs.write_pending`, `Change_notice.flush`,
  `Shutdown.request`, `Launcher.ask_rescan`, `Diagnostics.refresh` relies on "no bind, no
  interleaving". Under effects, a direct-style call may suspend without any syntactic marker, so
  these invariants become invisible; with multiple domains they become data races. Keep all of
  this state on one domain (one main scheduler worker plus blocking threads) or protect each item
  listed in spec §7.
- **Unbounded concurrency discipline**: every `Lwt_list.map_p` here is config-wide with a deadline
  per leaf (status fan-outs, 16 sampled shards); data-wide fan-outs elsewhere use `Bounded`
  pools. Under effects an unbounded `map_p` becomes unbounded fibers and a pool becomes a
  semaphore; the rule "width chosen by the code, not the data" is unchanged.
- **Duppy exploration (2026-09-21, nothing built)**: motivation — duppy (liquidsoap's
  effects/domains rewrite) schedules on actual constraints (worker queues, blocking vs
  non-blocking classification, `max_blocking`) globally, where Lwt asks every call site to decide
  scaling, and direct style removes monad syntax. Cost map: the `lib/lwt` seam is ~1,000 lines of
  functor applications (Core/Lock/Clock/syscalls over duppy ≈ 500 lines plus a homemade promise
  with cancel semantics — the riskiest part); expensive: HTTP/TLS/S3 on cohttp-lwt-unix/conduit/
  `Aws_s3_lwt.Io`, `lib/app` (~378 direct Lwt refs), tests (~1,019 refs in 104 files).
  Recommended order: (1) make `Io.S` direct-style while still on Lwt (`Lwt_direct`, unverified to
  exist in Lwt 6; needs OCaml 5 while `tsync-libs` says ≥4.14); (2) HTTP on libcurl in threaded
  tasks (open: S3 signing, libcurl on Android); (3) swap the scheduler as a replacement, never a
  permanent second one. `Bounded` pools stay regardless; one main worker plus blocking threads,
  no domain parallelism. Unchecked: Android/macOS compiler versions, GPL-2+ duppy vs tsync's
  licence.

## B.3 Mapping to the current code

| Spec concept | Current code |
|---|---|
| supervisor (`tsync start`) | `lib/app/cli/launcher.ml` (`Launcher`), the "sync" parent process |
| owner / presenting engine / converging engine | `lib/app/cli/runner/daemon/engine/domain_engine.ml` (`Domain.start`, `converge`, `start_queue`) |
| request handler | `ipc_handler.ml`, `item_row.ml`, `ipc_error.ml` |
| stop signal | `lib/core/shutdown.ml`; `Domain_engine.drain_for_stop`; `Frontend.fork_each`/`run_forked`/reap |
| IPC transport | `lib/core/ipc.ml`, `lib/lwt/core/ipc_lwt.ml` (with `Subs`) |
| one-shot lifecycle | `lib/app/cli/oneshot.ml` (`Oneshot.run`) |
| path arguments | `lib/app/cli/location.ml` |
| status collection | `Diagnostics`, `Status_report`, `Job_registry` under `runner/daemon/diagnostics` |
| job report | `lib/core/job_report.ml` |
| menu model | `lib/app/ui/menu.ml` (`Tsync_menu`) |
| wizard | `lib/app/wizard/wizard.ml` |
| maintenance list | `Maintenance_lwt` (`task = {name; triggers; run}`), `Domain_engine.run_maintenance` |
| runtime paths, service manager | `lib/local/runtime/*_runtime.ml` |
| descriptor limit | `Descriptors.raise_to ~target:8192` |

## B.4 Where the current code differs from the spec

The code at the spec's extraction commit implements an older process model. A rewrite, or a port of
the code towards the spec, has to change at least the following.

**Process model.**
- The `tsync start` parent converges every domain (reconcile, poller, maintenance, deferred
  resume) and presents none; each frontend group is a forked child that presents and runs its own
  upload and metadata queues over the same on-disk state. Nothing takes an ownership lock: the
  mirror, staged tree and WAL are written by the parent, every frontend child and `tsync sync`
  with in-process Lwt mutexes only (finding F7, including the confirmed loss of a staged edit to a
  concurrent peer delete).
- The parent tells frontends about applied peer changes with batched `changed` notices
  (`lib/lwt/core/change_notice.ml`, 0.2 s, ≤ 512 keys) sent to every frontend socket. Under the spec
  the hook is called in-process by the owner and the `changed` action disappears.
  `Change_notice.for_domain` caches the socket list on first use and ignores later lists.
- Replica/backfill logs are resumed only by the parent (`Domain.start_resumed`); frontends record
  and send `rescan` to the sync socket; one-shot commands build with `resume:false` and run their
  own posts under the durable-queue claim (RUNNER role). Android builds with `resume:false` and has
  no resumer at all (finding G7).
- The http-proxy child builds a presenting engine (`D.start`, `D.drain`) and its share server reads
  through the domain's chunk cache (`Data`).
- One-shot `import`/`rsync` write the mirror directly (`Mf.write`) and `tsync sync` reconciles,
  drains and rebuilds in the CLI process beside a running daemon (no guard).
- Children are forked with `Lwt_unix.fork` in config order; the parent does not restart a child
  that dies, so a crashed FUSE process leaves its domain unmounted until `tsync restart`.

**Pause.** `tsync pause` reaches only the frontend process behind the domain socket
(`Pause.set`, a plain `ref`); the parent's poller runs with the parent's own `Pause` instance, which
nothing sets, and the sync socket has no `pause` action (finding G8). The flag is in memory only.

**Stop.**
- The File Provider router serves without `until`, has no signal handler, never requests
  `Shutdown`, and drains its domains sequentially after the listener closes, so a stop with a store
  down can hang indefinitely (finding G10).
- `tsync stop` prints "No IPC-backed frontend running; relying on signal." and sends no signal; it
  prints `Stopped N domain(s).` without waiting for anything to exit.
- The domain handler returns control `Stop` for `stop` even when its reply is an error.

**IPC.**
- `Ipc.send` (the blocking CLI client) has no timeout and leaks its descriptor on an exception
  (finding G9); the in-loop client defaults to 2 s.
- The File Provider router's own errors (`cannot tell which domain…`, bad JSON) omit `code`
  (finding H2).
- Socket files are created with default modes (0755 seen); the directory is 0700 only when the IPC
  server creates it (the durable queue creates 0755 directories under the data dir); no peer
  credentials are checked.
- There are no detached jobs; long requests (`restore`, `ensure_cached`) are synchronous.
- Status falls back to asking every frontend socket, each of which probes every backend.

**Other.**
- A missing or invalid config: both exit 0 (`tsync start`); the units have no
  `RestartPreventExitStatus`.
- `Job_registry` keys on pid only.
- The wizard writes `config.json` and then `chmod 0600`s it (a window with default permissions).
- Memtrace leaf names are per frontend group, so per-binding children share a name.
- The fd soft limit target is 8192 while the unit grants 65536.
- Docs: DOCUMENTATION.md says `sync --full` "clears the local cache" (it rewrites the mirror in
  place) and that jobs report to "its domain's daemon" (they report to the sync socket).

## B.5 Conformance checks in the current test suite

| Spec §9 item | Test |
|---|---|
| drain raced, not cancelled | `tests/unit/drain_for_stop` |
| reaping, SIGKILL after grace, stop reaches children first | `tests/unit/fork_reap` |
| server stops by socket / `until`; socket removed | `tests/unit/ipc_serve` |
| subscription semantics | `tests/unit/subs` |
| stop signal, sleeps, hooks, retry ladder | `tests/unit/shutdown` |
| process stop leaves jobs on disk | `tests/unit/queue_stop` |
| stop publishes the cursor bump | `tests/frontends/stop_publishes_cursor` |
| presenting process uploads and publishes; maintenance list | `tests/frontends/presenting_domain` |
| pause holds queues, drain completes | `tests/scenario/pause` (single process only) |
| job registry | `tests/unit/job_registry`, `tests/unit/job_render` |
| status request shape, folding, cost, held members | `tests/unit/status_ask`, `status_report`, `status_cost`, `status_held` |
| menu rendering | `tests/unit/menu` |
| completion and path refusal | `tests/unit/completion` |
| export path spellings | `tests/unit/export_cli`, `export_display` |
| socket survives rename (e2e relay) | `tests/e2e/ipc_tap` |
| real daemon start/stop | `tests/e2e/linux`, `tests/e2e/macos` |

Not covered today: ownership, pause across processes, a wedged daemon against every CLI command,
the File Provider stop bound, detached jobs, peer-credential refusal.

## B.6 Resource strategy and superseded designs

- **Blocking pool**: `min(256, max(32, 8 × Σ(maxUploads + maxDownloads)))` over the domains a
  process serves, set after all forking (`cap_blocking_pool`). The pool never shrinks, so its ceiling
  is a memory floor (a mount at 256 settled at ≈114 MB).
- **Status sampling**: the chunk count estimate lists 16 evenly spaced shards and scales.
- **IPC bounds** used today: line 1 MiB, 256 connections, subscriber backlog 256 (the spec's values
  are 01's).
- A first normative draft specified *detached jobs* (`"detach":true`, `job` polling) for long IPC
  requests; it was replaced by bulk actions bounded by progress plus the `ping` liveness probe
  (failure-model §8.2), which needs no job table.
- **The status report is typed end to end** (`Status_report`, with `[@@deriving yojson]`): owners, the store server and the supervisor build records, `tsync status` renders records, and JSON exists only on the socket and in `--json`. The wire shape follows §5.5 with three groupings the types impose: a backend's `reachable`/`latencyMs`/`error` sit under `reach`, a process's `server`/`process`/`uplinks`/`traffic`/`recentErrors` under `self`, and `sync.state`/`reason` read as one optional `hold`.
