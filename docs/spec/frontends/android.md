# The Android frontend

Scope: the core side of tsync on Android: the `android` frontend, the owner embedded in a host
process, how its lazy tree stays fresh and keeps answering while the store does not, the bridge the
host calls, and the desktop command group. The application built on it (DocumentsProvider, user
interface, share target, camera backup, packaging) is [android-app.md](android-app.md).

Rules shared by every frontend are owned elsewhere and only referenced here:
- the frontend contract, item references, the item row, the actions and the shared request handler:
  [the frontend contract](../08-frontends.md);
- the process model, the ownership lock and one-shot commands: [daemon and CLI](../07-daemon-cli.md);
- the lazy tree and what a pull does: [04 §3.5](../04-checkout-cache.md#35-the-published-tree-full-and-lazy);
- durability of local writes: [durable queue](../algorithms/durable-queue.md);
- failure kinds, codes and deadlines: [failure model](../algorithms/failure-model.md);
- trust boundaries, TLS and secrets: [security model](../algorithms/security-model.md);
- conflicts: [conflict resolution](../algorithms/conflict-resolution.md).

---

## 1. Problem

Android kills and freezes processes at will, caps foreground-service time, and reaps executed
children. A long-lived daemon is the wrong shape there. The core is therefore a library the host
process loads, and three things follow:

1. **The host process is the owner.** There is no supervisor and no socket; requests arrive by direct
   call from threads the platform owns.
2. **No replica.** A process that may die at any moment cannot keep a full mirror converged:
   rebuilding one leaves every reference unresolvable until it ends. The owner reads a folder from
   the store when it is asked for (the lazy tree) and applies no journal entry.
3. **A phone is often offline, or on a link that does not answer.** What was already seen and what is
   already cached MUST keep working without the store, and say that it may be out of date.

## 2. Ownership and process model

- **The host process owns its domain.** At boot it takes the domain's ownership lock
  ([07 §2.3](../07-daemon-cli.md#23-the-ownership-lock)) with role `app` and no socket, and holds it
  for the life of the process; process death releases it. Only this process changes the domain's
  local state.
- There is no stop and no drain. Process death is a crash-stop; the next boot reconciles
  ([07 §3.6](../07-daemon-cli.md#36-embedded-host-android)).
- One booted domain per process: the one the host names, or the only one the config names.
- The frontend's descriptor ([08 §2.1](../08-frontends.md#21-frontend-descriptor)): presenting,
  per-domain, serving `Commands` (`tsync start` refuses it), tree `Pulled` (`tsync sync` refuses it),
  availability as the core computes it.
- The desktop command group (§7) is owner-class
  ([07 §2.5](../07-daemon-cli.md#25-one-shot-commands)): each invocation takes ownership for its own
  duration. An `app` holder serves no socket, so a command meeting one is refused, naming the holder.

## 3. What the owner runs

### 3.1 Boot

Boot is idempotent within a process; concurrent callers wait for the first.

1. Install the log sink and the notice sink (§4), before anything that can fail.
2. Load and validate the config; apply its TLS settings; take the ownership lock; build the domain
   over the lazy tree.
3. Start the scheduler on a thread of its own
   ([07 §3.7](../07-daemon-cli.md#37-event-loop-hosting)), ensure the mirror's root, and report
   ready. Callers wait for this step only: it reads no store.
4. In the background: start the upload and metadata queues and reconcile
   ([wal-and-journal.md](../algorithms/wal-and-journal.md)); resume deferred replica and backfill
   work left by earlier processes ([replication.md](../algorithms/replication.md)); start the
   maintenance schedule, the same list every owner runs
   ([07 §6](../07-daemon-cli.md#6-maintenance)).

- A failure in steps 1–3 is answered to the caller as text, the lock released, and a later boot may
  succeed. A lock held by another process is such a failure, naming the holder.
- A config changed after boot is not picked up: the process serves the config it booted with until
  it dies.
- If the scheduler itself dies the process exits
  ([07 §3.7](../07-daemon-cli.md#37-event-loop-hosting)); the host is restarted by the platform at
  its next use, and boots again.

### 3.2 Freshness without a journal poller

The owner runs no journal poller and applies no peer entry. Its view of what peers did comes from
**pulls**: a pull reads one folder's children from the store and replaces the mirror's view of that
folder, overlaid with this client's owed work, as the lazy tree specifies
([04 §3.5](../04-checkout-cache.md#35-the-published-tree-full-and-lazy)). A completed pull stamps the
folder ([04 §2.3](../04-checkout-cache.md#23-mirror-entries-and-markers)); a folder is **fresh** when
this process completed a pull of it less than `pull_freshness` ago, measured on the monotonic clock.

**When the owner pulls.**
1. A child listing (`list_dir`) pulls the folder first unless it is fresh. A caller MAY say
   `"pull":"now"` (pull even when fresh: a user's refresh gesture) or `"pull":"never"` (answer the
   mirror).
2. A mutation that names a child by name (`create`, `mkdir`, `write` by parent and name, `symlink`,
   the destination of a `rename`) pulls the destination folder first unless it is fresh, so that an
   existence check sees peers' entries.
3. Opening a file (the bridge's `open`, `ensure_cached`, `fetch_range`) reads the file's current
   manifest from the store and updates the mirror's entry; if the store no longer has it, the entry
   is removed and the answer is `not_found`.
4. `restore` of a folder pulls each folder of the subtree as it walks, so the subtree restored is the
   one the store holds. `evict` walks the mirror only.

Concurrent pulls of one folder share one store read. `stat` never pulls: it answers from the mirror.

**The listing says how fresh it is.** On a pulled tree a `list_dir` reply carries `pulledAt` (epoch
seconds of the pull its rows reflect; absent for a folder never pulled) and `outdated: true` when the
rows do not come from a pull made for this request or within `pull_freshness`.

**Notices.** After a pull that changed a folder's children, and after every mutation it performs, the
owner sends the host a `changed` notice naming each folder whose children changed (§4.2). The host
tells the platform; the owner does not track what the platform displays.

Conflicts between this client's unpublished work and peers' changes are settled when the owner
publishes, as the publish side of [conflict resolution](../algorithms/conflict-resolution.md)
specifies.

### 3.3 Working without the store

Offline is normal. A request MUST NOT wait on a silent store for longer than the patience below
when the mirror or the cache can answer it.

**Listings: answer the last view, then catch up.**
- A folder pulled less than `view_max_age` ago, by its pull marker: the listing waits for its pull at most
  `pull_patience`. If the pull has not completed by then, or the store's health breaker
  ([01](../01-core.md)) is open, it answers the mirror's view at once with `outdated: true` and
  `pulledAt`. The pull continues in the background; when it completes with different children the
  owner sends a `changed` notice, and the next listing is fresh.
- A folder never pulled, or whose view is older than `view_max_age`, has nothing to fall back on:
  the listing waits for the pull and fails with the pull's code (`unreachable` when the store is
  silent). A failed listing is never an empty folder. An expired view is not deleted: the next
  completed pull replaces it.
- `view_max_age` MUST be at least the default pin lifetime
  ([08 §3.4](../08-frontends.md#34-evict-and-restore)): a file made available offline stays
  reachable by name for as long as its pin holds its bytes. The view's age is carried in `pulledAt`
  for the host to show.

**Opens: serve the version known here.**
- The manifest read of rule 3 waits at most `pull_patience`, and not at all while the breaker is
  open. Without an answer the open serves the mirror's version.
- Bytes come from the chunk cache. A read that needs a chunk the cache lacks waits for the store as
  any read does and fails with DEADLINE ([failure-model.md](../algorithms/failure-model.md)) when it
  stays silent. A pinned file ([08 §3.4](../08-frontends.md#34-evict-and-restore)) is read whole
  without the store.

**Mutations: accepted, published later.**
- The destination pull of rule 2 waits at most `pull_patience`. Without it the mutation proceeds on
  the mirror's view, is recorded in the WAL and answered; the queues publish it when the store
  returns, across restarts.
- An exclusive creation checked against an out-of-date view may meet a name a peer took meanwhile.
  It is settled at publish as a conflict, and nothing is overwritten.
- `write` with `await` answers once the upload has published or has started failing; `isUploaded`
  in the reply's item says which.

**What does need the store.** `share`, `restore` of bytes not yet cached, and the first listing of a
folder answer `unreachable`. `status` never touches the store.

**Recovery.** When a store request succeeds after the owner answered `unreachable`, or answered a
listing `outdated` because the breaker was open, the owner sends the `recovered` notice. A host that
showed an offline state clears it and re-lists what it displays.

### 3.4 What is left out

- The journal poller and entry application, and therefore full resync and the change feed
  (`changes_since`, `list_all`, `cursor`): a pulled tree has no replica to rebuild or to diff.
- Subscriptions: there is no socket. The notice sink carries the same events (§4.2).
- Symlinks: the host's config sets `symlinks: "skip"`; the platform's document model has none.
- Ranged writes and `close`: the only write is whole-body adoption of a staged file.

## 4. Host environment

### 4.1 What the host provides

Before the core initialises:

1. **Home**: a private directory of the host. The config and cache locations derive from it, as on
   Linux with no XDG overrides.
2. **Trust store**: the path of a PEM bundle of certificate authorities. The core's TLS client uses
   it for every connection ([security-model.md §9](../algorithms/security-model.md#9-tls)). Boot
   fails, naming the trust store, when the file is missing or holds no certificate.
3. **A log sink** `(level ∈ {debug, info, warn, error}, message)`.
4. **A notice sink** (§4.2).
5. The name of the domain to serve (empty = the only one the config names).
6. **Transfer roots** ([security-model.md §7.3](../algorithms/security-model.md#73-paths-passed-over-ipc-confused-deputy)):
   one directory under home that every `staging` and `dest` path MUST lie in.

**Cleartext.** The core's network traffic does not go through the platform's network stack, so the
platform's cleartext switch does not reach it. On this host the core MUST refuse to connect to a
cleartext URL whose host is not a loopback address, even when a config names one, and
`check_config` MUST refuse such a config.

### 4.2 Notices

The one call from the core to the host other than the log sink. A notice is one JSON object, the
event a subscriber would receive ([08 §3.8](../08-frontends.md#38-events)):

- `{"event":"changed","domain":D,"id":N,"refs":["root","d:<id>",…]}`: the children of these folders
  changed (§3.2), or an item in them changed state (an upload published, a pin was set or dropped).
- `{"event":"recovered","domain":D,"id":N}` (§3.3).

Notices are hints: a lost one costs promptness, never correctness. The sink is called on a thread of
the core's; it MUST return quickly and MUST NOT call back into the bridge from inside the call.

### 4.3 Threads

The host calls the core from threads it owns (binder threads, descriptor callback threads, worker
threads). The core MUST accept calls from threads it did not create, MUST block only the calling
thread, and MUST apply the per-domain serialisation of
[08 §3.5](../08-frontends.md#35-rules-the-handler-enforces) whatever thread a call arrives on. Every
piece of state a call touches, the handle table included, is touched only on the scheduler.

## 5. The bridge

All text crosses as **UTF-8 byte arrays**, never platform strings: names may hold characters outside
the Basic Multilingual Plane, which the JVM's native string encoding cannot carry.

| Operation | In | Out | Semantics |
|---|---|---|---|
| `check_config(domain)` | domain | `""` or error text | Loads and validates the config and selects the domain, starting nothing and taking no lock. Callable before or after boot. |
| `boot(domain)` | domain | `""` or error text | §3.1. |
| `request(json)` | request | reply | One request, one reply, through the shared handler ([08 §3.3](../08-frontends.md#33-actions)). |
| `status()` | — | text | The same report as desktop `tsync status` for this domain, with `frontend: android`. |
| `open(ref)` | reference | handle > 0, or −errno | Resolves the file's current version (§3.2 rule 3, §3.3) and pins it to a new handle. |
| `size(handle)` | handle | size, or −errno | The size of the handle's version. |
| `read(handle, offset, length, dest)` | | bytes served, or −errno | Bytes `[offset, offset+n)` of the handle's version. Short only at end of content; 0 past it. Each handle is its own read stream for read-ahead. |
| `close(handle)` | handle | 0 | Forgets the handle. Idempotent. |

- **A handle serves one version.** Size and bytes both come from the version resolved at open, never
  from a later one. If that version's bytes become unavailable (a staged body replaced meanwhile),
  reads fail with EIO rather than mixing versions.
- **Errno**: ENOENT for a reference naming nothing; EBADF for an unknown or closed handle; EACCES;
  ENOSPC; EIO for anything else, a read deadline included.
- **Every entry is total.** Any failure becomes a reply, an error text or a −errno; nothing
  propagates into the host, which has no supervisor. A call before boot is such a failure. A request
  that is not JSON is answered `{"ok":false,"code":"invalid","error":"invalid JSON"}`; every failed
  request carries a code ([failure-model.md §7.2](../algorithms/failure-model.md#72-client-error-codes)).
- `busy` cannot be answered for want of an owner: the caller is the owner.

## 6. The handler on a pulled tree

The actions are [08 §3.3](../08-frontends.md#33-actions)'s. What differs here:

- `list_dir` takes `pull?` and answers `pulledAt?` and `outdated?` (§3.2).
- `changes_since`, `list_all`, `cursor`, `full_resync`, `sync` and `subscribe` are refused `invalid`,
  naming the pulled tree.
- `evict` and `restore` on a folder walk its subtree and answer counts, as
  [08 §3.4](../08-frontends.md#34-evict-and-restore) specifies, with the pulls of §3.2 rule 4.
- Hooks: `changed` and `on_upload_done` become `changed` notices; `reannounce` and `on_stop` do
  nothing.

## 7. The `tsync android` command group (desktop)

For shells and tests on a desktop build that includes the frontend. Arguments are positional; bad
usage exits 2. Each invocation follows the one-shot rule of §2, answers through the same handler and
bridge semantics, drains, and exits.

| Verb | Request or behaviour |
|---|---|
| `stat REF` | `stat` |
| `list REF [AFTER [LIMIT]]` | `list_dir` |
| `read REF DEST OFFSET LENGTH` | `fetch_range`: the range is written into DEST at the same offset, sparse elsewhere |
| `open REF` | the session below |
| `residency REF` | `{"ok":true,"cached":n,"total":m}`: chunks of REF on this machine |
| `fetch REF DEST` | `ensure_cached` |
| `write-whole PARENT NAME STAGING` | `write` with `await` |
| `create PARENT NAME`, `mkdir PARENT NAME` | `create`, `mkdir` |
| `delete REF`, `rmdir REF` | `delete`, `rmdir` |
| `rename SRC PARENT NAME` | `rename` |
| `share REF` | `share` |
| `request JSON` | the request, verbatim: the wire a host speaks |
| `status` | the status text |

Only a verb that sends a mutating action starts the queues and reconciles; the others only ensure
the mirror's root.

`open REF` session: first line `{"ok":true,"size":N}` or a refusal; then for each input line
`"OFFSET LENGTH"` (offset ≥ 0, length > 0) a line `{"ok":true,"length":n}` followed by exactly `n`
raw bytes; a malformed line is answered with an `invalid` refusal and the session continues; end of
input ends it. Framing is by count, never by delimiter.

## 8. Parameters

| Parameter | Recommended | Constraint |
|---|---|---|
| `pull_freshness` | 5 s | the window in which a folder is listed again without asking the store |
| `view_max_age` | 10 days | ≥ `DEFAULT_PIN_KEEP`; how old a view may be and still be answered while the store is silent |
| `pull_patience` | 2 s | < `REQUEST_DEADLINE`; how long an answer the mirror can give waits for the store |

## 9. Conformance

An implementation MUST exhibit these properties; [09-tests.md](../09-tests.md) says how they are
checked. Properties of the shared handler are [08](../08-frontends.md)'s.

**Ownership and boot**
- A second process cannot own the domain while a host does; a desktop command meeting an `app`
  holder is refused naming it, and otherwise owns the domain for its duration.
- Deferred replica or backfill work left by a killed process is completed after the next boot.
- Every bridge entry is total, before boot included; a non-JSON request is answered with the exact
  `invalid JSON` reply.
- Concurrent reads from foreign threads return exact bytes; a read after close is −EBADF; an open of
  an absent reference is −ENOENT; a handle keeps serving the version it opened after the file is
  rewritten.
- A cleartext backend URL to a non-loopback host is refused by `check_config` and by the core.

**Freshness**
- With the mirror wiped, listing root works without any sync and reads only root; descending reads
  only that folder.
- Two listings of a folder within `pull_freshness`, and every page of one paged listing, cost one
  store read; `"pull":"now"` costs one more.
- A file a peer deleted disappears from the next pull and from the mirror; a peer's new file appears;
  an open of a file a peer replaced serves the new version; an open of a file a peer deleted is
  `not_found`.
- A locally created, unpublished file survives a pull; a locally removed, unpublished file is not
  listed back; a folder with a metadata record that cannot be published is still refreshed from the
  store.
- A pull that changed a folder's children, and every mutation, sends a `changed` notice naming the
  folder.

**Without the store**
- With the store silent, a previously listed folder is answered within `pull_patience` with
  `outdated: true` and its `pulledAt`; with the breaker open it is answered without waiting; a
  never-listed folder, and one last pulled more than `view_max_age` ago, answers `unreachable`,
  never an empty listing.
- With the store silent, a cached file opens and reads; a pinned file reads whole; `create`,
  `mkdir`, `write`, `rename` and `delete` in a previously listed folder succeed and are published
  after the store returns, across a process kill.
- When the store returns, the host receives `recovered`, and a `changed` notice for each folder
  whose background pull found different children.
- An exclusive creation made offline onto a name a peer took meanwhile replaces nothing.

**Command group**
- Every verb is driven by a spawned process per call, and the registered verbs are exactly the ones
  tested.

## 10. Rationale (do not undo)

- **Linked core, not a daemon or a process per call.** Android reaped the daemon; per-call processes
  had no read-ahead state and could not be ordered against the upload queue.
- **Pulled tree.** A host without long-lived state cannot keep a replica: a resync wiped the mirror
  and left every document unresolvable until it ended.
- **Pulls overlaid with owed work, never skipped because of it.** Skipping froze a folder for as long
  as one record kept failing.
- **Answer the last view, flagged, rather than fail.** A listing that failed whenever the store was
  silent made cached and pinned files unreachable exactly when they mattered.
- **A view expires.** A listing weeks old shown as the folder's contents misleads more than it
  helps; the bound is the pin lifetime, so that it never strands a file made available offline.
- **Freshness is judged per process, on the monotonic clock.** A wall-clock stamp read after a clock
  jump would call an old view fresh.
- **Read-ahead keyed by handle, not by file.** A probe elsewhere in the file must not reset a
  sequential reader.
- **A handle is a version.** A handle that was a key served a rewritten file's new bytes under its
  old size.
- **Notices, not tracking.** The core does not know what the platform displays; the host does.

---

Implementation notes for this subsystem: [../ocaml/frontends/android.md](../ocaml/frontends/android.md).
