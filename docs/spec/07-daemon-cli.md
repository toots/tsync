# 07 — Process model, lifecycle, IPC contract and CLI

This file owns:

- the **process model** (principle P1): which process owns which domain on each host, the
  ownership lock, the machine-level supervisor, the store server, one-shot commands;
- the **lifecycle**: start order, supervision, stop and its grace, pause;
- the **IPC contract**: sockets, envelopes, bulk actions and the liveness probe, the supervisor
  socket, advisory side channels;
- the **CLI**: every command, its access to a domain, its output and exit status;
- status collection, logging, the shared menu model and the config wizard.

It does not own: the line-JSON framing and subscription streams ([01 §IPC framing](01-core.md)),
the request handler and its actions ([08](08-frontends.md)), what an owner owns
([data-model/local-cache.md](data-model/local-cache.md)), failure kinds and their mapping to codes
and exit statuses ([algorithms/failure-model.md](algorithms/failure-model.md), including IPC codes §7.2, CLI exit
status §7.5 and deadlines §8), the uplink lease
protocol ([algorithms/uplink-governor.md](algorithms/uplink-governor.md)), the durable queue
([algorithms/durable-queue.md](algorithms/durable-queue.md)), the security model
([algorithms/security-model.md](algorithms/security-model.md)), and config validation
([05](05-ops-config.md)).

Implementation notes: [ocaml/07-daemon-cli.md](ocaml/07-daemon-cli.md).

---

## 1. Problem

tsync is one binary that is both a long-running service and a toolbox of commands. Several
processes on one machine act on the same domain: a mount, a File Provider extension's daemon side,
an HTTP server for other machines, a tray, a file-manager plugin, and commands the user types while
all of these run. A domain's local state (mirror, staged edits, write-ahead log, applied log,
deferred-job logs, marks) holds the only copy of unpublished user data and the only record of owed
work. Two processes writing it with process-local locks lose data: one applies a peer's delete
after checking that no staged edit exists, the other stages an edit, the first discards it.

This subsystem removes the problem by construction: **each domain has exactly one local owner
process**, and everything else asks it. It also decides how processes start, stop, talk and report.

---

## 2. Process model

### 2.1 Roles

| Role | Instances | Owns | Does |
|---|---|---|---|
| **Domain owner** | exactly one process per domain per machine at a time | the domain's local state ([local-cache.md](data-model/local-cache.md)) and its ownership lock | converges the domain, resumes its deferred work, runs its queues and maintenance, serves its request interface, hosts the domain's presenting frontend |
| **Supervisor** | at most one per machine (`tsync start` on Linux) | no domain state; the uplink governor, the supervisor socket, the job registry | starts, restarts and stops owners and the store server; collects status |
| **Store server** | at most one per machine (the `http-proxy` frontend) | no domain local state | serves domains' stores to other machines; submits the deferred work it causes to owners' logs |
| **One-shot command** | any number | nothing, unless it takes ownership (§2.5) | acts on stores directly, or asks the owner, or becomes the owner for its duration |
| **Client tool** | any number (tray, Dolphin plugin, File Provider extension, Android UI) | nothing | asks the owner over its request interface |

A process MAY own several domains. It then holds one ownership lock per domain and keeps each
domain's state and serialisation separate.

### 2.2 The domain owner

The owner is the only process that mutates the domain's local state. It:

1. holds the domain's **ownership lock** (§2.3) for as long as it touches that state;
2. **converges** the domain: reconciles owed work at start
   ([wal-and-journal.md](algorithms/wal-and-journal.md)), applies peers' journal entries (unless
   the host's tree is pulled, [08 §2.1](08-frontends.md)), runs maintenance (§6);
3. **resumes** every deferred-job log of the domain: it is the log's only resumer
   ([durable-queue.md](algorithms/durable-queue.md));
4. runs the domain's upload and metadata queues; every local change, whichever client asked for it,
   is posted to these queues;
5. serves the domain's **request interface** ([08 §3](08-frontends.md)) on its socket, or by direct
   call in an embedded host;
6. hosts the domain's presenting frontend, if the domain has one (§2.4).

Within the owner, every check-then-act on local state MUST be serialised per domain for metadata
(names, folders, the WAL, the applied log, marks) and per key for content (staged bodies, cache
bodies, pins), whichever client, queue, poller or sweep performs it. A change applied from a peer,
a local edit arriving from any frontend, reconcile and every sweep take the same locks. No lock
spans processes, because no other process writes.

Other processes MAY **read** owner files that are replaced atomically (mirror entries, markers,
pins, the default-domain file) for advisory answers (`tsync ls`, path resolution, availability,
shell completion). Such a reader MUST tolerate the file changing or vanishing between two reads and
MUST NOT write anything based on what it read.

Other processes MAY **submit** work by creating a new, durable record in one of the domain's logs
(its deferred-job logs, its WAL), as
[durable-queue.md §4.2](algorithms/durable-queue.md#42-ownership) specifies: that is the only write a
non-owner makes under the domain's local state. The submitter then pokes the owner (`poll`, §4.6).
Only the owner reads, runs and removes records, and **only the owner mints journal entry keys and
publishes journal entries** ([wal-and-journal.md §4.9](algorithms/wal-and-journal.md#49-one-owner-per-domain)):
a command that publishes files puts their chunks and manifests on the store and submits the WAL
record that announces them ([durable-queue.md §7.3](algorithms/durable-queue.md#73-kill-point-walkthrough-publishing-without-a-local-staged-edit)).

### 2.3 The ownership lock

- One lock per domain, a file in the data directory (§2.7), taken **non-blocking** and exclusively.
- The lock MUST be released by the kernel when the holder dies, MUST NOT be released by an
  unrelated close of the same file inside the holder, and MUST NOT be inherited by processes the
  holder spawns. (Open-file-description locks or `flock` on a close-on-exec descriptor satisfy
  this; POSIX `lockf` does not, because any close in the process drops it.)
- After acquiring, the holder writes an advisory **holder record** into the lock file:
  `{"pid":<int>,"role":"daemon"|"command"|"app","what":"<e.g. tsync import>","socket":"<path>"|null}`.
  The kernel lock is authoritative; a record read while the lock is free means no owner.
- A process that fails to acquire the lock MUST NOT touch the domain's local state (except the
  permitted reads and inbox submissions of §2.2). It reads the holder record to find the owner's
  socket or to name the holder in a refusal.
- The lock is released only at process exit, or by a one-shot command after its drain (§3.5).
- A process started as an owner that finds the lock held exits with status `OWNER_HELD` (§3.3).

### 2.4 Which process owns which domain

On a host with a supervisor, it assigns each configured domain to exactly one owner process:

1. A domain presented by a frontend whose descriptor declares **per-domain topology** (`fuse`) is
   owned by its own process, which also hosts the mount.
2. A domain presented by a frontend whose descriptor declares **shared topology**
   (`file_provider`) is owned by that frontend's single process, which owns every such domain.
3. A domain with no presenting frontend (only `http-proxy`, or none) is owned by a **headless
   owner** process of its own.

Config validation guarantees at most one presenting frontend per domain ([05 §2.1](05-ops-config.md)).
The supervisor role is optional (P1): a host MAY have none. On macOS there is none: the service
process the launch agent starts owns every configured domain itself (the File Provider framework
talks to one process), holds the governor, and starts the store server as its child ([file-provider.md §2](frontends/file-provider.md#2-processes-and-ownership)).

| Host | Owner of each domain | Supervisor | Converges | Uplink governor |
|---|---|---|---|---|
| Linux service | one process per domain: the FUSE mount process, or a headless owner | `tsync start` | yes, the owner | the supervisor |
| macOS service | the service process started by the launch agent: it owns every domain (the `file_provider` ones and any other) and is restarted by the launch agent on any unclean exit | none: the service process starts the store server itself | yes, the owner | the service process |
| Android | the app process, for each domain it opens | none | reconcile, maintenance, deferred resume; no journal poller (pulled tree, [android.md §3.2](frontends/android.md#32-freshness-without-a-journal-poller)) | the holder of the machine-wide governor lock |
| One-shot command | itself, only when it takes ownership (§2.5) | — | recovery and deferred resume at acquisition; no polling | leased, else the governor lock's holder |

The uplink governor's owner is the supervisor where there is one, otherwise the holder of the
machine-wide governor lock ([uplink-governor.md §4.5](algorithms/uplink-governor.md#45-governor-ownership-and-the-lease-protocol)).

The store server is never an owner. What it needs of a domain is its configuration and its
composite store. Writes it accepts reach the mains synchronously; the deferred copies they cause are
submitted to the domain's deferred-job logs (§2.2) with a poke to the owner, never run by the store
server. Share content is streamed
from the stores and never passes through the owner's chunk cache. It keeps no other domain state.

### 2.5 One-shot commands

The domain's owner is expected to be running at all times: it holds the domain's mirror, queues,
logs and locks, so **every command that changes a domain is a request to its owner**, and the work
runs there. The CLI sends the request, follows it, and prints its result.

A command MAY do its work in its own process only for a reason this file states beside it. The
reasons today: a **read** changes nothing, so it has nothing for the owner to serialize and runs
wherever it is invoked; and **no owner serving** makes the command take ownership for its run. A new
command is an owner request unless such a reason is written down. Each command has an **access
class**:

| Class | Commands | Owner serving | No owner | Owner held but not serving |
|---|---|---|---|---|
| **none** | `config`, `default-domain`, `build-info`, `logs`, `status`, `start`, `stop`, `restart` | n/a | n/a | n/a |
| **read** | `ls`, `versions` (listing), `trash` (listing), `export` | reads stores and permitted local files | same | same |
| **owner** | `pause`, `resume`, `retry`, `set-aside`, `cache --evict/--fetch/--prune`, `versions --revert`, `sync`, `gc`, `expire`, `trash --purge`, `trash --restore`, `mirror`, `data-integrity`, `share`, `import`, `rsync` with a domain side, every `<group> <verb>` whose frontend declares it owner-class (the whole desktop `tsync android` group) | sends the request to the owner, which runs it | takes ownership for its run and performs the request itself (§3.5) | refuses with `busy`, naming the holder |

"Serving" means the holder record names a socket and the socket answers. A refused connection does
not by itself mean the owner is gone: some platforms refuse a connection while the socket's backlog
is full, with the same error as a socket nobody listens on (macOS). Only a free ownership lock means
no owner; a command whose connection is refused while the lock is held by a holder whose record
names a socket retries it until the request's deadline (§4.3), and only then treats the owner as held
but not serving. A holder whose record names no socket (a command that took ownership) never serves,
so the refusal is immediate. A command that takes
ownership is an owner for its duration with every duty of §2.2 except continuous journal polling,
and it runs the owner's drain before releasing the lock. Taking ownership is the fallback for a
machine where the daemon is not running, not the design: the same operation runs either way.

**Owner jobs.** A request whose work takes long (`sync`, `cache --fetch`, `cache --prune`, `gc`,
`expire`, `trash --purge`, `mirror`, `data-integrity`, `import`, `rsync`) is a **job**, bounded by
progress rather than by a total deadline (§4.3):

- With `--verbose`, the request asks for narration: the owner streams the job's narration
  ([05 §4.1](05-ops-config.md#41-rules-common-to-every-operation)) on the request's connection as it
  happens, and the CLI writes it to stderr. The final answer carries the result.
- Every job reports to the job registry (§4.6), so `status` shows it whoever started it.
- An operator's interrupt (Ctrl-C) makes the CLI send `cancel` naming its job: the job stops at its
  next unit boundary and leaves its durable state as any interruption does. A client that goes away
  without cancelling does not stop the job; it runs to completion (§4.3).
- Two jobs that would conflict on one domain (two collections, a collection and a purge of the same
  folder) do not run at once: the second is refused `busy`, naming the first.
- **Bounded stop.** As far as possible, a command and the work it asks for stop within a reasonable
  time of being asked. A job checks for cancellation at units small enough that the next boundary
  comes within seconds (a folder of a walk, a shard, a batch of keys), and every wait it makes is
  bounded by a timeout, a deadline or a stall rule. A second interrupt ends the CLI at once without
  waiting for the job's answer; the job still stops at its next boundary.

### 2.6 Pause

`pause` stops **everything that changes the domain** on this machine, persistently:

- publishing local changes (the upload and metadata queues);
- applying peers' journal entries (the poller holds; it MAY still list the journal to report how far
  behind it is);
- forwarding deferred work to replicas and backfills;
- owner requests and jobs that change the domain's stores or apply work (`revert`, `share`, `sync`,
  `gc`, `expire`, `trash --purge`, `trash --restore`, `mirror`, `data-integrity --repair`, `import`,
  `rsync`): these refuse with `paused` ([08 §3.3](08-frontends.md) marks them).

It does not stop: reads and the fetches they cause, local edits (accepted, staged, recorded and
held in the queues), local cache maintenance, requests from the store server's remote clients (their
own changes, paused only on their own machines), `stop`.

Rules:

- The pause state is per domain and is **persisted** by the owner as a flag file (§2.7), written
  durably ([durable-queue.md](algorithms/durable-queue.md) P2) before `pause` is acknowledged, and
  removed durably before `resume` is acknowledged. An owner reads it at start before starting any
  queue or the poller.
- A command that finds no owner reads the flag file itself.
- A drain completes while paused: a paused queue does not delay a stop; what it holds stays owed on
  disk.
- `status` reports `paused` from the owner's state.

### 2.7 Runtime paths

| Item | Linux | macOS |
|---|---|---|
| config | `$XDG_CONFIG_HOME/tsync/config.json` (default `~/.config/…`) | `~/Library/Group Containers/group.org.feverdreamtv.tsync/config.json` |
| data dir | `$XDG_DATA_HOME/tsync` (default `~/.local/share/tsync`) | `<group container>/tsync` |
| cache root | `$XDG_CACHE_HOME/tsync` (default `~/.cache/tsync`) | `<data dir>/cache` |
| owner socket | `<data dir>/tsync-<domain>.sock` (one per owner) | `<data dir>/tsync.sock`, the service process's one socket for every domain (routes by `domain`) |
| store-server socket | `<data dir>/tsync-http-proxy.sock` | same |
| supervisor socket | `<data dir>/tsync-sync.sock` | same |
| ownership lock | `<data dir>/owners/<domain>.lock` | same |
| governor lock | [uplink-governor.md §4.5](algorithms/uplink-governor.md#45-governor-ownership-and-the-lease-protocol) | same |
| pause flag | `<data dir>/paused/<domain>` (present = paused) | same |
| resync generation | `<data dir>/resync-<domain>` ([08 §2.5](08-frontends.md)) | same |
| feed watermark | `<data dir>/feed-watermark-<domain>`: the entry key, a space, the epoch ms it last moved ([08 §3.6](08-frontends.md#36-change-feed-changes_since)) | same |
| dropped-shard record | `<data dir>/feed-dropped-<domain>` (present = a shard was dropped) | same |
| default domain | `<data dir>/default-domain` (one line, the name) | same |
| restart (through the service manager, never by signalling processes found by name) | `systemctl --user restart tsync` | `launchctl kickstart -k gui/$UID/org.feverdreamtv.tsync.daemon`, then open the app |
| log reader | `journalctl -t tsync -n N [-f]` | `tail -n N [-f] ~/Library/Logs/tsync-daemon.log` |

`$TSYNC_CONFIG_JSON`, when set, is the config text itself and overrides the file. Modes and
ownership of the data dir and of every directory holding a socket, lock or flag:
[security-model.md §7.1](algorithms/security-model.md#71-socket-directory-and-files).

A socket path longer than the platform's limit for a Unix socket address cannot be bound. The
supervisor and every owner MUST check the length before binding and fail with a sentence naming the
domain and the limit.

### 2.8 Service units

- Linux user unit `tsync.service` and system template `tsync@.service` (`User=%i`): `ExecStart=tsync
  start`, `ExecStop=tsync stop`, `Restart=on-failure`, `RestartSec=5`,
  `RestartPreventExitStatus=78`, `TimeoutStopSec` greater than `STOP_WAIT` (§3.4),
  `LimitNOFILE=65536`. The system unit MUST NOT use `ProtectHome=`, `PrivateTmp=` or
  `PrivateMounts=`: a private mount namespace hides the FUSE mount from everyone else.
- macOS launch agent `org.feverdreamtv.tsync.daemon`: `RunAtLoad`, `KeepAlive {SuccessfulExit=false}`
  (the service process, which owns every domain, is restarted on any unclean exit), output to
  `~/Library/Logs/tsync-daemon.log`.

---

## 3. Lifecycle

### 3.1 `tsync start` (the supervisor)

1. Initialise daemon logging (§5.7).
2. No config file, or a config with no domains: say so on stderr and **exit 0**. An installer starts
   the service before configuration; a non-zero status would make the service manager respawn it.
   On macOS the service process instead keeps serving its request socket with no domain
   ([file-provider.md §11](frontends/file-provider.md#11-installation)): the app's subscription and
   menu need a listener before the first domain exists.
3. Load and validate the config ([05 §2](05-ops-config.md)). Invalid: print the error and exit with
   status **78** (`EX_CONFIG`), which the Linux units exclude from restarts.
4. Refuse, before starting any process, a configured frontend whose descriptor is `Commands`
   ([08 §2.1](08-frontends.md)), with that frontend's own refusal text, and a frontend that is not
   compiled into this binary ("configured but not compiled into this binary").
5. `--mount P` replaces the FUSE mount point only when exactly one domain is configured; otherwise
   it is refused. `--tls` overrides the TLS implementation for every process it starts.
6. Raise the descriptor soft limit to the hard limit, capped at `FD_SOFT_TARGET`, never lowering it.
7. Take the supervisor role: refuse to start if another supervisor answers on the supervisor socket
   ("tsync is already running", exit 1).
8. Start one owner process per owner assignment (§2.4) and the store server if any domain lists
   `http-proxy`. Each child MUST start with no runtime state inherited from the supervisor other
   than its arguments and environment: it is either a fresh execution of the binary or a fork made
   before the supervisor created any event-loop, thread-pool or socket resource.
9. Become the uplink governor's owner ([uplink-governor.md §4.5](algorithms/uplink-governor.md#45-governor-ownership-and-the-lease-protocol))
   and serve the supervisor socket. Failure to bind is fatal (exit 2): without the socket no stop and no lease is
   heard, and a restart by the service manager is better than running deaf.
10. Supervise (§3.3) until a stop is requested (§3.4).

On macOS, steps 7–9 are replaced by: take the governor lock, start the store server if configured,
and run the owner start (§3.2) for every configured domain in this process.

The order between the supervisor's socket and its children's start is not load-bearing: a lessee
that cannot reach the supervisor governs its own link and keeps renewing.

### 3.2 Owner start

In order:

1. Acquire each owned domain's ownership lock (§2.3); on failure exit `OWNER_HELD`. Write the
   holder record.
2. Build the domain from config ([05 §3](05-ops-config.md)).
3. Read the pause flag.
4. Local recovery of the checkout, including the exact staged-orphan sweep and the temporary-file
   sweep ([04 §4.10](04-checkout-cache.md#410-owner-start-local-recovery)).
5. Start the upload and metadata queues (paused if flagged), then **reconcile**
   ([wal-and-journal.md §4.7](algorithms/wal-and-journal.md#47-crash-recovery-reconcile)): recovery
   posts through the queues, so they run first.
6. Start every log of the domain with recovery, adopting submitted records
   ([durable-queue.md §4.2](algorithms/durable-queue.md#42-ownership)).
7. Start the journal poller (held if paused; not at all for a pulled tree) and periodic maintenance.
8. Serve the owner socket, then publish the recovery notice for each owned domain
   ([08 §3.8](08-frontends.md#38-events)), so a client latched on a router's "not served" answer clears.
9. Present: mount FUSE, or signal the File Provider system, as the frontend specifies.
10. Serve until stopped.

Nothing is presented before reconcile has finished its local part: a client never sees a mirror
that recovery is about to change underneath it.

**Starting on existing state.** An owner starts on whatever local state it finds, with no
conversion step: every local file is read under the definitions of its owning file
([04](04-checkout-cache.md), [local-cache.md](data-model/local-cache.md),
[durable-queue.md](algorithms/durable-queue.md), [03](03-journal-sync.md),
[05 §4.4](05-ops-config.md#44-export)), and the owed work it holds continues. For the files this file
owns:

- an absent ownership lock file means the domain is unowned; the owner creates it;
- an absent pause flag means not paused;
- a file that exists at a socket path is removed and the path bound afresh by the process that
  serves it;
- a file in a log directory that does not match the record grammar is ignored and never blocks
  adoption of a record ([durable-queue.md §4.2](algorithms/durable-queue.md#42-ownership)): the
  ownership lock is the only claim.

### 3.3 Supervision

- The supervisor waits on its children. A child that exits while no stop is requested is restarted
  after a backoff that starts at `RESTART_BACKOFF_MIN` and doubles up to `RESTART_BACKOFF_MAX`; the
  backoff resets after the child has run for `RESTART_STABLE`. Each restart is logged with the exit
  status.
- Exit statuses of an owner: 0 clean stop; 1 failure (including a dead event loop, §3.7);
  `OWNER_HELD` (75) the domain is owned by another process (for example a `tsync sync` running as
  owner) — retried with the same backoff, logged at info.
- A FUSE mount unmounted from outside ends its owner with status 0; the supervisor restarts it like
  any other exit, since no stop was requested.
- No restart happens once a stop is requested.
- On macOS the launch agent restarts the service process on any unclean exit; the service process
  restarts its store-server child as above.

### 3.4 Stop

Triggers: `tsync stop` (IPC `stop`), SIGTERM or SIGINT, the service manager's stop.

**Stop signal.** Each process has one process-wide stop flag with hooks
([01](01-core.md) shutdown). Requesting it is idempotent. Backoffs, retry ladders, queue workers and
uplink waits give way with STOPPING ([failure-model.md](algorithms/failure-model.md)): owed work is
left untouched on disk, never counted as a failure, never cancelled into a completed record.

**Owner stop.**

1. Stop accepting new requests on its socket except `stats`, `status` and `stop`, which stay
   answerable during the drain.
2. Begin un-presenting concurrently with the drain (unmount FUSE: [frontends/fuse.md §6.2](frontends/fuse.md)).
3. Drain every owned domain concurrently, raced against `GRACE`. The race MUST NOT cancel the
   drains: a cancelled job would be recorded as a failure of work that was merely unfinished.
4. Per-domain drain, in order: metadata queue, then upload queue (a published rename names the file
   an upload behind it is for), this pair raced against `QUEUE_GRACE_FRACTION × GRACE`; then flush the
   coalesced cursor bump so peers hear of uploads that finished; then settle the deferred-job logs
   ([durable-queue.md §4.8](algorithms/durable-queue.md#48-settle-stop-and-pause)), all within the
   grace.
5. On timeout, log "still busy after GRACE; what is left is owed on disk and resumes at the next
   start".
6. Close and remove its socket (exactly once, by the server that bound it), release the ownership
   locks by exiting.

The File Provider process follows the same protocol for all its domains; its stop is bounded by the
same grace.

**Store server stop.** Stop accepting HTTP requests, settle in-flight ones and the inbox submissions
they owe, raced against `GRACE`; then close its socket and exit.

On macOS the service process is the owner and has no supervisor: it stops as an owner, and stops its
store-server child as the supervisor would.

**Supervisor stop.**

1. Tell every child at once (SIGTERM), not after anything else: a child that has children of its own
   then stops alongside them within one grace.
2. Reap: poll children every `REAP_POLL` until `GRACE + REAP_MARGIN`; then SIGKILL the rest and reap
   them. Unregister the children afterwards so a later signal never reaches a recycled pid.
3. Keep the supervisor socket answering `stats` and `stop` until the children are reaped, then close
   it and exit 0.

`STOP_WAIT = GRACE + REAP_MARGIN + REQUEST_DEADLINE` ([failure-model.md §8.3](algorithms/failure-model.md#83-parameters)) bounds a whole-machine stop. Service
managers' stop timeouts MUST exceed it.

### 3.5 One-shot lifecycle

A command sends its request to a serving owner and follows it. The steps below are the fallback,
when no owner serves and the command takes ownership for its run:

1. Load and validate config; fail before any terminal output.
2. If the command's class needs it (§2.5), take ownership.
3. Lease the uplink from the governor's owner, or become it (§2.4).
4. Start a job report (§4.6) if the command reports.
5. Run the body.
6. Drain: run the owner's drain.
7. Finish the job report (`done` or `failed`).
8. Release ownership by exiting, **then** decide the exit status: exiting from inside the body skips
   the drain.

A one-shot owner's drain uses the durable queue's command settle
([durable-queue.md](algorithms/durable-queue.md) `settle_all`): it runs what it holds to completion,
bounded by the settle timeout; what remains is owed on disk for the next owner.

### 3.6 Embedded host (Android)

The app process is the owner of the domains it opens. The platform kills it without warning, so it
MUST be correct with no drain: every operation's state is durable before it is acknowledged, and
the next owner start reconciles and resumes whatever was owed. It runs no supervisor, no socket and
no journal poller; requests arrive by direct call through the same request handler (same JSON, same
error codes). CLI verbs driving the Android frontend on a desktop (`tsync android <verb>`) are
**owner**-class commands.

### 3.7 Event-loop hosting

- All domain state is touched only by the owner's scheduler. Platform threads (FUSE workers, JNI
  threads) submit a closure to the scheduler and block only themselves until it completes. An OS
  error raised by the core passes back to the platform thread unchanged (it is an answer); any
  other failure is carried back with its original trace.
- A host whose platform must own the main thread (libfuse) runs the scheduler on another thread;
  the main thread waits until the scheduler says it is ready before entering the platform loop.
  The ready signal is also released if the scheduler's body ends without calling it.
- **Loop death.** If the scheduler itself fails (not a task within it), the process logs the failure
  with its trace, flushes, and exits with status 1 **without** running exit handlers: they would
  drain through the dead scheduler and hang. The supervisor restarts it (§3.3).
- A failure in a background task is logged and never ends the process.
- The readiness mechanism MUST have no ceiling on descriptor numbers (never `select(2)`): above
  `FD_SETSIZE` one high descriptor takes the loop down.

---

## 4. IPC contract

### 4.1 Sockets

| Socket | Served by | Answers |
|---|---|---|
| owner socket | each owner | the request handler ([08 §3](08-frontends.md)) |
| store-server socket | the store server | `stats` (its own figures with `frontend`, else its full report), `status` (the full report, as `stats` with totals), `ping` (the liveness answer of §4.3), `stop` ([frontends/http-proxy.md](frontends/http-proxy.md)) |
| supervisor socket | the supervisor | §4.4 |

- Framing, line and connection bounds, subscription streams and server robustness:
  [01 §11](01-core.md#11-ipc-framing). Socket modes, directory checks and the same-uid peer check:
  [security-model.md §7](algorithms/security-model.md#7-local-ipc-access-control).
- No process sends change notices to any socket: an owner's frontends learn of changes in-process
  ([08 §3.2](08-frontends.md#32-hooks)), and the store server keeps no view to refresh.
- A server binds its path after removing a stale socket file, and is the only process that removes
  its socket, once, when it stops.

### 4.2 Envelopes

- Request: `{"action":"<verb>", "domain"?:"<name>", "ref"?:"<item ref>", "arg"?:"<string>", …}`.
  `domain` may be omitted only on a socket serving exactly one domain.
- Success: `{"ok":true, …fields}`. Failure: `{"ok":false,"code":"<code>","error":"<sentence>"}`.
  **Every failure carries a code**, including a router's own refusals and a malformed item reference
  (INVALID). The codes and the kinds they stand for are
  [failure-model.md §7.2](algorithms/failure-model.md#72-client-error-codes); a client treats a missing
  or unknown code as `internal`. A line that is not JSON is answered exactly
  `{"ok":false,"code":"invalid","error":"invalid JSON"}`; an unknown action is refused `invalid`,
  naming it.
- A reply to `stop` returns control `Stop` to the server only when the stop was accepted.

### 4.3 Deadlines, bulk actions and the liveness probe

Deadlines on both sides of every request are
[failure-model.md §8.2](algorithms/failure-model.md#82-requests-between-processes). This contract
designates:

- **Bulk actions**, bounded by progress rather than by a total deadline: `ensure_cached`,
  `fetch_range`, `write` with `await`, `evict` and `restore` of a folder, `sync`, `prune`
  ([08 §3.3](08-frontends.md) marks them **B**).
- **The liveness probe** that [failure-model.md §8.2](algorithms/failure-model.md#82-requests-between-processes)
  requires: `ping`, answered `{"ok":true}` from memory by every server (owner, store
  server, supervisor), never waiting on a store, a lock held across I/O, or a pool. It is
  time-sensitive work ([01 §6.5](01-core.md#65-scheduling)), answered by the socket layer before
  the request reaches a server's own dispatch. A client waiting on a bulk action probes on a
  separate connection.

A client that abandons a request closes its connection; the server's work continues and lands for
the next caller.

### 4.4 Supervisor socket

| action | request | reply | behaviour |
|---|---|---|---|
| `stats` | `arg`: comma set of `totals`, `exact`, `reload` | the machine report (§5.5), `ok:true` | `exact` implies totals; `reload` only with totals |
| `report` | a job report (§4.6) | `ok:true` | recorded in the job registry |
| `uplink` | lease renewal ([uplink-governor.md §4.5](algorithms/uplink-governor.md#45-governor-ownership-and-the-lease-protocol)) | lease answer | a process that does not own the governor answers without grants |
| `ping` | — | `ok:true` | liveness probe |
| `stop` | — | `ok:true` | starts the supervisor stop (§3.4); the socket stays up until children are reaped |
| other | | `invalid "unknown action: <a>"` | |

### 4.5 Owner socket

The request handler of [08 §3](08-frontends.md), for every domain the owner owns. The owner-level
actions it includes (`pause`, `stop`, `stats`, `status`, `poll`, `ping`, `subscribe`) are listed
there with the others.

### 4.6 Advisory side channels

All of these never fail their caller, are bounded by the advisory send deadline
([01 §11](01-core.md#11-ipc-framing)), log each kind of failure at most once, and carry hints on top
of durable state.

- **Poke.** A process that submitted records to a domain's logs sends `poll` to the domain's owner.
  No owner answering is not an error: the next owner adopts submitted records at start, and every
  owner rescans its logs periodically ([durable-queue.md §4.2](algorithms/durable-queue.md#42-ownership)).
- **Uplink lease.** Every process that writes to stores and does not own the governor renews a lease
  ([uplink-governor.md §4.5](algorithms/uplink-governor.md#45-governor-ownership-and-the-lease-protocol)).
- **Job report.** A one-shot command that reports sends `report` to the supervisor every
  `JOB_REPORT_INTERVAL`, sequentially (a slow send delays the next), with state `running`, then one
  final report `done` or `failed` (with `error`). Finishing twice is a no-op. `kind` names the command
  as typed (`import`, `sync --full`, `gc --abort`, …); `progress` carries total, skipped, done,
  handled and remaining, and an ETA from the run's own rate, absent before anything settled and after
  completion; `step` is what the job's progress says it is doing now. An owner reports each job it
  runs the same way, under its own pid, whoever started the job, so `status` shows it. A missing
  supervisor is the ordinary case: reporting never decides whether a command runs.

The job registry keys a report by (pid, kind, domain). A running entry not refreshed for
`max(JOB_STALE_MIN, 4 × interval)` whose pid is gone is dropped; `done` and `failed` entries are kept
for `JOB_KEEP` after their last report; a new report for a key replaces the old row.

---

## 5. CLI

### 5.1 Conventions

- **Domain resolution**, everywhere: `--domain NAME`, else the name in the default-domain file if it
  is configured (a recorded name that is not configured is ignored with a warning), else the sole
  configured domain, else the error "multiple domains configured — use --domain to select" (or "no
  domains configured").
- **Output.** Results on stdout; progress, narration and logs on stderr.
- **`-v/--verbose`**, accepted by every command, makes the operation narrate itself for a human
  operator who wants to follow it as it runs, understand what it decides, and debug it, in more detail
  than an operator normally needs:
  - each step as it starts and ends, with what it covers (which domain, member, folder or phase) and
    how long it took;
  - each decision that is not obvious and why: what it skipped, kept, refused, retried or waited for,
    and the rule that decided it;
  - counts and progress through long steps, at a pace a person can read (a line per unit of work, or
    periodic totals when units are many), with **no prolonged silence**: a step that runs longer than
    a few seconds reports where it is at regular intervals, so a silence means something is wrong;
  - plain sentences that name things as the operator knows them (paths, member names, dates), never
    internal identifiers alone.

  Narration goes to stderr and never changes stdout, so a script reading the result sees the same
  bytes with or without `-v`. It is not a log level: logs serve the program's maintainers and keep
  their own level (§5.7); `-v` also lowers the CLI's log level to `info`. Without `-v`, a command
  prints its result and only what needs the operator's attention, and its progress.
- **Progress by default.** A command whose work can take more than a few seconds shows its progress
  on stderr while it runs, with or without `-v`: a user who sees none assumes it is stuck. On a TTY it
  is the redrawn block below (a progress bar, counts, the current step); not on a TTY, periodic lines.
  `-q/--quiet`, accepted by every command, suppresses every kind of in-progress output (progress and
  narration), leaving the result and what needs the operator's attention.
- **Exit status**: [failure-model.md §7.5](algorithms/failure-model.md#75-cli-exit-status); a classified
  failure prints `tsync: <sentence>`. Status 2 (a refusal about the invocation's environment) is used
  by `sync` on a pulled tree ([08 §2.1](08-frontends.md#21-frontend-descriptor)).
- **Durations**: `<N>d|h|m|s` with N > 0; anything else is an invalid argument.
- **Progress on a TTY**: a redrawn block on stderr (cursor-up, clear to end), lines truncated to the
  terminal width by code points with `…`, redrawn on a timer with the elapsed time so a long call
  inside a step still shows life; a persistent note is printed above the block; log lines and result
  lines clear the block first, and a result line ends the step shown. Not a TTY: a progress line on
  stderr at most every 10 seconds.

### 5.2 Path arguments

- `DOMAIN:/path` or `DOMAIN:path` names a domain outright iff `DOMAIN` is a configured domain name;
  otherwise the token is a local path containing a colon.
- A command reads a relative token either as domain-relative (in the resolved domain, wherever it
  runs from) or as a local path, and says which in its help.
- A local absolute path resolves to a domain by lying under one of the domain's roots, tried in
  order: its mount point, its File Provider folder (macOS), then the data directory. A path under no
  root is refused with exit 1.
- Resolving a path to an item reference reads the domain's folder markers (a permitted read,
  §2.2). A folder this client holds no id for is refused with "this client has not resolved its
  folder; run 'tsync sync'".

### 5.3 Commands

| command | class | semantics |
|---|---|---|
| `start [--mount P] [--tls native\|openssl]` | none | §3.1 |
| `stop` | none | §5.4 |
| `restart` | none | the platform restart through the service manager (§2.7); exit 1 if the service is not installed |
| `status [--json] [--totals [--exact] [--reload]] [-w S]` | none | §5.5 |
| `logs [-f] [-n N]` | none | executes the platform log reader (default N = 200); explains what is missing if it cannot |
| `pause` / `resume` | owner | §2.6; also spelled `pause-uploads` / `resume-uploads` |
| `ls [PATH] [--deleted] [--frontend F]` | read | children sorted case-insensitively: `dir    name/`, or `<availability>  name  N bytes` (`pinned until <time>`); `--deleted` appends `deleted  name` rows |
| `cache --evict\|--fetch [--keep DUR] PATH...` | owner | `evict` / `restore` per path ([08 §3.4](08-frontends.md)), as bulk actions; one line per path, exit 1 if any failed; `--keep` default 10 days |
| `cache --prune [--grace DUR]` | owner | runs every on-demand maintenance task (§6) in the owner (`prune`, a bulk action); prints per task files and bytes; `--grace` default 1 h |
| `retry` | owner | re-adopt every parked record of the domain's logs now ([durable-queue.md §4.7](algorithms/durable-queue.md#47-parking-and-retry-of-parked-records)); owner action `retry`; prints the count re-adopted |
| `set-aside [--remove NAME... \| --remove-all]` | owner | lists the domain's set-aside objects (staged manifests, WAL and log records that could not be decoded) with their size and time, or removes the named ones after the user inspected them ([durable-queue.md §3.3](algorithms/durable-queue.md#33-ordering-rules), [04 §4.10](04-checkout-cache.md#410-owner-start-local-recovery)); owner action `set_aside` |
| `versions [PATH]` | read | versions of a file, newest first (`time  human  size`), or every deleted file of the domain |
| `versions --revert PATH [--version TS]` | owner | `revert` (latest when no version) |
| `trash` | read | trashed folders |
| `trash --restore PATH` | owner | [05 §4.8](05-ops-config.md); exit 1 on `Parent_unknown` |
| `trash --purge PATH` | owner | exit 1 on `Live_elsewhere` or `Not_in_trash` |
| `expire DATE` | owner | cutoff `YYYY-MM-DD` at local midnight; prints removed trash entries, versions and journal entries |
| `gc [...]` | owner | [05 §4.9](05-ops-config.md) |
| `sync [--full] [--source NAME] [-j N]` | owner | the resync operation ([05 §4.7](05-ops-config.md)) in the owner (`sync`, a bulk action); refuses with exit 2 for a pulled tree; prints `N journal entries from other clients` or `full resync: N manifests (K failed …)`, exit 1 if any failed |
| `data-integrity [--verify\|--repair] [--detail] [--source] [--dry-run]` | owner | [05 §4.10](05-ops-config.md); exit 1 if unhealthy |
| `mirror [--source] [--skip-chunks\|--path P]` | owner | [05 §4.6](05-ops-config.md); needs at least two members |
| `import DIR [--only G] [--exclude G] [--force-rehash]` | owner | [05 §4.3](05-ops-config.md); exit 1 if any entry failed |
| `export [PATH...] DIR [--source] [-j N]` | read | [05 §4.4](05-ops-config.md); one domain per run; exit 1 on failures or on pending local changes (listed on stderr) |
| `rsync SRC DST [--move] [-n]` | owner | [05 §4.5](05-ops-config.md). A side in a domain is `DOMAIN:PATH`, or `:PATH` for the domain `--domain` or the default resolves; any other argument is a local path (one holding a `:` before its first `/` is written `./…` or absolute). Two local sides, or two different domains, are refused with exit 2. `-n` prints each entry's decision and changes nothing |
| `share [PATH] [--expires DUR] [--token HEX] \| --revoke TOKEN\|URL \| --clear-cache` | owner | [05 §4.11](05-ops-config.md); URL on stdout, expiry on stderr; `--revoke` exits 1 when no share of the domain held the token |
| `config [--edit]` | none | print the parsed config with secrets masked, or run the wizard (§5.9) |
| `default-domain [NAME] [--clear]` | none | set (must be configured), clear, or print (exit 1 when unset) |
| `build-info` | none | compiled frontends and drivers, log sink, paths, sockets |
| `<group> <verb> [ARGS...]` | per verb | frontend-contributed ([08 §2.1](08-frontends.md)); the binary resolves `--domain`, checks the frontend is configured for it, and passes the remaining arguments uninterpreted. `fileprovider reset` terminates no process and `fileprovider purge` stops the owner only after the app released its domains ([file-provider.md §9.3–9.4](frontends/file-provider.md#93-reset)); the desktop `tsync android` group is owner-class |

`--source NAME` reads from one member ([05 §3.1](05-ops-config.md) `reading_from`); `-j N` sets read
parallelism (`reading_at_most`).

### 5.4 `tsync stop`

1. Send `stop` to the supervisor socket. If it acknowledges, wait until the socket stops accepting
   connections, polling every 100 ms, for at most `STOP_WAIT`.
   - Gone: print `Stopped tsync.` and exit 0.
   - Still there: print `tsync: still stopping after <N>s; unfinished work is owed on disk and
     resumes at the next start` and exit 1.
2. If no supervisor answers (no socket, or connection refused), send `stop` to every owner socket
   and the store-server socket of this configuration, concurrently, and wait for each the same way.
   - At least one stopped: print `Stopped <N> process(es).` and exit 0.
   - None was running: print `tsync is not running.` and exit 0.

   An owner socket is absent only when no domain it serves has a live holder naming a socket
   (§2.5): a refusal while one does is retried until the request's deadline, then reported as
   `tsync: <socket> refused connections for <N>s while its owner runs`, exit 1. Likewise an owner
   is gone once its socket refuses and its holder no longer lives, not at the first refusal.
3. A socket that accepts but does not reply within the client deadline: print
   `tsync: <socket> did not answer within <N>s` and exit 1.

The command MUST NOT claim an action it did not take. One-shot owners have no socket and are not
stopped by `tsync stop`.

### 5.5 `tsync status`

1. Resolve targets once (a `--watch` redraw does not re-read the config): the supervisor socket,
   every owner socket and the store-server socket of this configuration.
2. Ask the supervisor `stats`. Its reply is the finished machine report; the supervisor answers
   within the request deadline, marking what it could not collect in time.
3. With no supervisor, ask every owner socket and the store-server socket and fold their answers
   the same way.
4. Print JSON (`--json`, with `"t": <now>` prepended) or text. `-w S` redraws every S seconds,
   clearing the screen (not in `--json`).

**Collection (supervisor).** The supervisor asks each owner and the store server for `stats` with
`arg` containing `frontend` plus the caller's flags, and folds them
with its own process description and the job registry. **Only a collector fans out**: a process
asked for its own figures asks nobody. A failed answer becomes a process entry
`{reachable:false, socketPath, error}`; `ask` never raises.

**Report shape.** Machine report `{host, domains:[…], processes:[…], jobs:[…], warnings:[…]}`:

- a process self-description: `server {hostname, pid, startedAt, uptimeSeconds, loadAvg?, role,
  serves:[domains]}`, `process {cpuSeconds, cpuPercent, cpuPercentAvg, rssBytes, privateBytes,
  swappedBytes, heapBytes, topHeapBytes, minorCollections, majorCollections}`, `backend`, `pools
  [{name, inFlight, waiting, max}]`, `uplinks`, `traffic`, `recentErrors [{t, level, message}]`
  (the last 50 warnings and errors). `cpuPercent` covers the interval since the previous report
  (reports under 1 s apart reuse it; the first is the lifetime average);
- a domain body from its owner: resolved settings, `mainOffline?`, `paused`, `sync {state:
  "incremental" | "hold", reason?, markAgeSeconds, unappliedEntries, unappliedReason?, parkedMetadata}`
  ([wal-and-journal.md §4.8](algorithms/wal-and-journal.md#48-retention-horizon-bridging-and-rebuild)),
  `cache {chunks, bytes, pinnedBytes, maxCache, manifests?}`, `wal {pending, intent, prepared,
  executed, stuck, lastError}`, `queues {pendingFiles, inFlight: [FIFO], bytesOwed}` (pending counted
  in files; bytes owed are whole-file bytes, in-flight included; a folder rename owes 0 bytes),
  `frontends [...]`, `backends [{name, type, role, link?, config (secrets masked `***`), reachable, latencyMs, error,
  journal {entries, behind, cursor, lastSync} | {counting} | {error}, corrupted {checked, chunks?,
  truncated?}, disk?, health, totals?}]`;
- the fold: domain bodies deduplicated by name, a stub `{name, unanswered:true}` for a domain no
  process answered for; processes one per pid with `serves` widened; jobs deduplicated by
  (pid, kind, domain); warnings grouped by (level, message) with per-process counts and first/last
  times, newest first.

**Cost rules.**

- A member's probe and corruption listing are cached per owner for `STORE_STATE_WINDOW`, and its
  journal listing for `JOURNAL_WINDOW`, shared by every asker, and refreshed behind the answer. A
  journal listing reads every entry (thousands of objects, several pages on a remote store), so a
  status page or `status --watch` polling every few seconds must not take one per poll. An answer waits for
  a listing at most `LISTING_GRACE` after the probe, else reports `{"counting":true}`.
- A member held down by its breaker is not probed (`reachable:false`, error = the hold).
- `journal.behind` counts listed entries newer than the last-sync mark and not authored by this
  client (this client's own entries are never behind; keys compare without their month directory);
  the listing is not truncated (a cut would drop exactly the newest entries).
- `totals` (store contents) are never computed while a request waits: an answer serves the last
  sample with `sampledSecondsAgo` (+ `refreshing`); a walk starts only when none exists or on
  `reload`; one walk per (store, precision). A chunk count MAY be an estimate from a sample of
  shards, and says so; manifests are always a full listing.
- `corrupted.checked:false` distinguishes "nobody looked" from "clean".

**Text rendering.** Header `tsync on <host> — N domains, M processes, up X, load L`; per domain its
settings, cache, `PAUSED`, unsynced or stuck WAL, `MAIN OFFLINE`; each frontend (`NOT ANSWERING`,
traffic, open handles, parked metadata, unapplied peer entries, transfers, maintenance); each backend
(`UNREACHABLE`/`HELD DOWN`, journal, corruption or "not checked", disk); then `Processes`, `Jobs`,
`Warnings (newest first)` (10 shown). A row appearing is the signal: clean states print nothing.

### 5.6 Pause and resume

`tsync pause|resume` sends `pause` (`arg` `"on"` or `"off"`) to the domain's owner, or, with no
owner, takes ownership and writes or removes the pause flag durably itself (§2.5, §2.6). It prints `Paused <domain>.` or
`Resumed <domain>.`

### 5.7 Logging

- Levels `debug`, `info`, `warn`, `err`; CLI default `warn` (`-v` → `info`), daemons `debug`. An
  owner of one domain prefixes its lines with `[<domain>] `. The sink is replaceable (Android logs to
  logcat). The last 50 warnings and errors are kept with timestamps for `recentErrors`.
- Daemons log to syslog (ident `tsync`, facility daemon, with pid), echoing to stderr only when
  stderr is a terminal; without syslog, to stderr. tsync writes no log files of its own.

### 5.8 Menu model (tray and macOS menu bar)

A pure function from per-domain `status` replies to a menu, shared by the Linux tray and the macOS
menu (served as JSON by the File Provider process's `menu` action):

- **Summary**: no domains → "No domains configured"; every domain unreachable → "Daemon not
  running"; nothing moving → "Paused" if all are paused, else "Idle"; otherwise
  "Uploading N · Downloading M" plus " · paused" when any domain is paused.
- **Icon**: all unreachable or no domains → error; all paused → paused; any transferring → sync;
  else idle.
- **Rows**: per domain a row opening its folder; up to 5 upload rows (the file's name, indented,
  not actionable) then "… and N more"; download rows revealing the file ("name — P%" from `bytes`
  of `size`, indented); a traffic line "X sent · Y to go" when non-zero (X: every domain's
  `traffic.upBytes`, Y: every domain's `pendingBytes`); a rate line "R/s · 2h 13m left" while
  uploading (R: every domain's `traffic.upRate`, the time Y / R; two largest non-zero units; none
  under a minute); a Stats submenu filled on
  open (placeholder "Reading…", never empty); "Hold changes", checked when all domains are paused,
  disabled when all are unreachable, whose action pauses or resumes every domain; on the Linux tray,
  quit, labelled "Quit tsync tray", which leaves the daemon running. The macOS menu has no quit row:
  the app carrying it also relays change signals ([file-provider §2](frontends/file-provider.md#2-processes-and-ownership)).
- **JSON**: `{icon?, tooltip, entries:[{separator} | {label, enabled, indent, checked?, submenu?,
  action: openFolder | reveal{domain, rel} | setPaused | stats | quit}]}`.

### 5.9 Config wizard (`tsync config --edit`)

- Edits the raw JSON so that nothing it does not ask about is lost. An existing file that is not
  valid JSON is refused (exit 1).
- New file: prompts for globals (client name, default the hostname; `maxUploads`; `maxChunkBuffers`,
  default `maxUploads`; `maxDownloads`; uplink settings; per-link ceilings for links some backend
  uses; TLS implementation when more than one is available), then a domain.
- Main loop: select by number; `[a]dd [e]dit [r]emove [g]lobals [w]rite [q]uit`. A domain prompts for
  its name, `versioning` (default true), `symlinks`, `readOnly`, sizes, `maxCache` (default 1 GiB),
  backends (type default `local`; field prompts from the driver's option spec; role default
  `replica` for a cloud store once a `main` exists, else `main`; optional filling of s3/gcs fields
  from a deployment's outputs, per [11 §11](11-infrastructure.md#11-outputs)), and frontends (from the frontend registry).
- Prompts: blank keeps the current value; required fields are asked again; secrets are read without
  echo; an answer a field's own check refuses (a size, a port, a choice) is said and asked again. A
  blank answer to a field with no value writes nothing when the parser applies that default itself,
  and writes the wizard's own defaults (`versioning`, `symlinks`, `maxCache`, a backend's `role`).
- On write: drop per-link settings no backend uses; validate with the parser's own rules
  ([05 §2](05-ops-config.md)) and refuse to write an invalid config (exit 1); write to a temporary
  file **created with mode 0600**, fsync, rename over the config, fsync the directory; tell the user
  to `tsync restart`.

---

## 6. Maintenance

What an owner runs unasked is a declared list, so it can be reported (`stats` lists it) and cannot
drift between hosts. Every host that owns a domain runs the same list, the Android app included.

| task | when | rule |
|---|---|---|
| local recovery, including the exact staged-orphan sweep and temporary files | at owner start | [04 §4.10](04-checkout-cache.md#410-owner-start-local-recovery) |
| temporary files | at start and daily | [04 §4.11](04-checkout-cache.md#411-periodic-maintenance) |
| chunk cache cap | after every upload and every `HOUSEKEEPING_INTERVAL` | [04 §4.11](04-checkout-cache.md#411-periodic-maintenance) |
| applied-log prune | daily | [wal-and-journal.md §4.8](algorithms/wal-and-journal.md#48-retention-horizon-bridging-and-rebuild) |
| removed-id records, export-record sweep | daily | [04 §4.11](04-checkout-cache.md#411-periodic-maintenance), [05 §4.4](05-ops-config.md) |
| log rescan and re-arming of parked records | every `HOUSEKEEPING_INTERVAL` | [durable-queue.md](algorithms/durable-queue.md#47-parking-and-retry-of-parked-records) |

- Each periodic task runs to completion before its next period starts; a failing task does not stop
  the others. `tsync cache --prune` runs the sweeps on demand (`prune`).
- While paused, what changes the domain's stores or applies peer work is held; local tasks run.

---

## 7. Concurrency and failure

- **Serialisation.** One owner per domain (§2.2); inside it, per-domain metadata and per-key content
  serialisation. Reads MAY run concurrently with each other and with mutations only where each
  read observes one consistent snapshot of what it reads (atomically replaced files, or a read under
  the same lock). A rewrite with preemptive threads MUST additionally make atomic every piece of
  shared in-process state that the owner's tasks update: the subscriber registry and its queues,
  the stop flag and hook table, debounce flags, the job registry, the recent-errors ring, counters
  and the status caches.
- **Durability.** Everything owed is on disk (WAL, staged tree, deferred logs, pause flag). Volatile:
  the job registry, status caches, event streams, the coalesced cursor bump (flushed by every
  drain).
- **Bounded stop.** `GRACE` drain, `REAP_MARGIN`, then SIGKILL; nothing is cancelled.
- **Failures in background tasks** are logged and never end a process. A dead event loop ends it with
  status 1 at once.
- **Every wait is bounded** ([failure-model.md §8](algorithms/failure-model.md#8-deadlines-and-bounded-waits-p7)).
- **Idempotence**: stop, `tsync stop` repeated, `pause` and `resume`, job-report finish, `full_resync` (a
  new generation each time).
- **Offline**: status reports stores unreachable or held without blocking; commands that need a
  store fail with the driver's sentence and exit 1.

---

## 8. Design rationale

- **One owner per domain**, not cross-process locks around each check-then-act: every local
  decision already has a lock inside one process; making the process unique is what makes those
  locks sufficient. A frontend that presents a domain runs inside its owner, so a local edit and a
  peer's change meet under one metadata lock.
- **The supervisor owns no domain state**: a crash or restart of one owner leaves the other domains
  untouched, and the supervisor never has to arbitrate between presenter and converger.
- **Commands are requests to the daemon**: the owner already holds the domain's mirror, queues, logs
  and locks and serializes every change to it, so an operator's command joins that one stream
  instead of racing it from another process. Taking ownership is only the fallback when the daemon
  is not running.
- **Submission instead of IPC for owed work** between processes that are not commands (a store
  server's copy jobs): a record created exclusively is already a durable request; the owner is poked
  but need not be up.
- **Only the owner publishes journal entries**: entry keys are minted by one process, the applied log
  has one writer, and a command never touches the mirror unless it is the owner.
- **Pause is persisted** because a user who holds changes before a flight expects them held after a
  reboot.
- **Bulk actions bounded by progress, with a liveness probe**, give every request a bound without
  cutting off legitimately long work.
- **Stop races, never cancels**: a cancelled job reads as a failure and degrades a queue. **Queues
  give way at a fraction of the grace** so the cursor bump of finished uploads still goes out.
  **Children are told at once** so nested processes stop within one grace. **A listener closes once,
  after the drain**, so status stays answerable.
- **References, not paths, on the wire** ([08 §2.2](08-frontends.md)).
- **Exit 0 on a missing config, 78 on an invalid one**: service managers must not respawn-loop a fresh
  install, and must not hide a broken config.
- **The wizard validates with the parser** so it cannot write a config the daemon refuses.

---

## 9. Conformance

An implementation MUST exhibit:

- **Ownership.** For any domain, at most one process holds its ownership lock; a second owner start
  exits `OWNER_HELD` without touching local state; killing the holder with SIGKILL frees the lock
  for the next process. A local edit made through the mount and a peer's delete of the same file
  applied concurrently end as the conflict table says (the local edit publishes later), never with
  the edit discarded.
- **Start on existing state.** An owner starting on existing local state (owed WAL records, staged
  edits, a backlog of deferred jobs, files in log directories that are not records, a leftover socket
  file, no lock or pause file) converts nothing: the domain comes up owned and not paused, every owed
  record and deferred job is adopted and runs, and nothing is lost or rewritten except by the owner's
  ordinary work.
- **Commands run in the owner.** `tsync sync` with a running owner runs the resync in the owner and
  prints its count; with no owner it takes ownership and releases it at exit; with a non-serving
  holder it refuses with `busy`. An import sent to a running owner runs there and appears in the
  mount as it publishes; killing the owner at any point leaves no manifest on the store unannounced
  after its next start. With `-v` the command's stderr shows the job's narration; Ctrl-C cancels the
  job at its next unit boundary, and closing the client without it lets the job finish.
- **Pause.** While paused: nothing is published, no peer entry is applied, no deferred copy runs,
  and store/publish commands refuse; local edits are accepted and held. The pause survives a
  restart. A drain overrides pause: it completes while paused.
- **Queue accounting.** Pending uploads count files; in-flight entries are listed first in, first
  out; bytes owed are whole-file bytes, in-flight included; a folder rename owes 0 bytes.
- **Stop.** A stop without a process stop drains everything; after a process stop, a queue returns
  within a bound, leaving its records on disk for the next start. A drain that finishes is waited
  for; one that does not is left at the grace and not cancelled. A server removes its socket and
  returns within one second of being told to stop. Children that stop on SIGTERM are reaped at once; one ignoring it is killed after
  `GRACE + REAP_MARGIN`; a stop reaches all children before any reaping. A stop publishes the cursor
  bump of finished uploads even while another upload holds the drain past the grace. The File
  Provider process's stop completes within the grace with a store unreachable.
- **`tsync stop`** prints `Stopped tsync.` only after the supervisor socket is gone; `tsync is not
  running.` when nothing answered; a wedged socket is reported and exits 1 within the reply deadline.
- **Deadlines.** Every CLI command that talks to a daemon returns within its deadlines when the
  daemon accepts connections but never replies. `ping` answers while a bulk action is in progress
  and while every store is unreachable.
- **IPC answers.** Invalid JSON is answered exactly `{"ok":false,"code":"invalid","error":"invalid
  JSON"}`; an unknown action is refused naming it; `stop` is acknowledged and requests the stop
  exactly once.
- **Servers.** A server stops when asked over its socket, when its owner's stop resolves, or both;
  its socket file is gone afterwards; no failure escapes. A connection serves several requests.
  Subscription: subscribed, counted, topics isolated, events in order, a departed subscriber
  dropped, publishing to nobody returns 0. A connection from another user is refused.
- **Stop signal.** A stop-aware sleep runs its length without a stop, ends at once on stop, and one
  begun after a stop returns at once; hooks run once, not after unregistering; late hooks run at
  once; a retry ladder is not climbed past a stop and counts no failure. A process stop takes no more
  queue work and leaves all jobs on disk; the next start runs them.
- **Job reports.** A long command reports itself as a job, including when no supervisor listens; its
  progress carries total, skipped, done, handled and remaining, and an ETA only between the first
  settled item and completion. A dead pid's running job disappears; a finished or failed one stays;
  a re-report replaces the row.
- **Status.** The report carries the fields of §5.5 with their values (the text rendering's layout
  and wording are not part of the contract, except that a zero-valued qualifier is omitted); secrets
  are masked `***`; this client's own journal entries are never counted behind; processes and jobs
  are deduplicated; warnings are folded by (level, message). The collector's request shape to a
  process is `{"action":"stats","domain":…,"arg":"frontend,…"}`; an unbound socket becomes
  `{reachable:false, socketPath, error}` promptly; over a large journal, repeated reports within the
  window list the store once; a held-down member is not probed and is reported as held; totals never
  delay a reply; a domain in `hold` reports its reason and mark age.
- **Menu.** Rendering is a pure function of the status replies (icons, tooltip, rows, "… and N
  more", checkbox state and enablement).
- **CLI parsing.** Shell completion offers configured domains and `DOMAIN:/` items that exist,
  folders ending in `/`, and every offer is accepted by the command; `ls` shows availability, name
  and size per file and folders with a trailing `/`; a path command finds its domain's owner socket; a path under no domain is refused with exit 1 by `ls`,
  `cache --evict` and `versions`. `tsync export` accepts and refuses the path spellings of
  [05 §4.4](05-ops-config.md).

---

## 10. Parameters

| name | value | rule |
|---|---|---|
| `GRACE` | 10 s | a stop's drain budget |
| `QUEUE_GRACE_FRACTION` | 0.8 | < 1, so the cursor flush runs inside the grace |
| `REAP_MARGIN` | 2 s | |
| `REAP_POLL` | 50 ms | |
| `STOP_WAIT` | `GRACE + REAP_MARGIN + REQUEST_DEADLINE` | < the service manager's stop timeout |
| `RESTART_BACKOFF_MIN` / `MAX` / `RESTART_STABLE` | 1 s / 60 s / 60 s | |
| `OWNER_HELD` exit status | 75 | |
| `JOB_REPORT_INTERVAL` / `JOB_STALE_MIN` / `JOB_KEEP` | 10 s / 45 s / 300 s | |
| `STORE_STATE_WINDOW` / `LISTING_GRACE` | 5 s / 2 s | |
| `JOURNAL_WINDOW` | 60 s | a member's journal listing in status |
| status listing timeout | 30 s | journal and corruption listings |
| corrupted sample | 1000 (+1 to detect truncation) | |
| `HOUSEKEEPING_INTERVAL` | 60 s | |
| `FD_SOFT_TARGET` | 65536 | |

Request deadlines: [failure-model.md §8.3](algorithms/failure-model.md#83-parameters). IPC line,
connection and subscriber bounds: [01 §15](01-core.md#15-parameters).
