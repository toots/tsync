# 07 — Process model, lifecycle, IPC and CLI — OCaml implementation notes

Companion to the spec [../07-daemon-cli.md](../07-daemon-cli.md). Not normative: where each part of
it lives in the code, where the code departs from it, and what the code learned. Section numbers in
parentheses are the spec's. The request handler itself is in [08-frontends.md](08-frontends.md).

## Where each part lives

| Spec | Code |
|---|---|
| Owner assignment (§2.4) | `Supervisor.assign`: one `owner --domain D` child per domain whose frontend is `` `Per_domain `` or that has none, one `owner` child for every `` `Shared `` domain together, one `store-server` child when a domain lists `http-proxy`. The topology is `Frontend.t.presenting`. |
| Ownership lock (§2.3) | `Owner.acquire`, `release`, `holder`: `Fs.flock` on a close-on-exec descriptor of `Paths.ownership_lock`, then the holder record. `Owner.owner_held` is 75. |
| Owner start, serve and stop (§3.2, §3.4) | `Owner.run`, and `serve` inside it: `Domain.build ~owner:true`, the engine's `start`, a `housekeeping` fiber, `Handler.create`, `Ipc.serve`, the recovery notice, then the frontend's presentation. At the stop: `draining` is set, every engine's `drain` runs concurrently, the socket closes. |
| Owner requests and the one-shot fallback (§2.5, §3.5) | `Owner.request`: `Owner.ask` over the socket, else `Owner.one_shot`, which takes the lock as role `command`, starts the engine with `~poll_journal:false`, calls `Handler.call` in process and drains before `release`. |
| Owner jobs (§2.5) | `Jobs.t`, `Jobs.run`; `Handler` `run_job` and `cancel`; `Protocol.Job`, `Protocol.Cancel`; `Cli.run_job`. Cancellation points: `Cancel.check`, `Cancel.race`, `Cancel.batches`. |
| Pause (§2.6) | The engine's `set_paused` and `is_paused` over `Engine.pause_flag`; `Protocol.Pause`; `Protocol.refused_while_paused`. |
| Runtime paths, service manager (§2.7) | `Tsync_config.Paths`, `Tsync_config.Service`. |
| Service units (§2.8) | `linux/tsync.service`, `linux/tsync@.service`; `Service.agent_definition`, `macos/install-agent.sh`. |
| `tsync start` (§3.1) | `Daemon_cmds.start`, then `Supervisor.run`: the supervisor lock (`Paths.supervisor_lock`), `Ipc.serve`, `Uplink.own`, `supervise`. On macOS `Daemon_cmds.macos_service`. |
| Supervision and its stop (§3.3, §3.4) | `Supervisor.keep_running`; `supervise`, `reap_one`, `stop_children`. A child is a fresh execution of the binary (`Unix.create_process`) running the internal `owner` or `store-server` command. |
| Embedded host (§3.6) | `Owner.embed`, `Owner.maintain`. |
| Hosting (§3.7) | `Rt.run_sync` for the main thread and foreign threads; `Owner.host`, `register_host`, `host_for`; `Owner.stop_on_signals`. |
| Sockets, envelopes, deadlines (§4.1–§4.3) | `Tsync_ipc.Ipc`: `serve`, `close`, `publish`, `subscribers`, `Client`, `call`, `call_bulk`, `call_stream`, `advisory`, `ok`, `failure`. |
| Supervisor socket (§4.4) | `Supervisor` `handle`: `stop`, `stats`, `report`, `uplink`. |
| Job reports and registry (§4.6) | `Handler` `send_report` through `Ipc.advisory`; `Supervisor` `record_job`, `live_jobs`. |
| CLI conventions (§5.1) | `Cli`: `domain`, `run`, `fail`, `Exit_with`, `verbose`, `duration`, `run_job`; `Display`; `Narrate`. |
| Commands (§5.3) | `Daemon_cmds`, `Status_cmd`, `Domain_cmds`, `Store_cmds`, `Setup_cmds`. Frontend groups: `Daemon_cmds.frontend_cmds`, from `Frontend.t.commands`. |
| `tsync stop` (§5.4) | `Daemon_cmds.stop`, `wait_gone`, `owner_sockets`. |
| `tsync status` (§5.5) | `Status_cmd.report`, `fold_owners`; `Supervisor` `machine_report`; `Report.domain_body`, `Report.traffic`; `Self_report.self`; the types of `Status_report`; `Status_text.render`. |
| Logging (§5.7) | `Log`: `min_level`, `prefix`, `sink`, `once`, `recent`. |
| Menu model (§5.8) | `Menu.render`, `Menu.stats_entries`. |
| Config wizard (§5.9) | `Config_wizard.edit`, `prepare`; `Setup_cmds.edit_config` writes with `Fs.durable_replace ~perm:0o600`. |
| Maintenance (§6) | `Owner` `housekeeping`: every 60 s the engine's `poll` and `trim_cache`, `rearm` every `Dqueue.rearm_interval`; daily `Export.sweep_records`, `prune_applied`, `daily_maintenance`. |

## Where the code departs from the spec

- **Commands.** `ls`, `cache` and `set-aside` do not exist, nor do the `prune` and `set_aside`
  actions. `sync` takes no `--source` and no `-j`.
- **Status totals.** `status` takes `--json` and `-w` only. The supervisor forwards the `stats`
  argument, and an owner ignores it (`Owner` `stats_reply`): `Status_report` has no store totals.
- **Status self-description.** `Status_report.self` has no `pools` and no `backend` block. With no
  supervisor, `Status_cmd.fold_owners` reports no uplinks, no jobs and no warnings.
- **Jobs.** One job runs per domain at a time (`Handler` `run_job`): a second one is refused
  `busy` whether or not it would conflict. A job's report carries its fraction as counts out of 100.
- **Logging.** There is no syslog sink. Every process logs to stderr, `build-info` prints
  `log sink: stderr`, and `tsync logs` reads `journalctl -t tsync`, so the Linux service depends on
  its unit sending stderr to the journal.
- **Progress on a terminal** is one line redrawn in place with the elapsed time (`Display`), not a
  block with a bar.
- **Loop death (§3.7).** The runtime is a pool of domains with no single loop to die. A failing
  scheduler task is logged with its backtrace (`Rt.task_error`, set by `Log`) and a failing detached
  fiber with its name (`Rt.detached_failure`); neither ends the process.

## Learnings

- **Signals are blocked, not handled.** `Owner.stop_on_signals` blocks SIGTERM and SIGINT with
  `Thread.sigmask` and one thread takes them with `Thread.wait_signal`. It runs before the runtime
  starts a domain, so every thread inherits the mask.
- **The runtime starts lazily.** `Rt` starts its domains at the first use, so a command decides its
  signal mask, descriptor limit (`Fs.raise_nofile`) and log destination first.
- **The exit status leaves the runtime as a value.** `Cli.run` answers what `Rt.run_sync body`
  answers, and `bin/tsync.ml` exits after `Cmd.eval'`. `Cli.Exit_with` carries a status out of a
  body. Only the second interrupt of a job uses `Unix._exit 130`.
- **Failures print a sentence.** `Cli.run` classifies whatever escapes (`Fail.classify`), prints
  `tsync: <reason> (<repair>)`, and answers 125 for an unexplained failure, 1 otherwise. An invalid
  config in `start` is 78.
- **Shared state is atomic or locked**, since a fiber resumes on any domain: the supervisor's job
  registry is an `Atomic` list replaced by compare-and-set, a handler's running job an `Atomic`
  slot, the owner's `draining` flag an `Atomic`.
- **Teardown is a `Fun.protect ~finally`** ([README](README.md) lesson 8): the owner drains every
  engine it started and closes its socket on a stop and on a failed start alike; the supervisor
  stops its children, then closes its socket, so `stats` and `stop` answer until they are reaped.
- **The lock's descriptor is closed when the holder record cannot be written** (`Owner.acquire`,
  pitfall C-7.10): a kept descriptor would hold the lock for a process that is not an owner.
- **A refused connection is not an absent owner.** macOS refuses a connection to a full backlog as
  it does one nobody listens on. `Owner.served` reads the holder record and checks its pid, and
  `Owner.retry_refused` retries every 100 ms until the request deadline while a holder serves.
- **Execution class per request** (01 §6.5). `Ipc.serve` answers `ping` before the handler, runs a
  connection's reads and writes as `` `Immediate `` and the handler as `` `Threaded `` unless
  `?execution` says otherwise; the supervisor answers `uplink` as `` `Direct ``.
- **Peer and directory checks** are in `Ipc.serve`: the socket's directory is created 0700, a
  path longer than `sun_path` is refused before the bind, and each connection's peer uid is read
  with `Fs.peer_uid` (`SO_PEERCRED` on Linux, `getpeereid` on macOS).
- **A job's lines are throttled at the socket**, not in the job: `Handler` `throttled` sends at
  most one progress line per 0.25 s and the latest held one before any other line.
- **A job ends with `Usage.release`**, and housekeeping with `Usage.release_if_grown`
  ([memory.md](memory.md) M.4).
- **The macOS service opens its own log** (`Daemon_cmds` `log_to_service_file`): an agent
  registered through SMAppService cannot name a path under the user's home for its output.
- **The status report is typed end to end** (`Status_report`, `[@@deriving yojson]`): owners, the
  store server and the supervisor build records, `tsync status` renders records, and JSON exists
  only on the socket and in `--json`. Three groupings differ from §5.5's wire: a backend's
  reachability sits under `reach`, a process's own figures under `self`, and `sync.state` and
  `reason` read as one optional `hold`.

## Parameters in the code

| Where | Values |
|---|---|
| `Ipc` | line 1 MiB, 256 connections, subscriber backlog 256, request deadline 30 s, client deadline 35 s, advisory 2 s, liveness probe every 10 s with a 5 s deadline |
| `Supervisor` | backoff 1 s to 60 s, stable after 60 s, reap margin 2 s, reap poll 0.05 s, job stale after 45 s, finished job kept 300 s |
| `Handler` | job report every 10 s, progress line every 0.25 s |
| `Report` | probe window 5 s, journal window 60 s, listing grace 2 s |
| `Owner` | housekeeping every 60 s |
| `Rt` | 2 to 8 domains, at most 256 blocking threads (finding 94) |

## Tests

`tests/owner/{owner,shared,supervisor,jobs,menu,protocol}_test`, `tests/ipc/ipc_test`,
`tests/status/render_test`, `tests/config/{config,wizard}_test`, and the runtime's own
`tests/unit/rt*_test`. Each is a snapshot (`<exe>.expected`).
