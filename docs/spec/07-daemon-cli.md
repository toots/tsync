# 07 — Daemon, process model, IPC and CLI

Scope: `bin/`, `lib/app/cli` (commands, `Launcher`, `Oneshot`, `Location`, `Daemons`, `Common`),
`lib/app/cli/runner/daemon/engine` (`Domain_engine`, `Ipc_handler`, `Item_row`, `Ipc_error`),
`lib/app/cli/runner/daemon/diagnostics` (`Diagnostics`, `Status_report`, `Job_registry`),
`lib/app/ui` (`Menu`), `lib/app/wizard` (`Wizard`). Also the process-level pieces those sit on
and nobody else owns: `lib/core/ipc.ml` + `lib/lwt/core/ipc_lwt.ml` (wire transport),
`lib/core/shutdown.ml` (stop), `lib/lwt/core/change_notice.ml`, `lib/core/job_report.ml`,
`lib/core/log.ml`, `lib/local/runtime/*` (paths, service manager), `lib/app/frontends/api/frontend.ml`
(the frontend registry and the fork/reap primitives). Frontend internals (FUSE, File Provider,
http-proxy, Android) are another spec; only their contract with the launcher/engine is here.

This file is the language-neutral specification. The [OCaml notes](ocaml/07-daemon-cli.md) hold OCaml implementation
notes, split into runtime-independent learnings and Lwt/functor-specific ones.

---


## 1. Problem

tsync is one binary (`tsync`) that is both a long-running service and a toolbox of one-shot
commands. This subsystem decides:

- **what runs where**: which OS processes exist when the service is up, which of them owns
  shared per-domain state (mirror, applied-through bookmark, staged tree, deferred-copy queues,
  link governor), and which merely present a domain to a user (a FUSE mount, a File Provider
  extension's daemon, an HTTP listener);
- **how they talk**: a line-delimited JSON request/reply protocol over Unix-domain sockets,
  shared by the CLI, the macOS File Provider extension (Swift), the tray/menu-bar, the
  converging parent and the frontends among themselves;
- **how the service starts and stops**: config-less start, fd limit, forks, supervision of
  children, a stop bounded by a *grace* (10 s) after which unfinished work is left owed on disk;
- **how one-shot commands behave beside a running daemon**: they run their own event loop,
  drain what they owe before exit, report progress to the daemon advisorily, and lease upload
  bandwidth from it;
- **how the machine reports on itself** (`tsync status`): one process assembles a report from
  every other process's self-description, with every fan-out bounded by config width and every
  leaf by a deadline.

It is separate because the domain library (sync, checkout, backends) is parameterised by a
domain configuration and knows nothing of processes, sockets or the CLI. Everything
process-shaped is pushed here, into one place that sees the whole (domain × frontend) matrix.

---

## 2. Concepts & data model

### 2.1 Process model (service running)

```
tsync start                         ("sync" process: parent, converges every domain)
 ├─ owns: sync socket  <data_dir>/tsync-sync.sock
 ├─ owns: link governors (uplink "owner"), deferred replica/backfill queues (resume=true)
 ├─ runs per domain: reconcile, sync poller, maintenance sweeps, upload+metadata queues
 │
 ├─ fork: frontend group "fuse"   (topology `Process_per_binding)
 │     ├─ serves last fuse binding itself (FUSE main loop holds main thread)
 │     └─ fork: one child per other fuse binding
 │          each: domain socket <data_dir>/tsync-<domain>.sock (Linux)
 ├─ fork: frontend group "http-proxy" (`One_process, all its domains)
 │          proxy socket <data_dir>/tsync-http-proxy.sock + TCP listener
 └─ fork: frontend group "file-provider" (macOS, `One_process, all domains)
            one socket <data_dir>/tsync.sock for every domain, routes on "domain"
```

- One process per **frontend name** (group), forked from the parent in config order of first
  appearance (`Launcher.bindings_by_frontend`). Within a group, `topology` decides: one process
  for all its bindings, or one per binding (`Frontend.run_forked`: the *last* binding runs in
  the group process, the others in forked children).
- Frontends whose `serving = Commands hint` (Android) are never run by the launcher; if any
  configured frontend is such, `tsync start` fails **before the first fork** with `hint`.
- The parent ("sync") presents no domain. It is the only process that runs convergence work
  for a domain (commit cb2be7ac): reconcile, poller, sweeps write state shared by all processes
  of the domain and are arbitrated by none, so exactly one process may run them.
- Every presenting process runs its **own** upload queue and metadata queue for what it accepted
  (in-memory workers; each posts only what it was handed). Presenting (`Domain.start`) never
  runs reconcile/poller.
- Frontend processes are **lessees** of the upload link and **recorders** of replica jobs; the
  parent is the link **owner** and **runner** of replica jobs (`Domain.start_resumed` only in
  the parent).
- One-shot CLI commands are separate processes, also lessees, which run and drain their own
  deferred work (`resume=false`).

### 2.2 Runtime paths (`lib/local/runtime`, selected at build time per OS)

| | Linux | macOS |
|---|---|---|
| config | `$XDG_CONFIG_HOME/tsync/config.json` (default `~/.config/...`) | `~/Library/Group Containers/group.org.feverdreamtv.tsync/config.json` |
| data_dir | `$XDG_DATA_HOME/tsync` (`~/.local/share/tsync`) | `<group container>/tsync` |
| cache_root | `$XDG_CACHE_HOME/tsync` (`~/.cache/tsync`) | `<data_dir>/cache` |
| domain socket | `<data_dir>/tsync-<domain>.sock` (per domain: each FUSE domain is its own process) | `<data_dir>/tsync.sock` (same for every domain; routed by `domain`) |
| proxy socket | `<data_dir>/tsync-http-proxy.sock` | same |
| sync socket | `<data_dir>/tsync-sync.sock` | same |
| default domain | `<data_dir>/default-domain` (one line, the name) | same |
| resync generation | `<data_dir>/resync-<domain>` (decimal ms timestamp) | same |
| restart | `systemctl --user restart tsync` | `pkill -f <app>`; `launchctl kickstart -k gui/$UID/org.feverdreamtv.tsync.daemon`; `open -a /Applications/TsyncApp.app` |
| log reader | `journalctl -t tsync -n N [-f]` | `tail -n N [-f] ~/Library/Logs/tsync-daemon.log` |

Socket directories are created `0700` by the server before binding.

Service units (`linux/tsync.service` user unit, `linux/tsync@.service` system instance for
packages): `ExecStart=tsync start`, `ExecStop=tsync stop`, `Restart=on-failure`, `RestartSec=5`,
`TimeoutStopSec=30`, `LimitNOFILE=65536`. The system instance must **not** use
`ProtectHome`/`PrivateTmp`/`PrivateMounts` (private mount namespace hides the FUSE mount).
macOS: LaunchAgent plist `org.feverdreamtv.tsync.daemon`, `RunAtLoad`, `KeepAlive
{SuccessfulExit=false}` (restart on crash, respect clean exit 0), stdout/stderr to
`~/Library/Logs/tsync-daemon.log`; installer removes a stale `tsync.sock` first.

### 2.3 Wire protocol (all sockets)

- Transport: `AF_UNIX`, `SOCK_STREAM`. Framing: **one JSON object per line** (`\n`-terminated),
  request then reply, strictly alternating on a connection. A connection carries any number of
  requests until the client closes it (the File Provider asks constantly; one connect per
  question buys nothing). A connection may be converted into an **event stream** by `subscribe`.
- TCP_NODELAY is never set on these sockets (`~set_tcp_nodelay:false` on both server and
  client): macOS answers `EINVAL` on setsockopt for a peer that already hung up, which killed the
  accept loop (d8f854af; memory note lwt-unix-server-nodelay-einval).
- Request envelope: `{"action": "<verb>", "domain"?: "<name>", "ref"?: "<item ref>", "arg"?: "<string>", ...action fields}`.
  `domain` omitted addresses a daemon serving exactly one domain.
- Reply envelope, success: `{"ok": true, ...fields}`. Failure:
  `{"ok": false, "code": "<code>", "error": "<prose>"}`. Clients act on `code`, never on prose.
  (The File Provider router's own routing errors omit `code` — see §9.)

Error codes (`Ipc_error`), and exception → code mapping (`Ipc_error.of_exn`):

| code | from |
|---|---|
| `not_found` | `ENOENT`; `Share_not_found`; `Failure "no versions for..."`; unresolvable ref |
| `exists` | `EEXIST` |
| `not_empty` | `ENOTEMPTY` |
| `read_only` | `EROFS`; `Backend.Not_writable`; mutating action on a `readOnly` domain |
| `unreachable` | `Backend.Backend_error`; any timeout; `Share_unavailable` |
| `denied` | `EPERM`, `EACCES` |
| `invalid` | `Invalid_argument`; bad JSON; missing/invalid fields; unknown action |
| `internal` | everything else (retried by callers: one unexplained failure costs one op, not the domain) |

`unreachable` tells the caller "the store is the problem, stop trying"; the macOS side maps
codes to File Provider errors, some of which make the system back off until signalled, so the
mapping must be conservative.

### 2.4 Item references (wire names for items)

`Item_ref` (defined in core, used heavily here). Wire forms:

- `root`
- `d:<folder id>` — a directory, by its stable folder id (survives renames).
- `f:<parent folder id>/<leaf>` — a file, by its parent's id and its own name. The root's folder
  id is `.tsync-root`, e.g. `f:.tsync-root/a.txt`.
- anything else parses to `Bad` (a storage key included — a key carries no kind).

Resolution to a logical key happens **only** in `Ipc_handler` (and `Location.item` on the CLI
side); it mints nothing (a read that minted would persist a marker and resurrect a deleted
folder). Unresolvable → `not_found`. A `f:` ref must not answer for a folder (`expect` kind).

### 2.5 Item row (the one shape of listing/stat/change rows)

`Item_row.fields`, in this order:

```json
{"ref":"f:.tsync-root/a.txt","parentRef":"root","name":"a.txt","kind":"file",
 "size":5,"mtime":1727600000.0,"etag":"650e58ac64da6e0a","isUploaded":true,
 "symlinkTarget"?: "...", "trashed"?: true,
 "availability"?: "online-only"|"cached"|"pinned", "pinnedUntil"?: <epoch float>}
```

- `kind`: `dir | file | symlink`.
- `etag`: content hash (`h1`) of the published manifest; `""` for a file with unsynced edits;
  for a directory, its own folder id (constant for the folder's lifetime; `mtime` 0, `size` 0),
  so watchers are not told a directory changed on every look.
- `trashed` only when set; `availability` only for files; `pinnedUntil` only when pinned.
- Root row: `ref:"root"`, `parentRef:"root"`, `name:<domain name>`, `etag:".tsync-root"`.

### 2.6 Paging cursors

- `list_dir`: entries of one folder sorted by name (`compare` on bytes, files and folders
  interleaved), `limit` default **1000**. Cursor = the **last served name** (`"next":"mid"`);
  resume filters `name > after`. Stateless: a fresh process answers the same page; insertions
  before the cursor shift nothing.
- `list_all`: whole-domain walk sorted by path, `limit` default 1000. Cursor
  `"<walk>:<n>"` where `<walk>` = decimal ms timestamp of the walk, `<n>` = 0-based line index of
  the last entry served. The walk is persisted between pages at
  `<cache_root>/<scratch dir for domain>/.tsync-list-all`: line 1 header
  `{"walk":"<ms>","skipped":<n>}`, then one JSON line per entry
  `{"path":"a/b.txt","container":"<folder id>","kind":"file","size":5,"mtime":1.0}` or
  `{"path":"a","container":"<id>","kind":"dir"}`. Written atomically, best-effort; never
  invalidated by changes (the change feed carries what moved after the anchor). Missing file
  (a resync empties scratch) → re-walk and continue at the same line number (logs a warning if
  walk ids differ). A cursor whose prefix before `:` is not all digits (old `<container>/<name>`
  form) restarts the listing. Line numbers are used instead of `container/name` because one
  folder id can sit at several mirror paths and a name cursor could loop forever.
- Both: fetch `limit+1` to decide whether to emit `next`. Items the client cannot name (under a
  folder with no known id) are omitted and **counted** in `"unnamed": N` (plus a warning
  suggesting `tsync sync --full`); for `list_all` an unnameable folder's subtree counts once more.

### 2.7 Change feed anchors

`changes_since` / `cursor` anchors: `"<generation>|<journal entry key>"`, entry key `""` for a
caller that has never synced. `<generation>` is the content of `<data_dir>/resync-<domain>`
(trimmed; `""` if absent), stamped with the current ms time by `full_resync`. An anchor issued
under another generation → `{"ok":true,"stale":true}` (the reader re-lists). Answers come from
the locally kept **applied** entries (`Applied_entries`), never from the store, and are not
filtered by author (a CLI change must reach the mount; the client uuid is per machine).

### 2.8 Status report JSON (what `tsync status --json` prints)

Per-process self description (`Diagnostics.self_json`):

```
server:  {hostname, pid, startedAt, uptimeSeconds, loadAvg?, frontend, serves:[domains], ...extra}
process: {cpuSeconds, cpuPercent, cpuPercentAvg, rssBytes, privateBytes, swappedBytes,
          heapBytes, topHeapBytes, minorCollections, majorCollections}
backend: {<counter>: int ...}      pools: [{name,inFlight,waiting,max}]
uplinks: {<link>: governor figures} lwt: {readableFds, writableFds, timers, poolSize}
traffic: {...}                      recentErrors: [{t, level, message}]  (last 50 warn/err)
```

`cpuPercent` is over the interval since the previous report (reports <1 s apart reuse the last
figure; first report = lifetime average).

Per-domain body (`Diagnostics.Make.domain_json`): resolved config (`name, clientName,
versioning, symlinks, domainReadOnly, chunkSize, cacheChunkSize, maxCache, maxUploads,
maxChunkBuffers, maxDownloads, uplinks, cacheRoot, dataDir, socketPath, domainPrefix,
chunkPrefix`), `mainOffline?`, `cache {chunks, bytes, pinnedBytes, maxCache, manifests?}`,
`wal {pending, intent, prepared, executed, stuck, lastError}`, `frontends [...]`,
`backends [{name, type, role, link?, config, reachable, latencyMs, error, journal{entries,
behind, cursor, lastSync}|{counting}|{error}, corrupted{checked, chunks?, truncated?},
disk?{availableBytes,totalBytes}, <link json>, <health json>, totals?}]`.

Machine report (`Status_report.of_answers`): `{host, domains:[...], processes:[...], jobs:[...],
warnings:[{level, message, count, firstAt, lastAt, sources:[{frontend,pid,count}]}]}`. With
`--json` the CLI prepends `"t": <now>`.

### 2.9 Job report (one-shot → daemon, every 10 s)

```json
{"action":"report","kind":"import","domain":"Files","pid":979109,"startedAt":...,
 "uptimeSeconds":...,"intervalSeconds":10.0,"state":"running"|"done"|"failed","error"?:"...",
 "memory":{rssBytes,privateBytes,swappedBytes,virtBytes,systemUsedBytes,systemTotalBytes},
 "gc":{heapBytes,topHeapBytes,minorCollections,majorCollections,liveBytes?},
 "traffic":{...},"backend":{...},"pools":[...],"uplinks":{...},
 "counters":{"files":2499,"planned":6000,...},"target"?:"/media/stage","current"?:"...",
 "backends"?:[{name, ...link json}], ...Job_progress fields}
```

`liveBytes` is sampled every 6th tick (it costs a GC walk). `kind` values used:
`sync`, `sync --full`, `mirror`, `mirror --manifests`, `mirror --path`, `import`, `export`,
`rsync`, `gc`, `gc --abort`, `data-integrity`, `data-integrity --verify`,
`data-integrity --repair`.

### 2.10 Change notice (parent → frontends)

`{"action":"changed","domain":"<name>","keys":["<logical key string>", ...]}` sent to every
socket a domain's frontends answer on. Batched: a per-domain set of pending keys, flushed
**0.2 s** after the first pending key, in chunks of at most **512** keys; flush loops until the
set is empty. Failure is logged once per domain (warn) and otherwise ignored.

### 2.11 Other constants

| constant | value | where |
|---|---|---|
| `Shutdown.grace` | 10 s | stop budget |
| drain inner race | 0.8 × grace | queues give way before cursor flush |
| reaper deadline | grace + 2 s, poll 50 ms, then SIGKILL | `Frontend.reap` |
| `Ipc.Make.send` default timeout | 2 s | async client |
| rescan / uplink lease send timeout | 1 s | |
| rescan debounce | 0.5 s | `Launcher.ask_rescan` |
| `Status_report.cold_timeout` | `Health.probe_timeout` (10) + `listing_grace` (2) + 5 = 17 s | |
| `Diagnostics.listing_grace` | 2 s | wait on in-flight listing after probe |
| store state window | 5 s | cached probe/journal/corruption |
| listing timeout | 30 s | journal / corruption listings |
| corrupted sample | 1000 (+1 to detect truncation) | |
| sampled shards | 16 of `Chunk_layout.shards` | chunk count estimate |
| `Job_registry` stale | max(45 s, 4 × interval); finished kept 300 s | |
| `Subs.max_queued` | 256 per subscriber, drop oldest | |
| blocking pool | `min 256 (max 32 (8 × Σ(maxUploads+maxDownloads)))` | per process |
| fd soft limit target | 8192 (never lowered) | `tsync start` |
| housekeeping interval | 60 s | maintenance |
| default page / changes limit | 1000 / 512 | |
| share link lifetime (IPC `share`) | 7 days | |
| `Log.recent` | 50 warn/err | |
| status `--watch` | redraw every N s, clear screen with `ESC[2J ESC[H` (not in `--json`) | |

---

## 3. Interface

### 3.1 The frontend seam (a plugin interface with several implementations)

A **frontend** is one way of presenting a domain to a user. It is registered by name at build
time (the binary's set of frontends is decided by what is linked in) and describes itself with:

| property | values | meaning |
|---|---|---|
| `availability(locality, key)` | `online-only` \| `cached` \| `pinned(until)` | where a file's bytes are, for `tsync ls` and item rows |
| `serving` | `Daemon{topology, listens, start}` \| `Commands(refusal text)` | whether the launcher runs it; `Commands` frontends are driven by `tsync <group> <verb>` or by an app that embeds the core, and the text is what a refusal says |
| `topology` | `one-process` \| `process-per-binding` | how many processes the launcher forks for it (per binding = its serving call blocks per domain, as a FUSE mount does) — *declared*, the launcher enacts it |
| `listens` | none \| `domain-socket` \| `proxy-socket` | which socket it answers requests on |
| `start(served list)` | blocks until shutdown | serve the given bindings |
| `tree` | `replicated` \| `pulled(refusal text)` | whether it keeps the manifest tree complete locally; a pulled tree has nothing for a full resync to rebuild, so `tsync sync` refuses |
| `spec` | field specs | what the config wizard asks for |
| `cli_group`, `commands[{verb, doc, run(domain conf, raw args)}]` | | CLI verbs the frontend contributes; the binary resolves `--domain`, checks the frontend is configured for it, and passes positional args uninterpreted |

A **binding** = (domain configuration, the frontend's option map from config, mount point
(fuse only)). A **served** item = binding + the per-domain engine the launcher built for it
(§3.2 *presenting* engine) + `peers`: sockets of the domain's *other* frontends (only the
http-proxy uses it, so its own status page is complete).

| frontend | serving | topology | listens | tree |
|---|---|---|---|---|
| fuse | Daemon | process-per-binding | domain-socket | replicated |
| http-proxy | Daemon | one-process | proxy-socket | replicated |
| file-provider (macOS) | Daemon | one-process | domain-socket (one path for all domains) | replicated |
| android | Commands | — | — | pulled |

Process primitives the launcher offers frontends:

- `use_event_loop_backend()` — select a readiness backend that has no descriptor-number ceiling
  (never `select(2)`: above FD_SETSIZE=1024 one high descriptor takes the loop down).
- `cap_blocking_pool(concurrency)` — size the per-process blocking-I/O worker pool to
  `min(256, max(32, 8 × concurrency))`, `concurrency = Σ over served bindings of (maxUploads +
  maxDownloads)` (summed: the pool is per process, the budgets per domain). Must be called in the
  leaf, after all forking.
- `fork_each(f, items) -> reaper`: fork one child per item, in list order; the child resets its
  diagnostics start time, runs `f(item)`, exits 0. Registers a stop hook that SIGTERMs all
  children the moment this process is asked to stop. `reaper()` = §4.2 reap, then unregister the
  hook.
- `run_forked(f, items)`: `fork_each` all but the last item, run the last in this process, reap
  when it returns (so a failure of the in-process one does not orphan the forked siblings).

### 3.2 Domain engine — what a process gets per domain

Two roles over the same per-domain machinery:

**Presenting engine** (every process that serves a domain to a user):

| operation | contract |
|---|---|
| `file_ops` | the file operations over the domain (checkout, content, staging) |
| `handler(hooks, line) -> (reply line, control)` | the request handler of §3.6 over `file_ops` |
| `start(on_upload_done?)` | ensure manifest root; start **this process's** upload queue (each completion runs `on_upload_done` then the after-upload maintenance tasks) and metadata queue |
| `drain()` | §4.2 domain drain |
| `stats_fields()` | `pendingUploads, uploadsCompleted, pendingMetadata, metadataDegraded, unappliedEntries, unappliedReason, maintenance[]` |

**Converging engine** (exactly one per domain per machine):

| operation | contract |
|---|---|
| `start(on_changed: key -> ())` | `start_queue` + start the sync poller (held while paused) whose applied keys are reported to `on_changed` + start periodic maintenance |
| `drain()`, `stats_fields()` | as above |

Building blocks, layered:

- `init` — ensure the manifest root exists (all a read-only command needs).
- `start` — init + upload queue + metadata queue.
- `start_queue` — start + **reconcile** (recovery replays through the queue, so the queue must be
  running first). What a lone one-shot command or an embedded host owes.
- `converge` — start_queue + poller + periodic maintenance.
- `run_maintenance` — one driver for the declared task list (§4.5).

The checkout implementation is a parameter: the replicated checkout (daemon, CLI) or the lazy
one that reads a folder when asked (Android).

Process-level helpers:

- `drain_for_stop(drains)` — run all drains concurrently; return when all finish or after
  `grace`, whichever first; never cancel the unfinished ones.
- `host_loop(serve, main_thread?, after?)` — run the event loop; `serve` receives `ready()`. With
  `main_thread`, the loop runs on a second thread and the caller's thread waits for `ready`, then
  runs `main_thread()` (a platform loop that must own the main thread, e.g. libfuse), then joins.
  `after` runs on the loop thread after a clean finish. `serve` finishing without calling `ready`
  still releases the waiter.
- `host_loop_detached(serve)` — the loop on its own thread for a host whose main thread belongs
  to a platform (Android); returns once `ready` is called; never joined.
- `on_loop(f)` — from a platform thread, run `f` on the loop and block only the calling thread
  until its result; errors are re-raised on the calling thread carrying the original trace.
- Loop death: if the event loop itself fails (not a task — the dispatcher), log with trace, flush,
  and terminate the process immediately **without** running exit handlers (they would try to
  drain through the dead loop and hang). Seen in production: 47 minutes of silence after a TLS
  read raised inside the dispatcher, outside any task.

### 3.3 IPC transport

Blocking client (one-shot commands): `send(socket, line) -> line` (no timeout);
`request(socket, fields) -> fields` (raises the daemon's `error` text on `ok:false`);
`action(socket, verb, ref?, arg?, fields?, domain?)` — optional fields omitted rather than sent
empty.

Non-blocking client (inside a daemon): `send_async(socket, line, timeout = 2 s) -> line`; timeout
is distinguishable from other failures.

Server `serve(path, handler, until?, subs?)`:

- `mkdir -p` the parent with mode `0700`; unlink a stale socket; listen.
- One concurrent task per connection; a connection carries many requests until the client
  closes it.
- Per line: `handler(line) -> (reply, control)`; write reply + newline, flush; then
  `continue` → next line; `stop` → trigger the server stop (idempotent across clients) and end the
  connection; `subscribe(topic)` → the connection becomes an event stream (§ below), or is closed
  if the server has no subscriber registry.
- `until` completing also triggers the stop. On stop: close the listener, **then** unlink the
  socket path — exactly once, here. Nobody else removes the socket.
- Handler failure or client EOF ends only that connection.

Subscriber registry: `publish(topic, msg) -> delivered count` (a subscriber registered under
`""` hears every topic; 0 = nobody listening, not an error); per subscriber a FIFO of at most 256
messages, overflow drops the oldest (events are hints on top of the journal: loss costs
promptness, not correctness). A subscription ends when the client goes away (read side hits EOF
and wakes the writer) or a write fails; either side ends by itself, not by cancelling the other;
unregistered on exit. Event lines are only ever written on a subscribed connection, so events and
replies never interleave.

Transport requirement: never set TCP_NODELAY on these sockets (see the [OCaml notes](ocaml/07-daemon-cli.md)).

### 3.4 Process stop signal

A process-wide, one-way flag with hooks:

- `request()` — idempotent; the first call sets the flag and runs every registered hook once, in
  registration order.
- `requested() -> bool`.
- `on_request(f) -> unregister` — runs `f` immediately if already requested.
- `grace` — seconds a stop may take (10; settable for tests).
- `interruptible_sleep(s) -> slept | stopping` — returns `stopping` at once if already requested
  or as soon as it is.
- Error `Stopping` ("left for the next start"): what backoffs, retry ladders, queue workers and
  uplink waits fail with. Consumers must treat it as *owed, untouched on disk*: never retried in
  this process, never counted as a failure, never taken to mean "no longer owed" (distinct from a
  cancellation that completes a record).

### 3.5 Advisory side channels

All four never fail their caller, log each kind of failure at most once, and are pure hints on top
of durable state.

- **Change notice** `send(domain, sockets, key)`: add key to the domain's pending set; if no
  flush is scheduled, schedule one 0.2 s later; flush takes the whole set, sends it in chunks of
  ≤512 keys (`changed` action, §2.10) to every socket concurrently, and repeats while keys keep
  arriving. `settle()`: flush every domain's pending set now (for a process about to exit).
  Domain with no sockets: ignored.
- **Job report** `start(socket, domain, kind, target?, interval = 10 s, current?, backends?,
  counters)`: every interval (sequential — a slow send delays the next), send `report` state
  `running`; `finish(error?)`: stop the loop and send a last report `done`/`failed`; second call
  no-op.
- **Rescan request** (frontend processes): after recording a replica/backfill job it does not run,
  send at most one `rescan` to the sync socket per 0.5 s window (1 s timeout).
- **Uplink lease** (every non-owner process): periodic `uplink` renewal to the sync socket
  (1 s timeout); an unanswered/refused renewal means the process governs its own link. Protocol
  owned by the uplink spec; the sync socket answers it (§3.6).

### 3.6 Actions per socket

**Domain socket** (fuse per domain; file-provider shared; served by `Ipc_handler.Make(C)(F)(Sq)(Pause)` with frontend `hooks`):

| action | request fields | reply fields | notes |
|---|---|---|---|
| `stat` | `ref` or `rel` | item row fields | `rel` (path, `""`=root) for callers holding only a path (desktop menus); kind from mirror |
| `list_dir` | `ref`/`rel`, `limit?`, `after?` | `items`, `next?`, `unnamed?` | §2.6 |
| `list_all` | `limit?`, `after?` | same | §2.6 |
| `changes_since` | `arg`=anchor, `limit?` (512) | `stale`, `cursor`, `more`, `ops`, `unnamed?` | §2.7, §4.4 |
| `cursor` | — | `cursor` | current anchor |
| `ensure_cached` | target, `dest` | `localPath` | assemble whole file to `dest` |
| `fetch_range` | target, `dest`, `offset`≥0, `length`>0 | `localPath, offset, length` (served, short at EOF) | |
| `create` | `parentRef`, `name` | `item?` | mutating |
| `write` | `parentRef`, `name`, `staging` (path), `await?` | `size?, mtime?, item?` | adopts staging file in place; cancels an in-flight upload of the key first; `await:true` waits for upload |
| `delete` | target | — | mutating |
| `rename` | `ref` (src), `parentRef`, `name` | `item?` (dest) | keeps kind; folder id travels |
| `mkdir` | `parentRef`, `name` | `item?` | |
| `symlink` | `parentRef`, `name`, `target` | `item?` | |
| `rmdir` | target | — | |
| `revert` | target, `arg`=version ts (`""`=latest) | — | then `hooks.changed key` |
| `share` | target | `url` | 7-day link |
| `evict` | target | — | `hooks.evict` (fuse: whole subtree) |
| `restore` | target, `keep?` seconds | — | `hooks.restore` (fetch + pin) |
| `full_resync` | — | — | stamps new generation, then `hooks.full_resync` |
| `status` | — | `domain, running:true, readOnly, paused, pendingUploads, pendingDownloads, uploading:[{name,rel,body?,size?}], downloading:[{name,rel,bytes,size,seconds,rate}], pendingBytes, <process traffic fields>, <hooks.status_fields>` | cheap: no store access (menu poll) |
| `pause` | `arg`: `"off"` → resume, anything else → hold | — | |
| `stats` | `arg` = comma set of `totals`,`exact`,`reload`,`frontend` | self_json + `domains:[domain body with frontends:[queues]]` | `frontend` → only this frontend's figures, no cache walk / WAL / probes |
| `download_progress` | target | `active`, `bytesDownloaded?`, `totalBytes?` | |
| `changed` | `keys:[logical key strings]` | — | from the parent; `hooks.changed` per key; unknown keys warned |
| `stop` | — | — | `hooks.on_stop`; control `Stop` |
| `subscribe` | `domain` (required) | — | control `Subscribe <routed domain>` |

"target" = `ref` or `rel`. Mutating set: `create, write, delete, rename, mkdir, rmdir, symlink,
revert` (share excluded: share manifests live outside domain roots). Action strings are a wire
contract with `macos/TsyncFileProvider/IPC.swift`.

Frontend `hooks` record: `evict`, `restore ?keep`, `changed`, `full_resync`, `status_fields`,
`stats_fields` (must include `"frontend": <type>`; normalised to `"type"`), `on_stop`.

**File-provider router extras** (same socket, macOS): `menu` → `{"ok":true,"menu":<Menu.to_json>}`
(built by calling every domain handler's `status`); `menu_stats` → `{"ok":true,"rows":[...]}`
(every domain's `stats`). Other actions route by `domain`; missing `domain` with exactly one
domain served → that one; otherwise error "cannot tell which domain '<action>' is for".

**Sync socket** (parent, `Launcher.handler`):

| action | behaviour |
|---|---|
| `stats` | `arg` flags `totals`/`exact`/`reload` (`exact` implies totals; `reload` only with totals). Returns the finished machine report (`processes` present) with `ok:true` |
| `report` | job report → `Job_registry.record`; always `ok:true` |
| `rescan` | start a background rescan of every durable deferred queue's on-disk records; `ok:true` at once |
| `uplink` | lessee lease renewal (`pid`, `links:{name: report}` or flat legacy shape) → `{ok, interval, links:{name:{rate, limit?}}, rate?}`; `invalid "not the links' owner"` if this process isn't |
| `stop` | `request_stop()` then `ok:true`, control `Continue` (listener closes after the drain, via `until`) |
| other | `invalid "unknown action: ..."` |

**Proxy socket**: http-proxy's own handler (other spec); speaks the same envelope, answers
`stats` and `stop`.

### 3.7 CLI surface (`tsync <cmd>`)

Global conventions: `--domain NAME` (with shell completion from config) else the default-domain
file else the sole domain; `-v/--verbose` sets log level `info` (default `warn`) — progress goes
through `Log`, command results to stdout via printf; exit codes: 0 success; 1 for user-facing
`Failure`/`Retry.Failed` (printed `tsync: <msg>`) and command-specific failures; 2 for
`sync` on a `Pulled` frontend; 125 (internal error) for anything unexpected, with a stack trace. Commands that compute an exit code call `exit` **after** `Oneshot.run` returns (exiting
inside the promise skips the drain).

Path arguments (`Location`): `DOMAIN:/path` or `DOMAIN:path` names a domain outright iff
`DOMAIN` is a configured domain name (else it's a local path with a colon). Readings:
`` `In_domain `` (relative token = domain-relative in the target domain, wherever run from) vs
`` `Either `` (relative token = local path). Absolute/`Either` paths resolve by lying under a
domain root (`Conf_parsing.roots_of`), else — for `Location.item` — by asking the running
daemon's `stats` for its `mountPoint` (covers `tsync start --mount`). `Location.item` resolves a
path to `(domain, Item_ref)` locally via folder markers (`Folder_ids_lwt.ref_of_key`); error
"this client has not resolved its folder" if none.

| command | talks to | semantics |
|---|---|---|
| `start [--mount P] [--tls native\|openssl]` | — | Run the service (§4.1). `--mount` only when exactly one domain. |
| `stop` | every socket from `Daemons.all` (+sync) | send `stop`; ECONNREFUSED/ENOENT = not running; prints `Stopped N domain(s).` or "No IPC-backed frontend running; relying on signal." |
| `restart` | service manager | `Runtime.restart_service`; exit 1 if not installed |
| `status [--json] [--totals [--exact] [--reload]] [-w S]` | sync socket, fallback every frontend socket | §4.6 |
| `logs [-f] [-n N=200]` | exec log reader | `execvp`; ENOENT → explain need for journald |
| `pause` / `resume` (aliases `pause-uploads` / `resume-uploads`) | domain socket | `pause` with `arg` on/off |
| `ls [PATH] [--deleted] [--frontend F]` | local mirror | children sorted case-insensitively; `dir    name/` or `<availability>  name  N bytes` (`pinned until <ts>`); `--deleted` appends `deleted  name` |
| `cache --evict\|--fetch [--keep DUR] PATH...` | domain socket (`evict` / `restore`) | per-path error lines, exit 1 if any failed; `--keep` default 10d (daemon side) |
| `cache --prune [--grace DUR=1h]` | local | runs every declared on-demand maintenance task; prints per task files/bytes |
| `versions [PATH]` / `--revert [--version TS]` | local+store / domain socket `revert` | list versions `ts  human  size` newest first, or all deleted files |
| `trash` / `--restore PATH` / `--purge PATH` | local+store | restore exit 1 on `Parent_unknown`; purge exit 1 on `Live_elsewhere`/`Not_in_trash` |
| `expire DATE` | store | cutoff `YYYY-MM-DD` local midnight; prints removed versions/journal entries |
| `gc [--budget] [--pause] [--concurrency] [--delete-batch] [--abort] [--status] [--retry-jobs] [--verify]` | store | resumable collection (gc spec) |
| `sync [--full] [--source NAME] [-j N=32]` | store | refuses (exit 2) if any configured frontend is `Pulled`; prints `N journal entries from other clients` or `full resync: N manifests downloaded (K failed …)`, exit 1 if failed>0 |
| `data-integrity [--verify\|--repair] [--detail] [--source] [--dry-run]` | store | exit 1 if unhealthy |
| `mirror [--source] [--manifests\|--path P]` | stores | needs ≥2 members |
| `import DIR [--only G] [--exclude G] [--force-rehash]` | store | exit 1 if any failed |
| `export [PATH...] DIR [--source] [-j N]` | store | one domain per run; exit 1 on failures or pending local changes (listed on stderr) |
| `rsync SRC DST [--move] [-n]` | store | refuses local→local and cross-domain |
| `share [PATH] [--expires 7d] [--token HEX] \| --clear-cache` | store | URL on stdout, expiry on stderr |
| `config [--edit]` | file | print parsed config with secrets masked, or run wizard |
| `default-domain [NAME] [--clear]` | file | set (must be configured) / clear / print (exit 1 if unset) |
| `build-info` | — | frontends, s3 enabled, log impl, paths, sockets |
| `<cli_group> <verb> [ARGS...]` | frontend | frontend-contributed (`fileprovider reimport\|reset\|purge`; `android stat\|list\|read\|open\|residency\|fetch\|write-whole\|create\|mkdir\|delete\|rmdir\|rename\|share\|request\|status`); binary checks the frontend is configured for the domain, passes raw positional args |

Durations (`parse_duration`): `<N>d|h|m|s`, N > 0, else a user-facing error.

### 3.8 Composition per host

The same core (config → domain conf, checkout, content, queues, poller, request handler,
diagnostics) is instantiated by seven hosts. What differs is which engine role each builds, which
domain config flags it passes, who owns the shared per-machine roles, and its lifecycle.

Per-machine roles that must have exactly one holder at a time:

- **converger** of a domain (reconcile, poller, periodic sweeps: they write the mirror, the
  applied-through bookmark and the staged tree, which no one arbitrates);
- **resumer** of deferred replica/backfill work (built with `resume = true`; starts queues left
  owed by previous runs);
- **link owner** (uplink governor that grants shares to lessees).

| host | engine role per domain | resume | link | checkout | loop hosting | stop |
|---|---|---|---|---|---|---|
| **daemon parent** (`tsync start`, "sync") | converging, all domains | **true** (the only one) | **owner** | replicated | `host_loop`, main thread | signals / sync-socket `stop`; drain all; reap children |
| **fuse child** (one per fuse domain) | presenting | false | lessee | replicated | `host_loop` with FUSE on the main thread | SIGTERM (from parent) / domain-socket `stop`; unmount ∥ drain |
| **http-proxy child** (server for other tsync clients; all its domains) | presenting | false | lessee | replicated | `host_loop` | SIGTERM / proxy-socket `stop`; drain |
| **file-provider child** (macOS; all domains, one socket) | presenting | false | lessee | replicated | `host_loop` | domain-socket `stop`; drain (see §9) |
| **one-shot command** (`tsync import` etc.) | `init` or `start_queue` as the command needs; never the poller | false (records *and drains its own* deferred work) | lessee | replicated | one loop per command, then drain | returns |
| **embedded app** (Android, core linked into the app process) | `start_queue` + periodic maintenance, **no poller** (pulled tree: folders read on demand) | false | none (no daemon) | lazy | `host_loop_detached`; requests via `on_loop` | process death; state is on disk, next start reconciles |
| **android CLI** (`tsync android <verb>`, for shells/tests) | per command: `start_queue` if the request mutates, else `init`; then drain | false | lessee | lazy | one loop per command | returns |

Per-host wiring differences:

- Frontend processes install: uplink lessee → sync socket; "on recorded" → rescan request to the
  sync socket; their own `hooks` into the request handler (§3.6): fuse evicts/restores whole
  subtrees and invalidates its view on `changed`; the embedded app's hooks are no-ops except
  evict/restore of a single key; file-provider signals the system extension via subscribers.
- The daemon parent wires `on_changed` of each converging engine to a change notice towards that
  domain's frontend sockets; it is the only process that sends `changed`.
- The embedded app and one-shot commands have no socket of their own; the embedded app answers
  requests through a direct function call carrying the same JSON request/reply lines (same
  handler, same error vocabulary as the File Provider).
- A host whose OS forbids long-lived background processes (Android: a foreground service is
  stopped after ~6 h/day) must be correct with no drain at all: every operation's state is on
  disk and reconcile at the next start publishes what it finds.

Start order inside the daemon parent (order matters):

1. load config; raise the fd soft limit (before forking, so children inherit it);
2. refuse any `Commands` frontend (before the first fork, while there are no siblings to orphan);
3. fork one process per frontend group (config order of first appearance); in each child:
   diagnostics clock reset, lessee + rescan wiring, event-loop backend + pool sizing, then
   `start(served)` (which may fork per binding);
4. in the parent: install stop handling and a background-error logger → become link owner →
   start resumed deferred queues → start each domain's converging engine **sequentially** →
   serve the sync socket (fatal if it fails) → `ready`.

Frontend children never run convergence; the parent never presents.

## 4. Behaviour / algorithms

### 4.1 `tsync start`

1. Initialise daemon logging (syslog at debug, §4.9).
2. No config file → message to stderr, **exit 0** (the installer starts the service before
   configuration; 0 keeps launchd/systemd from respawning). No domains → same, exit 0.
3. `--tls` overrides the config's TLS backend choice (picked once per process).
4. For each domain: socket = domain socket path; conf built with `resume = true`; mount point =
   `--mount` if exactly one domain, else the configured one (default `~/tsync/<DOMAIN>`).
5. Raise fd soft limit toward 8192 before forking.
6. **Create no event-loop resources before the forks** (a child inheriting the loop's
   wake-up descriptor gets its worker completions delivered to the parent); fork with a primitive
   that re-initialises them in the child.
7. Launch groups as in §3.8; each child also opens a per-process memory trace when `MEMTRACE`
   names a directory.
8. Parent: converge (below) with the reaper guaranteed to run on the way out.

Parent converge sequence:
1. Per domain: converging engine + diagnostics; frontend sockets = (frontend name, socket)
   deduplicated by socket.
2. SIGTERM/SIGINT → `request_stop` = stop signal `request()` + resolve the local `stop` event
   (once).
3. Background-task errors are logged, never fatal.
4. Become link owner (before engines, which may send at once).
5. Start resumed replica/backfill queues.
6. Start each converging engine sequentially with `on_changed = change notice to its frontends`.
7. Serve the sync socket with `until = drained`; if serving fails → log and **exit 2** (without
   the socket no lease and no stop are heard; a supervisor restart is better than running
   unreachable — c3c4a983).
8. `ready`; wait for `stop`; `drain_for_stop(every domain's drain)`; resolve `drained` (the
   listener closes and unlinks only now, so status stays answerable during the drain).
9. Reap children.

### 4.2 Stop

Triggers: `tsync stop` (IPC `stop` to each socket), SIGTERM/SIGINT (systemd `ExecStop`/kill), a
FUSE mount unmounted externally.

Parent on stop:
- `request()` runs hooks, including the fork hook: SIGTERM every direct child **immediately**,
  not after the parent's own drain (a child that forked in turn then stops alongside its children
  within one grace; waiting would take two graces and outlast the parent's deadline).
- Backoffs, queue workers and uplink waits give way with `Stopping`.
- `drain_for_stop`: all drains concurrently, raced against `grace` — **raced, not cancelled**
  (cancelling made the metadata queue record the cancellation as a permanent failure and mark
  itself degraded). On timeout: warn "still busy after 10s; what is left is owed on disk and
  resumes at the next start".
- Per-domain drain: metadata queue drain **then** upload queue drain (a published rename is what
  names the file an upload behind it is for); while stopping, that pair is raced against
  `0.8 × grace`; then flush the coalesced cursor bump (so peers hear about uploads that did
  finish), settle change notices, drain backend deferred copies.
- Reaper: SIGTERM all children, poll non-blocking wait every 50 ms until `grace + 2 s`, then
  SIGKILL and wait for stragglers; then unregister the fork hook (a later stop must not signal
  recycled pids).

Frontend processes: fuse maps SIGTERM/SIGINT and IPC `stop` (via `hooks.on_stop`) to its
`request_stop`; its listener closes at once on `stop`; it then unmounts **concurrently** with
`drain_for_stop([its drain])` (the unmount is what releases the FUSE main loop). http-proxy
mirrors the parent (listener closes after the drain). Overall bound: ~10 s drain + 2 s reaper
margin, inside systemd's `TimeoutStopSec=30`.

### 4.3 Event-loop hosting

See `host_loop`, `host_loop_detached`, `on_loop` and loop death in §3.2. Invariant: **all domain
state is touched only on the loop thread**; platform threads (libfuse workers, JVM binder threads)
never touch it directly, they marshal through `on_loop` and block only themselves. `on_loop`
passes an OS error (errno) through untouched (it is an answer, e.g. `getattr` → ENOENT on the
hot path) and wraps anything else with its original trace.

### 4.4 IPC handler internals

- Parse; non-object → `internal "expected JSON object"`; bad JSON → `invalid`.
- Read-only domain and mutating action → `read_only "'<domain>' is read-only"` (enforced here,
  not trusted to the frontend's advertised capabilities).
- **Mutations are serialised** under one mutual-exclusion lock per domain handler, *including* reference
  resolution (b7fd7943): the File Provider sends concurrent requests; resolving `parentRef`
  before the mirror lock let `mv f4 sub/` racing `mv sub sub2` recreate `sub` beside `sub2`, and
  every replica journaled the wrong tree. Reads are not serialised.
- Every handler failure → failure envelope with `code` from the §2.3 mapping and the error's text as `error`.
- Control: `stop` → `Stop`; `subscribe` with non-empty `domain` → `Subscribe C.domain_name`
  (the routed domain is the topic); else `Continue`.

`changes_since` algorithm:
1. Split anchor at first `|` → (issued generation, entry key). Generation mismatch → `stale:true`.
2. Head = latest applied entry key. Anchor == head, or both absent → up to date:
   `{stale:false, cursor:anchor(gen,head), more:false, ops:[]}`.
3. `Applied_entries.since ?since:anchor ~limit` → `None` (anchor pruned) → `stale:true`.
4. Ops of the page's entries, in order; cursor = last entry key of the page (or the anchor if
   none — never told to start over); `more` from the page.
5. Each op described (`op_to_json`) using `removed_folder_id` lookup (answers even after the
   mirror dropped a folder):
   - `put` → `{op:"put", ref, parentRef, name, item}` with `item` read from the mirror via the
     ref's *current* resolution (the folder may have moved since).
   - `mkdir` → `{op:"mkdir", ref:"d:<id>", parentRef, name, item}` (row built from the id).
   - `delete` / `rmdir` → naming only (`rmdir` adds `id`).
   - `rename` → `{op:"rename", is_dir, id?, srcRef, srcParentRef, ref, parentRef, name, item}`;
     dropped unless **both** ends are nameable (a half-reported move loses an item).
   - An op whose self/parent cannot be named is dropped and counted in `unnamed` (re-listing the
     domain for one folder would cost every other).

`list_all` walk: DFS from root, each folder's children via its folder id; folder with no id →
`unnamed+1` and subtree skipped.

### 4.5 Domain maintenance (declared, one driver)

Tasks are data (`Maintenance_lwt.task = {name; triggers; run}`), so "what runs unasked" is a list
and `stats_fields.maintenance` reports it. Per domain (test-pinned list):

```
mirror temp files (on demand); staged orphans (on demand); export records (on demand);
applied journal entries (on demand, every 86400s); chunk cap (after each upload, every 60s);
deferred rescan (every 60s); metadata retry (every 60s)
```

`run_maintenance`: for each task with a `Periodic s` trigger, an async loop `sleep s; run`.
`After_upload` tasks run sequentially after each upload completion. `tsync cache --prune` runs
the `Md.tasks ~staged_grace` list (the on-demand half) directly. Periodic maintenance runs only
in the converging parent (`converge`); presenting processes run `After_upload` tasks.

### 4.6 `tsync status`

1. Resolve targets once (`--watch` must not re-read config): every configured frontend with a
   socket (`Daemons.all`: `Domain_socket` → per-domain path, `Proxy_socket` → proxy path, one
   entry per domain even when shared), plus `("sync", sync socket)`, sort-uniq.
2. Ask the sync socket `stats` (timeout `cold_timeout` 17 s). If the reply has `processes`, it is
   the finished report (drop `ok`).
3. Otherwise (no parent, or an old daemon) fall back: ask every frontend socket in parallel
   (width = config) and fold with `Status_report.of_answers` without local/domains.
4. Print JSON (with `t`) or `Status_report.text`.

Parent `stats` assembly (`Launcher.report`): per engine `Diag.domain_json` in parallel; ask every
frontend `stats` with `arg:"frontend"` (their own figures only, no probes; default 2 s timeout);
fold with `local = self_json + {frontend:"sync", serves:[...]} + jobs`. **Only a collector fans
out**: a frontend asked for its figures asks nobody (else frontends × frontends round trips).

`Status_report.ask` never raises: failures become `{"error": "timed out" | exn}`, rendered as a
frontend entry `{type?, reachable:false, socketPath, error}`.

`frontend_entry`: take the answering daemon's `domains[name == asked].frontends[0]` (fallback to
the first domain) and add `pid`, `uptimeSeconds` (from `server`), `cpuSeconds`, `rssBytes`
(from `process`), `traffic` — unless the frontend already reported that key itself.

`of_answers` fold:
- host = first reply with `server.hostname`.
- domain bodies: collector's own win; then answered bodies deduped by name; then a stub
  `{name, unanswered:true}` for each asked domain nobody answered.
- each domain's `frontends` = body's frontends + gathered entries, merged by identity
  (`type:<t>` or `socket:<path>`), first description wins per field.
- `processes`: one per distinct `server.pid` (flattened server+process+traffic/pools/lwt/backend/
  uplinks, hostname removed), `serves` widened across all replies of that pid.
- `jobs`: concatenated, deduped by pid (jobs without pid are all kept).
- `warnings`: grouped by (level, message), counting per (frontend, pid), first/last times,
  sorted newest `lastAt` first.

Diagnostics cost controls:
- Store probe + journal listing + corruption listing per member are cached for a 5 s window,
  shared by every asker, refreshed **behind** the answer (a redraw never waits on the store). The
  answer waits for the listing at most `listing_grace` (2 s) after the probe; otherwise reports
  `{"counting":true}`.
- A member whose health is *held down* is not probed at all (`reachable:false`, error =
  health description).
- `journal.behind` = listed journal keys newer than the last-sync bookmark and not authored by
  this client uuid; listed whole (a `max_keys` cut would drop exactly the newest entries).
- `totals` (store contents) are never computed while a request waits: a request serves the last
  sample with `sampledSecondsAgo` (+`refreshing` if a walk is running); `compute` starts a walk
  only if none exists or `reload`; one walk per (store, precision) at a time; `exact` and sampled
  are separate slots (the other precision is served as fallback). Sampled chunk count = 16 evenly
  spaced shards × (shards/16); manifests always a full listing; mid-GC adds `chunksPartial`.
- `cache.manifests` (a mirror walk) only with totals.

Text rendering: header `tsync on <host> — N domains, M processes, up X, load L`; then per domain
(settings, concurrency, cache, read-only, unsynced/stuck WAL, `MAIN OFFLINE`), each frontend
(`NOT ANSWERING`, traffic, clients, handles, `metadata lock HELD`, `METADATA PARKED`,
`PEER ENTRIES UNAPPLIED`, in flight/completed/downloading/maintenance), each backend
(`UNREACHABLE`/`HELD DOWN`, journal, corrupted — "not checked" when no verifier, traffic, behind,
disk, holds); then `Processes`, `Jobs`, `Warnings (newest first)` (10 shown). Silent-when-clean:
a row appearing is the signal.

### 4.7 One-shot commands (`Oneshot.run`)

```
open memory trace "<argv[1]>-<pid>" if MEMTRACE names a directory
run event loop until:
  start job report (if the command reports)
  r = command body;  on failure: job report finish(error), re-raise
  drain backend deferred copies the command posted
  settle change notices
  job report finish
  return r
exit code decided by the caller only after the loop returned
```

A one-shot's conf is built with `resume:false` (it records and drains its own deferred work but
must not run jobs the daemon runs) and every `make_conf` registers the process as an uplink
lessee of the sync socket (if nothing answers, it governs its own link). Every command also
fails fast on config errors before any terminal redraw.

`live_output` (progress rewrite on a TTY stderr): `block lines` rewinds with `ESC[<n>A` +
`\r ESC[J` and redraws lines truncated to terminal width (`$COLUMNS`, else `tput cols`, else 80;
cut by code points with `…`); `note` prints a persistent line above; log sink wrapped to clear
the block first. Not a TTY → lines go to `Log.info` (visible with `-v`).

### 4.8 Pause

`tsync pause|resume` → domain socket `pause` → `Pause.set held` on that process's upload and
metadata queues; `Sync_poller` is started with `~paused:Pause.held` (holds applying peers' work).
Reads are never held. `drain` still completes while paused (a paused queue cannot wedge a
shutdown — test `pause`). The flag is in-memory only (lost on restart). See §9 on which process
actually holds the poller.

### 4.9 Logging

- `Log.{debug,info,warn,err}` printf-style; `min_level` default `info` (CLI sets `warn`, `-v`
  `info`, daemon `debug`); optional per-process `prefix` (fuse sets `"[<domain>] "`); sink
  replaceable (Android → logcat); last 50 `warn`/`err` kept with timestamps for `recentErrors`.
- Daemon: `syslog(3)` ident `tsync`, facility `LOG_DAEMON`, `LOG_PID`, plus `LOG_PERROR` only if
  stderr is a TTY (under a service manager stderr is the journal too; echo would duplicate).
  Levels → `LOG_DEBUG/INFO/WARNING/ERR`. Falls back to stderr when the syslog library is absent
  (`build-info` reports which). No log files of its own; `tsync logs` execs the platform reader.

### 4.10 Tray / menu model (`lib/app/ui/menu.ml`)

Pure function from per-domain `status` replies to a menu; the Linux tray links it; macOS gets it
as JSON via the `menu` action. Rules:
- summary: no domains → "No domains configured"; all unreachable → "Daemon not running";
  nothing moving → "Paused" if all paused else "Idle"; otherwise
  "Uploading N · Downloading M · paused".
- per domain detail: "not answering" if counts missing; download count = number of downloading
  rows if any, else the chunk-fetch count.
- icon priority: all unreachable → `tsync-error-symbolic`; all paused → `tsync-paused-symbolic`;
  any transferring → `tsync-sync-symbolic`; else `tsync-idle-symbolic`.
- rows: header only when no domains; per domain a row (action open folder) then up to 5 upload
  rows + "… and N more", download rows (action reveal `{domain, rel}`, file icon by extension,
  generic freedesktop names only); traffic line "X sent · Y to go" (only when non-zero); rate
  line "R/s · 2h 13m left" (`eta`: two largest non-zero of d/h/m, `None` under a minute);
  separator; `Stats` submenu (filled on open via `stats`/`menu_stats`, placeholder "Reading…",
  never empty); "Hold changes" checkbox (checked = all paused; disabled when all unreachable;
  action sets the negation; the checkmark shows the daemon's answer on the next poll); separator;
  quit row (label names the *icon*, e.g. "Quit tsync tray" / "Quit tsync menu bar": the daemon
  keeps running).
- `to_json`: `{icon?, tooltip, entries:[{separator}|{label,enabled,indent,checked?,submenu?,
  action:{openFolder|reveal{domain,rel}|setPaused|stats|quit}}]}`; icon omitted for non-OCaml
  clients.

### 4.11 Config wizard (`tsync config --edit`)

Interactive editor over the raw JSON (preserves unknown per-link fields). Existing file that is
not valid JSON → refuse, exit 1. New file: prompt globals (client name default hostname,
`maxUploads`, `maxChunkBuffers` default = maxUploads, `maxDownloads`, uplink governor enabled /
headroom % (≤100) / target delay ms (≥5) / ceiling (must be ≥ minRate, asked again otherwise),
per-link ceilings for each link some backend uses, TLS backend if ≥2 available, "auto" = unset)
then domain 1. Main loop: select by number, `[a]dd [e]dit [r]emove [g]lobals [w]rite [q]uit`.
Domain: name, versioning (default **true**), symlinks, readOnly, chunkSize, cacheChunkSize,
maxCache (default 1 GiB), backends (type default `local`; s3/gcs offer filling
bucket/keys/shareUrl from `terraform|tofu -chdir=DIR output -json`, outputs `stores`/`gcs_stores`,
secrets from `secret_access_keys`/`gcs_service_account_keys`; remaining fields from the driver's
`Field_spec`; role default `replica` for a cloud store once a `main` exists, else `main`),
frontends (from the registry). Field prompts: blank keeps current; required fields re-asked;
optional with default `""` omitted; secrets read without echo. On write: drop per-link settings
whose link no backend uses (parser would reject), validate with `Conf_parsing.of_json` (refuse and
exit 1 if invalid), write pretty JSON + newline, `chmod 0600`, tell the user to `tsync restart`.

---

## 5. Interactions

Depends on:
- **Config** (`Conf_parsing`, `Domain.of_config`, `Conf_lwt.S`): domain list, frontends,
  backends, roles, defaults; `Domain.target`, `default_domain`, `start_resumed`,
  `set_on_recorded`, `reading_from`, `reading_at_most`.
- **Sync** (`Sync_queue`, `Meta_queue`, `Pause`, `Sync_poller`, `Replay`, `Resync`): queue
  start/drain/pending counts, poller, reconcile, unapplied entries.
- **Checkout / file ops** (`File_ops.S`, `Checkout_lwt`, `Folder_ids_lwt`, `Applied_entries`,
  `File_store_lwt.flush_cursor`, `Staged`): everything the IPC handler answers.
- **Backends** (`Backend_lwt.drain`, `Write_guard_lwt.probe/state`, `Health`, `Corruption`,
  `Collection`, `Wal`, `Journal`): diagnostics and drains; deferred replica/backfill queues
  (`Durable_queue_lwt.rescan_all`).
- **Uplink** (`Uplink_lwt.own_links`, `lease_from`, `lease_renewal`, `answer_json`): link owner in
  the parent, lessees everywhere else, over the sync socket.
- **Maintenance** (`Maintenance_lwt`): the declared sweep list.
- **Commands' libraries** (`Import_lwt`, `Export_lwt`, `Mirror_lwt`, `Gc_lwt`, `Retention_lwt`,
  `Integrity_lwt`, `Rsync_lwt`, `Share_lwt`, `Resync_lwt`): each CLI command is a thin driver.

Depended on by:
- **Frontends** (fuse, file-provider, http-proxy, android): `Frontend` registry,
  `Domain_engine.Domain`, `Ipc_handler`, `Ipc_lwt.serve`, `Domain_engine.run/drain_for_stop`,
  `Shutdown`, `Diagnostics`, `Status_report`, `Menu`.
- **macOS Swift** (`DaemonClient.swift`, `IPC.swift`): the domain-socket wire contract, `menu`,
  `menu_stats`, `subscribe`.
- **Linux tray** and **Dolphin plugin**: domain socket (`status`, `pause`, `stat`/`restore`/
  `evict` by `rel`), `Menu`.

Main flows:
- *Write through a mount*: kernel → fuse op (`on_loop`) → `F` → staged + upload queue (in the fuse
  process) → upload → journal entry + cursor bump (coalesced, flushed on drain); replica copy
  recorded → `rescan` to parent → parent's deferred queue sends it.
- *Peer change*: parent's poller applies journal entries to the mirror → `on_changed key` →
  `Change_notice` batch → `changed` to each frontend socket → `hooks.changed` (fuse invalidation /
  File Provider signal); File Provider then pulls `changes_since`.
- *CLI edit*: `tsync cache --evict P` → `Location.item` resolves `(domain, ref)` from local folder
  markers → `Ipc.action evict` on the domain socket.
- *CLI heavy job*: `tsync import` → own loop, conf `resume:false`, lessee of the link, job reports
  to sync socket every 10 s → `tsync status` shows `Jobs` → on exit drain + settle + final report.

---

## 6. Concurrency, durability & failure semantics

- **Single event loop per process**; no parallelism over domain state. Blocking I/O runs on a
  bounded per-process worker pool. Platform threads enter via `on_loop`. See §6.1 for what this
  model is silently relied on for.
- **What survives a crash/stop**: everything owed is on disk (upload records/WAL, replica jobs,
  staged bodies, durable queue logs). A stop leaves unfinished work for the next start; the
  parent's `resume:true` conf and `start_resumed` pick it up; frontends only record. In-memory
  only: pause flag, job registry, change-notice batches (settled on drain), cursor-bump coalescing
  (flushed on drain — test `stop_publishes_cursor`), diagnostics caches, `recentErrors`.
- **Stop is bounded**: ~10 s drain, +2 s reaper, SIGKILL after; never cancels in-flight jobs
  (races them). Retries/backoffs end with `Stopping` and are not counted as failures.
- **Background-task failures** never kill a daemon: they are logged. A dead event loop kills
  the process at once (exit status 1, no exit handlers) so the supervisor restarts it. The sync socket failing to serve
  exits 2 (restart rather than run unreachable).
- **IPC**: per-connection tasks; a slow request never blocks another client. Mutations per domain
  handler serialised; reads concurrent. The blocking CLI client has **no timeout**; the in-loop
  client defaults to 2 s.
- **Advisory channels** (job reports, change notices, rescan, uplink lease) never fail the
  caller; each failure is logged at most once.
- **Fan-out widths**: every concurrent fan-out here is as wide as the config (domains ×
  frontends × members, 16 shards), not the data, and each leaf has a deadline — so no bounding
  pool is used. A fan-out whose width the data chooses must be bounded.
- **Idempotence**: stop `request()`, IPC stop wake, `Job_report.finish`, `tsync stop` repeated,
  `full_resync` (new generation each time), `pause` set.
- **Descriptor safety**: event-loop backend without a descriptor-number ceiling; fd limit raised pre-fork.
- **Offline**: status reports stores unreachable/held without blocking (cached window, deadlines);
  commands fail with the driver's sentence (`tsync: <reason>`, exit 1).

### 6.1 Correctness that silently relies on cooperative, single-threaded scheduling

The implementation runs every task of a process on one thread and switches tasks only at explicit
suspension points (I/O, sleep, lock wait). Several pieces are correct **only** because nothing
runs between two statements that do not suspend. A rewrite with preemptive threads, or with
parallel workers touching this state, must add locking (or confine the state to one thread) at
each of these:

| where | what would break under preemption |
|---|---|
| subscriber registry `write_pending` | "queue empty → wait on condition" has no lock; a publish between the check and the wait would be a lost wake-up and a stalled stream |
| subscriber `publish` / register / unregister | mutate a shared list and per-subscriber queues without a lock |
| IPC server stop `woken` flag | check-then-wake; two concurrent `stop`s could double-resolve the stop event |
| stop signal `request()` / `on_request` | flag + hook table read and written without a lock; a hook registered concurrently with `request()` could be run twice or never |
| parent/fuse/http-proxy `request_stop` | "if stop not yet resolved then resolve" is check-then-act |
| change notice pending set + `scheduled` flag, `flush`, `settle` | a key added between "read all pending" and "reset set" would be lost; `scheduled` could leave keys with no flush |
| rescan debounce `pending` flag | check-then-set |
| diagnostics `refresh` (`counting` slot) and the 5 s store-state cache | "not counting → mark counting → start walk" relies on atomic check-and-set; the cache entry is replaced without a lock |
| job registry table, `Log.recent` ring, CPU-percent sample, metrics counters | plain shared mutable state |
| pause switch | sets the flag then each queue's flag; a reader between them sees a mixed state (harmless today because nothing yields there) |
| request handler | **reads** are deliberately not serialised; each mirror operation is assumed atomic between suspension points, and only mutations take the per-domain lock (because they *do* suspend between resolving a reference and acting on it) |
| `list_all` kept listing, generation file | written atomically (temp + rename), read without locks — safe under preemption as long as writes stay atomic renames |

The mutation lock (§4.4) is the one place the design already acknowledges interleaving; it exists
because resolution and mutation are separated by suspension points, not because of parallelism.
Platform threads are safe only because they never touch this state directly (§4.3).

---

## 7. Design choices & rationale

- **Convergence in the parent, not a frontend** (cb2be7ac): reconcile/poller/sweeps write shared
  state; running them in "the first frontend" made one frontend secretly different and picked it
  by config order, and a passive frontend never heard peers. The parent presents nothing, so no
  one is picked. Frontends learn about applied changes only through the `changed` notice.
- **Every presenting process runs its own upload queue** (test `presenting_domain`): otherwise a
  process accepts writes it never sends while metadata ops land on the store.
- **No event-loop resources before forking** (the [OCaml notes](ocaml/07-daemon-cli.md) §B.2): an inherited wake-up descriptor sends
  a child's worker completions to the wrong process.
- **Poll backend without FD_SETSIZE ceiling; worker-pool size asked, not defaulted**: the pool
  never shrinks once grown, so its ceiling is a memory floor (~0.5 MB/thread; a mount left at 256
  settled at ~114 MB, a small host's whole budget). Summed across bindings: pool per process,
  budgets per domain.
- **Stop raced, not cancelled** (9ea6d6c3): cancellation looked like a failure and degraded the
  metadata queue. **Queues give way at 0.8 × grace** (c3c4a983) so finished uploads' cursor bumps
  are still published.
- **Children told at once on stop** (9ea6d6c3): nested forks would otherwise need two graces.
- **Listener closes once, after the drain** (9ea6d6c3): status answerable during the drain; two
  removers raised ENOENT out of the accept loop.
- **No TCP_NODELAY on unix sockets** (d8f854af): macOS EINVAL killed the accept loop — presented
  as a File Provider deadlock.
- **Serialise mutations incl. ref resolution** (b7fd7943) rather than a finer lock: correctness of
  concurrent FP requests over throughput.
- **References, not paths, on the wire**: a directory path changes for a whole subtree on rename;
  folder ids do not. A file is (parent id, leaf): blast radius of a rename is one item. Storage
  keys are rejected (no kind; would require guessing). Paths only where the caller holds only a
  path (`rel`).
- **Page cursors are names/line numbers, not offsets** (stateless across processes; no loops when
  one folder id sits at several paths).
- **Change feed from applied local entries, not the store**: never names an item the mirror hasn't
  caught up with; not filtered by author (the CLI's own changes must reach the mount).
- **`status` asks the parent**, which owns the domains, instead of every frontend (each would
  re-probe every backend for the same figures); only collectors fan out; `frontend` flag keeps
  frontends from redoing domain work.
- **Diagnostics never block on stores**: windowed cache, refresh behind the answer, totals only on
  request and served stale with age; `checked:false` distinguishes "nobody looked" from "clean".
- **Advisory reporting** (jobs, notices): reporting must never decide whether a command runs; a
  missing daemon is the ordinary case.
- **Job reports go to the sync socket**, not a domain socket: a domain served only by the
  http-proxy has no socket of its own, while every frontend is a child of the parent.
- **One-shot drain in `Oneshot.run`**, not per command: short-lived commands otherwise strand
  deferred copies and batched notices (a file imported by CLI stayed invisible in a listening
  mount). Exit codes set outside the promise for the same reason.
- **Exit 0 on missing config** so service managers do not respawn-loop on fresh installs.
- **Declared maintenance list**: "what runs unasked" is data; Android once ran half of what the
  daemon ran because loops were ad hoc.
- **`Menu` shared** between Linux tray and macOS (via `menu` action) so the rules exist once.
- **Wizard validates with the parser's own rules** before writing, so it cannot write a config
  the daemon refuses.
- **Syslog without a log file**; `tsync logs` execs the platform reader (journald by identity, so
  renaming units does not lose logs).
- **Scheduler choice is open** (see the [OCaml notes](ocaml/07-daemon-cli.md) §B.2 on the duppy exploration): whatever replaces the
  event loop must keep one worker for domain state plus blocking threads (§6.1), and keep bounded
  pools — a global scheduler bounds width, not working set.

---

## 8. Invariants the tests pin down

- `tests/unit/drain_for_stop`: a drain that finishes is waited for; one that does not is left at
  the grace and **not cancelled**.
- `tests/unit/fork_reap`: children that stop on SIGTERM are reaped at once (<1 s); one ignoring
  SIGTERM is killed after grace + margin (not its own 30 s); a stop reaches all children
  immediately, before any reaping.
- `tests/unit/ipc_serve`: a server stops when asked over its socket, when told by its `until`
  promise, or both; it returns, its socket file is gone, no exception escapes.
- `tests/unit/subs`: connection serves several requests; subscribe acknowledged; subscriber
  counted; topics isolated; publish reports delivery count; events in order; departed subscriber
  dropped; publishing to nobody returns 0.
- `tests/unit/shutdown`: `Sleep.sleep` runs its length without a stop, ends at once on stop, and
  a sleep begun after a stop returns `Stopping` immediately; hooks run once and not after
  unregistering; late hooks run at once; a retry ladder is not climbed past a stop and counts no
  failure.
- `tests/unit/queue_stop`: a command-finishing stop still runs everything queued; a process stop
  takes no more work, returns at once having begun only the running job, leaves all jobs on disk;
  the next start runs them all.
- `tests/frontends/stop_publishes_cursor`: a stop publishes the cursor bump of finished uploads
  even while another upload holds the drain past the grace; stop completes within the grace.
- `tests/frontends/presenting_domain`: a presenting-only process still uploads and publishes the
  cursor; the maintenance list is exactly the 7 tasks in §4.5 with those triggers.
- `tests/scenario/ipc`: exact JSON of `stat` (by `rel` too), `list_dir` (paged by name, `next`),
  `list_all` (`<walk>:<n>` cursors), `unnamed` counting, identical content → identical etag,
  `create` under a key-shaped parent refused `not_found`, `changes_since` up-to-date / pruned
  anchor stale / after reimport stale, op shapes for put/mkdir/rename/delete, `restore` with
  `keep` → `pinned` + `pinnedUntil`, `evict` → `online-only`.
- `tests/scenario/pause`: posted while paused is held (pending=1); resume uploads; drain completes
  while paused.
- `tests/unit/job_registry`: live job listed, killed (and reaped) job dropped; `done`/`failed`
  kept after exit; second report from a pid replaces the first.
- `tests/unit/status_ask`: request shape `{"action":"stats","domain":"beta","arg":"frontend"}`;
  frontend entry carries pid/uptime/cpu/rss/traffic from the process; unbound socket →
  `{type, reachable:false, socketPath, error}`.
- `tests/unit/status_report`: snapshot of the folded report and its text rendering (merge by
  frontend type, unreachable entries, warnings dedup).
- `tests/unit/status_cost`: over a 3000-entry journal, the first report lists the store, ten more
  within the window do not.
- `tests/unit/status_held`: a main that is up is probed; held down it is not probed at all,
  reported once as held, domain says `mainOffline`, replica described as is.
- `tests/unit/menu`: snapshots of the rendered menu for busy/unreachable/paused/below-threshold
  cases (icons, tooltips, rows, "… and N more", checkbox state/enabled).
- `tests/unit/job_render`: text of Jobs blocks (progress bytes vs counts, failed job shows
  `failed, ran … : <error>`).
- `tests/unit/completion`: shell completion offers configured domains, `DOMAIN:/` items, only
  things that exist, every offer is accepted by the command; a path under no domain is refused
  with exit 1 by `ls`, `cache --evict`, `versions`.
- `tests/unit/export_cli`, `export_display`: path spellings accepted/refused by `tsync export`
  (8 ok, 4 refused: missing path, two domains, domain named twice differently, no destination).
- `tests/e2e/ipc_tap`: a bound unix socket survives rename, which lets e2e tests interpose a
  recording relay without test code in the daemon. `tests/e2e/linux|macos`: real daemon
  start/stop and mount behaviour.

---

## 9. Open questions / inconsistencies

1. **Pause does not reach the converging poller (likely bug).** `tsync pause` goes to the domain
   socket (the fuse/file-provider process), whose `Pause` holds only that process's queues. The
   poller runs in the parent with the parent's own `Pause.held`, and the sync socket handler has no
   `pause` action. Since bde81092 (after the cb2be7ac split) the documented "what peers did is not
   applied" appears not to hold on Linux. The parent's own upload/metadata queues (reconcile) are
   also not held. The pause flag is not persisted across restarts either.
2. **File-provider stop is not grace-bounded**: its router serves without `until`; `stop` →
   `Stop` closes the listener at once, then drains every domain **sequentially** with no
   `Shutdown.request` and no `drain_for_stop` race. `hooks.on_stop` is a no-op there.
3. The domain handler returns control `Stop` for `stop` even when its reply is an error.
4. `Ipc.send` (blocking, used by `stop`, `pause`, `cache`, `versions --revert`, `Location`) has no
   timeout: a wedged daemon hangs the CLI (the exact symptom of the EINVAL bug).
5. `tsync stop` prints "relying on signal" when no socket answered, but sends no signal.
6. File-provider router errors (`cannot tell which domain…`, invalid JSON) use
   `{"ok":false,"error":…}` without `code`, unlike `Ipc_handler.error_reply`.
7. `Change_notice.for_domain` caches the socket list on first use; later calls with a different
   list are ignored.
8. Docs vs code: DOCUMENTATION says `sync --full` "clear local cache", the command says "rewriting
   the local mirror in place"; docs say jobs report to "its domain's daemon" and that an
   unanswering domain is named on stderr — code reports to the sync socket and renders
   `unanswered`/`NOT ANSWERING` in the report.
9. `on_leaf` trace naming is per frontend group, so `Process_per_binding` children of one group
   share a memtrace name — contrary to the "one file per process" intent of `trace_process`
   (pids are not in the leaf name).
10. `Descriptors.raise_to ~target:8192` while systemd grants 65536; harmless but two ceilings.
11. `Status` fallback path (no parent) makes every frontend probe every backend — acknowledged as
    the degraded mode, but still the mode on a machine whose parent is down.
12. `Job_registry` keys on pid only; a pid running two reporting jobs sequentially is fine, but
    concurrent reporters in one process (not currently possible) would overwrite each other.
13. **Android embedded host builds its domain with `resume = false`** (`android_jni.ml:load_domain`)
    and there is no daemon parent on the phone, so nothing is the *resumer* of replica/backfill work
    recorded there (§3.8). Whether the "deferred rescan" sweep alone picks such records up in that
    host was not verified here — worth checking against the deferred-queue spec.

---


---

OCaml implementation notes for this subsystem: [ocaml/07-daemon-cli.md](ocaml/07-daemon-cli.md).
