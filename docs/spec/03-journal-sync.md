# 03 — Multi-machine synchronisation (journal, sync, conflict resolution)

Scope: `lib/domain/journal/` (`journal.ml`, `applied_entries.ml`), `lib/domain/sync/`
(`replay.ml`, `sync_poller.ml`, `sync_queue.ml`, `meta_queue.ml`, `pause.ml`),
`lib/lwt/domain/sync/sync_lwt.ml`, plus the pieces they cannot be understood without:
the journal's backend half `lib/domain/remote/store/file_store/` (+ `lib/lwt/.../file_store_lwt.ml`),
the write-ahead log `lib/domain/checkout/wal/`, the conflict tables
`lib/domain/checkout/file/resolve.ml` and their fact-gathering/enactment in
`lib/domain/checkout/file/file.ml` (modules `Local.Peer_entry`, `Backend_half`, `Foreign`).
The WAL, durable queue, folder-id index and store layout are specified elsewhere; only their
contract as seen from sync is restated here.

This file is the language-neutral specification. The [OCaml notes](ocaml/03-journal-sync.md) hold OCaml-specific implementation
notes, each tied to the Part A section it implements.

---


## 1. Problem

tsync lets **one person** mount the same storage ("domain") from several machines
("clients"). Every client keeps a local *mirror* (a manifest per file, a `.tsync-dir`
marker per folder carrying a stable folder id) and writes locally first, publishing to the
shared backend later. Machines never talk to each other; the only shared medium is the
backend (object store, local disk, or another tsync over HTTP).

This subsystem answers:

1. **How a change leaves a machine** — every mutation is recorded durably before it
   happens (WAL), its backend half is published by a queue, and then announced as an
   immutable **journal entry** on the backend, after which a single **cursor** object is
   bumped so peers know to look.
2. **How peers discover changes** — a poller waits on the cursor (store-specific wait),
   lists the journal, and applies every entry it has not handled yet, in key order.
3. **How a peer's change is applied when it clashes with unpublished local work** — a pure
   decision table (`Resolve.Arrival`) plus a second table for when this client's own op is
   published to a store that moved on (`Resolve.Publish`).
4. **What "handled" means** — a local, positional, month-sharded **applied log** that
   doubles as the change feed for frontends (File Provider / Android `changes_since`).

It is a separate abstraction because it is the only place where two clients' histories
meet; everything else (mirror, chunk store, frontends) is single-client.

The guiding principle ("best-effort conflicts", the user's term) — see §7.1:

1. **Immediately**: resolve at the moment the peer's op arrives (or the moment a publish
   finds the store changed). Never defer an entry, never wait for more information.
2. **Soundly on both sides**: lose no data; every client ends with the same tree. Ops that
   do not clash simply converge by the simplest implementation.
3. **When in doubt, two conflicted copies**: `X (conflicted copy from <client>)`, never a
   merge or a guess at intent.
4. **Last resort, winner takes all**: two writes to the same already-published file; the
   loser survives only in version history.

The goal is explicitly *not* general concurrent correctness; the user mostly avoids
concurrency.

---

## 2. Concepts & data model

### 2.1 Client identity

| Item | Location | Format |
|---|---|---|
| Client uuid | `<data_dir>/client-uuid` | 32 lowercase hex chars (16 random bytes from `/dev/urandom`), first line. Shared by all domains of this client. |
| Client name | config `clientName` | Human name used in conflicted-copy names ("Client B", "laptop"). |
| Folder id leases | `<data_dir>/id-leases/<hex block>` | Empty files; creation (`O_CREAT|O_EXCL`) = ownership of a block of 1024 counter values. |

- **uuid creation is race-free across processes**: write random token to
  `client-uuid.<pid>.tmp`, `link()` it to `client-uuid`; `EEXIST` means another process won,
  then read the winner's. Memoised per data dir in-process (`journal.ml:29-55`).
- **Folder id** = `<first 12 hex of uuid>-<counter in lowercase hex>`, e.g.
  `3f9a0c1b2d4e-40a`. Counter = `block*1024 + next`. A process leases the next free block
  (`highest existing + 1`, retrying upward on `EEXIST`), keyed by pid so a forked child
  leases its own. Never waits, never contacts the store; unique across clients by the uuid
  prefix, across processes by the lease (`journal.ml:57-119`). Lease files are never
  removed (ponytail).

### 2.2 Entry key — the name of one unit of work

`Entry_key.t = { ms : int64; client_uuid : string }`.

- String form: `%013Ld-%s` → `1788134400000-3f9a0c1b2d4e5f60718293a4b5c6d7e8`.
  13-digit zero-padded ms so lexicographic = chronological.
- Minted at the **start** of the work (`Unix.gettimeofday` in ms), bumped to `last+1` if
  not strictly greater than the last one minted by this process (monotonic *per process*
  only; two processes sharing a uuid may collide within one ms — accepted, ponytail).
- The same key names the work for its whole life: WAL record id → published journal object
  → cursor body → applied-log line → change-feed anchor. It is abstract precisely because
  three string spellings (bare, prefixed, month-sharded) used to coexist and two readers
  compared the wrong ones (`journal.mli:22-26`).
- **Parser** `of_string`: takes the last `/` segment (so listing keys and paths are
  accepted), requires exactly 13 digits then `-` then a non-empty uuid; returns `None`
  otherwise (so a month directory `2026-08` is never an entry).
- **Order** `compare`: by `ms`, ties by uuid string (total order only; same-ms entries from
  two clients have no true order).
- `relative_path` → `YYYY-MM/<key>` using **UTC month of the key's ms**.
- `cannot_bridge anchor keys` (keys ascending): `true` if `keys = []`, else
  `oldest.ms > anchor.ms`. An empty journal is treated as "pruned" on purpose (a needless
  resync is cheaper than silently skipping pruned ops).

### 2.3 Journal op (the wire vocabulary between clients)

```
op = Put    of rel_path * size:int64
   | Delete of rel_path
   | Mkdir  of rel_path * folder_id option
   | Rmdir  of rel_path * folder_id option
   | Rename of { dst; src; size : int64 option; is_dir : bool; id : folder_id option }
```

`rel_path` is domain-relative, `/`-separated, no leading slash (`photos/one.jpg`; root is
`""`). Directory ops carry the folder's stable id because applying a removal destroys the
local marker it could otherwise be read from. `id = None` for legacy entries or when the
writer had no id.

JSON encoding (one object per op; `id` and `size` **omitted** rather than null so older
readers see what they always saw):

```json
{"op":"put","key":"photos/one.jpg","size":1024}
{"op":"delete","key":"photos/two.jpg"}
{"op":"mkdir","key":"photos","id":"3f9a0c1b2d4e-40a"}
{"op":"rmdir","key":"photos","id":"3f9a0c1b2d4e-40a"}
{"op":"rename","key":"photos/two.jpg","src":"photos/one.jpg","is_dir":false,"size":1024}
{"op":"rename","key":"pics","src":"photos","is_dir":true,"id":"3f9a0c1b2d4e-40a"}
```

Decoding is total: an unknown `op`, missing field or bad JSON yields `None` and the op is
skipped (forward compatibility: a newer client may write ops this one does not know).
`is_dir` absent → `false`. `keys_of_op` = `[key]`, or `[dst; src]` for a rename (a reader
deciding whether an op concerns it must test both).

### 2.4 Published journal entry (backend)

- **Key**: `tsync/<domain>/journal/<YYYY-MM>/<entry key>`
  e.g. `tsync/photos/journal/2026-09/1788134400000-3f9a…e8`.
  Month directory keeps listings bounded; both levels sort chronologically.
- **Body**: NDJSON — each op's JSON on its own line, `\n`-joined, trailing `\n`. Blank or
  unparsable lines skipped on read.
- Immutable once written; written with a plain `put`. One entry = one WAL record's ops
  (typically one op; imports batch many; a rebuild never publishes).
- Only `File_store.journal_key` turns an entry key into a backend key (prefix +
  `relative_path`); concatenating prefix + bare key "silently misses".

### 2.5 Cursor (backend)

- **Key**: `tsync/<domain>/cursor`. **Body**: one entry key string (the newest this
  writer published), e.g. `1788134400001-3f9a…e8`.
- A **hint, not a truth**: last-writer-wins among clients, may move "backwards" relative to
  another client's newer bump, may be lost (debounced timer, crash). Correctness never
  depends on it; it only gates when a peer bothers to list the journal.
- Replica backends carry journal and cursor; backfill members carry neither (see
  DOCUMENTATION.md §roles).

### 2.6 Last-sync mark (local)

`<data_dir>/last-sync-<domain>`: one entry key line. Written through
`<file>.<pid>.tmp` + rename (atomic; a crash never leaves an empty file that reads "never
synced"). Moved **forward only** during apply. Its only remaining uses: (a) `None` ⇒ "never
synced", which disables the dedupe horizon; (b) `tsync sync` compares it against the
journal with `cannot_bridge` to decide on a full rebuild. It is **not** used as a "list
since" cursor any more (§7.3).

### 2.7 Applied log (local) — `Applied_entries`

Directory `<cache_root>/<domain>/applied/`, files `YYYY-MM.log` where the month is the
**UTC month in which the entry was handled** (not the key's month).

Record format, newline-*led* (not terminated):

```
\n<entry key>\t<JSON array of ops>
```
e.g. `\n1788134400001-aaaaaaaaaaaaaaaa\t[{"op":"put","key":"photos/one.jpg","size":1024}]`

- Appended with `O_APPEND|O_CREAT`, mode 0600, no lock. Leading newline means a torn
  record is closed by the next append and only the torn record is lost; readers drop
  lines that do not parse (no tab, bad key, non-array JSON).
- Contains **both** this client's published entries and peers' applied entries, plus
  rebuild findings (`note_local`, fresh key, ops = the diff a rebuild made) and
  `mark_handled` entries (ops = `[]`).
- Order of lines = order handled = the feed's order. An anchor is a **position** (the line
  whose key equals it), not a time.
- Retention: `keep_days = 30`; maintenance prunes daily (`applied_prune_interval =
  86400 s`) with `keep_bytes = 64 MiB`: whole shards dropped if mtime older than 30 days,
  or walking newest→oldest, if cumulative size would exceed 64 MiB.

### 2.8 WAL record (local, owned by `Wal`; restated for sync)

`<data_dir>/journal-pending/<domain>/<entry key>` (file name = entry key; atomic write).
Body JSON:

```json
{"state":"prepared","attempts":2,"ops":[{"op":"mkdir","key":"d","id":"3f9a0c1b2d4e-7"}],
 "lastError":{"kind":"permanent","detail":"…"}}
```

States: `intent` (recorded, nothing done) → `prepared` (local half done / data staged,
backend half owed) → `executed` (bytes/marker on backend, entry not yet published) →
*file deleted* (no "committed" state). Unknown state reads as `intent` (safe: reconcile
re-derives). A legacy body with no envelope (NDJSON ops) reads as `intent`. `list()`
returns only records whose key's uuid is this client's, sorted by `Entry_key.compare`.
A record is **metadata** iff it has ≥1 op and no `Put`.

### 2.9 Conflicted-copy naming

`conflict_key ~n key` (`file.ml:409`):

- File `report.pdf` → `report (conflicted copy from <client_name>).pdf`; the extension is
  everything from the **last** `.` of the leaf.
- Folder `v1.2` → `v1.2 (conflicted copy from <client_name>)` (no extension split; stays a
  folder).
- n ≥ 2 → `(conflicted copy N from <client_name>)`.
- Same parent as the original. `aside_name` picks the smallest n whose candidate is absent
  from the mirror **and** has no staged file (the mirror does not show staged files).
- The client name is always **the client doing the moving aside**, i.e. the one whose
  work lost the name (the one that publishes second). Both machines then converge on that
  name because the move is published as a rename (or as the upload of the renamed file).

### 2.10 In-memory state (per process)

| State | Scope | Purpose |
|---|---|---|
| `handled` hash set of entry-key strings | per `Replay.Make` instance, loaded once from `Applied_entries.keys` | dedupe |
| `stepped_aside : domain → (key → reason)` | per domain, process-global | peer entries that failed on our account |
| cursor debouncer `{pending; last_published; timer_armed; publish_lock}` | keyed by cursor object key, process-global (one per object however many components use the store) | coalescing bumps |
| poller `last_version`, `last_swept` | per poller instance | gating |
| meta queue `parked` set | per queue | `degraded()` reporting |

---

## 3. Interface

### 3.1 Journal vocabulary (pure + identity)

```
type op, rename_op                                 (§2.3)
module Entry_key : of_string, to_string, timestamp_ms, client_uuid, compare,
                   cannot_bridge, relative_path
to_json : op -> json ; of_json : json -> op option
encode : op list -> string ; decode : string -> op list      (NDJSON, lossy-tolerant)
keys_of_op, keys_of_ops
per data dir: client_uuid () ; entry_key () ; folder_id ()   (synchronous, local only, never block on I/O beyond local files)
```

### 3.2 Applied log

```
keep_days : int = 30
note   : ?now -> cache_root -> domain -> Entry_key -> op list -> unit       (append)
since  : cache_root -> domain -> ?since:Entry_key -> limit -> page option
         page = { entries : (key * op list) list (oldest first, ≤ limit); more : bool }
         None  ⇔ anchor given but not found in any kept shard (⇒ reader must relist)
head   : … -> Entry_key option      (last line of newest shard; reads 8 KiB tail, whole
                                     shard if the tail yields nothing)
keys   : … -> Entry_key list        (every kept key)
prune  : … -> keep_days -> keep_bytes -> (shards_dropped, bytes_dropped)
```

`since` with an anchor reads shards newest-first until it finds the anchor's line, so cost
is proportional to what follows the anchor. Without an anchor it returns everything kept.

### 3.3 Journal store — the journal's backend seam (`file_store_intf.ml`)

```
write_journal_entry      : ?entry_key -> op list -> Entry_key io   (mints if absent)
write_journal_entry_body : ?entry_key -> bytes   -> Entry_key io   (pre-encoded; import)
bump_cursor   : Entry_key -> unit io   (may return before the write lands; coalesced)
note_cursor   : Entry_key -> unit      (never publishes inline; arms timer)
flush_cursor  : unit -> unit io        (publish pending now; swallows backend errors)
fetch_cursor  : unit -> Entry_key option io
wait_cursor_change : Entry_key option -> unit io    (store-paced hint; see §4.6)
read_last_sync_key / write_last_sync_key            (local mark, §2.6)
list_journal_keys : ?start_after -> unit -> Entry_key list io   (sorted by compare;
                    unparsable names skipped; start_after exclusive)
get_journal_entry : Entry_key -> op list option io  (ANY error ⇒ None)
journal_entry_published : Entry_key -> bool io      (HEAD)
rename_file, head_manifest_opt                       (manifest helpers, not journal)
```

Invariant a caller must keep: every path that bumps must be followed by a `flush_cursor`
before process exit, or the last bump of a run is lost (peers only find the entry by the
60 s sweep).

The host binding of the journal store (`file_store_lwt.ml`) wraps `write_journal_entry*` so that **recording in
the applied log and announcing** happen for every publisher (five callers: upload queue,
metadata queue, reconcile, import, revert…):

```
write_journal_entry ?k ops = k := k or mint;
                             Applied_entries.note k ops;   (* BEFORE publishing *)
                             backend put;
                             Change_notice.send each keys_of_ops to own socket
note_applied k ops  = Applied_entries.note
applied_keys ()     = Applied_entries.keys
note_local ops      = note_applied (fresh key) ops; announce ops   (rebuild findings)
```

### 3.4 Replay — everything that reads a journal (`replay_intf.ml`)

```
reconcile     : unit -> unit io   (startup only; finish/discard own WAL records, adopt
                                   unrecorded staged data)
apply_foreign : on_changed:(string -> unit) -> unit -> int io   (returns #entries applied)
mark_handled  : Entry_key list -> unit io   (rebuild: remember as handled, ops [])
unapplied     : unit -> (Entry_key * reason) list   (stepped-aside peer entries)
```

Replay is parameterised by: the concurrency runtime, a bounded-concurrency helper, the
journal store (3.3 plus `note_applied`, `applied_keys`, `note_local`), the WAL, the staged
manifest store, the domain config, and the domain's file operations. The file operations
provide what replay calls back: `apply_foreign_ops`, `apply_delete`, `mkdir`,
`rmdir`, `rename`, `redo_local`, `resume_put`, `resume_meta`, `queue_put`.

### 3.5 Poller

```
sync_once : on_changed -> unit -> int io
set_sweep_interval : float -> unit          (default 60 s; tests shorten)
start : ?paused:(unit -> bool) -> on_changed -> unit -> unit   (detached loop)
```

### 3.6 Outbound queues

- `Sync_queue.S` (uploads, keyed pool): `pending, uploading, pending_bytes,
  completed_count, set_paused, paused, start ~on_upload_done, drain, wait_uploaded key`.
- `Meta_queue.S` (metadata backend halves, ordered, one worker): `pending` (queued +
  in-flight), `degraded`, `set_paused`, `start`, `rearm` (re-adopt `prepared` metadata
  records not currently queued), `drain`.
- Pause: built over the two queues' `set_paused`; one switch `set held` pauses both queues; `held()` is
  passed to the poller as `paused`. Reads are never held.

### 3.7 Conflict tables — pure functions, the policy seam

```
Arrival.decide : facts -> Skip(reason) | Apply(ordered action list)
Publish.decide : facts -> { actions : action list; ending }
clashed, facts_to_string, decision_to_string
```

Full tables in §4.4 / §4.5. `tests/unit/resolve` prints every combination; a changed row
is a change of policy.

---

## 4. Behaviour / algorithms

### 4.1 Outbound: a local mutation's life

Every local mutation (frontend call) runs under the domain's **metadata lock** and never
touches the network:

1. Mint entry key `k`.
2. Metadata op (`delete`, `mkdir`, `rmdir`, `rename`): `W.record k ops` (state `intent`),
   do the local half (mirror change, folder id write, `rename_local` moving staged uploads),
   then either
   - local half answers `Nothing` (e.g. renaming a never-published staged file: its upload
     under the new name is all it owes) → `W.complete k`;
   - else `hand_over meta_owed k ops` (rewrite as `prepared`, signal the metadata queue).
   A failure in the local half deletes the intent and re-raises.
3. File content (`close` of a staged file, `symlink`): record `prepared` with
   `[Put(rel, size)]` and signal the upload queue.

Specific local-half rules relevant to sync:
- `mkdir` mints the folder id **locally** (or reuses one already held at that path); it is
  final for life. Refused before anything changes if the parent has no id ("run tsync sync").
- `rmdir`/folder `rename` read the id first (the marker is destroyed by the op) and
  refuse if the parent's marker key can't be named.
- `rename` of a file computes `size` from staged manifest if any, else published manifest;
  cancels any in-flight upload of `dst`.
- `rename_local` cancels uploads under the source (file or whole staged subtree) and
  re-queues them under the new path **after** the rename is recorded, so peers replay the
  move before the puts.

**Upload queue** (`sync_queue.ml`): keyed pool, `workers = max 1 max_uploads`, one job per
file (slot key = logical key string; a newer post for the same file cancels and replaces
the running one). Per job:

```
if cancelled → complete record
upload bytes (F.upload: staged → chunk upload + manifest; symlink manifest; else ENOENT)
if cancelled → complete record
W.discharge: advance Executed; write_journal_entry k ops; note_cursor k; complete k
on Retry.Cancelled | ENOENT → complete (nothing owed any more)
on Shutdown.Stopping → re-raise (record stays for next start)
on other exn → W.note_failure k kind reason; re-raise (queue retries: transient requeued at
               back; permanent poison = Stop, record left on disk)
```

**Metadata queue** (`meta_queue.ml`): **ordered**, one worker, jobs in recorded order;
transient failures retried at the head (so nothing overtakes). Classification is
`Retry.classify_in_order`: only a `Retry.Failed{kind}` raised by the retry loop around a
request keeps its kind (a link problem); **anything else is `Permanent`** (this client's
own account). Permanent ⇒ poison `Stop`: record stays, job leaves the queue, id added to
`parked` (`degraded()` true) — later ops publish past it; `rearm()` (retry sweep) re-adopts
every `prepared` metadata record. Per job:

```
current := W.find k   (re-read: a conflict settled since may have rewritten ops, e.g.
                       Retarget_our_rename)
ops' := F.backend_ops current.ops        (runs Resolve.Publish per op, §4.5)
if ops' = [] → complete k                 (store owed no word of it)
else W.discharge ~publish:write_journal_entry ~cursor:note_cursor k ops'
Retry.Cancelled (Superseded) → complete k
```

Note: the published entry contains the **rewritten** ops (`as_published`: a folder is
published where it is *now* here, e.g. after being moved aside), under the original key.

**Drain order** (`Domain_engine.drain`, `Resync.run`): metadata queue first (a rename it
publishes names the file an upload behind it is for), then uploads, then `flush_cursor`,
then change notices, then backend drain. On shutdown the queue wait is raced against
0.8 × grace so the cursor still flushes.

### 4.2 Cursor bump coalescing (`file_store.ml:69-212`)

Stores cap writes to one object name at ~1/s (429 otherwise). State per cursor key,
process-global (every component that instantiates the journal store shares it):

```
cursor_flush_interval = 2 s     (must stay > 1 write/s)
bump k:  if now - last_published >= interval → publish k now (under publish_lock)
         else note k; arm
note_cursor k: note k; arm       (upload/meta queues always use this)
note k: pending := max(pending, k)   (forward-only)
arm: if not armed: armed; async(sleep max(0, interval - (now - last_published)); flush)
flush: take pending, clear, disarm; if none → take and release lock (wait for an
       in-flight publish); else publish under lock; errors logged and swallowed
publish: B.put cursor_key (to_string k); last_published := now (after the write lands)
```

Tests pin: a bump on a quiet cursor writes before returning; 60 bumps in the interval → 0
writes, then 1 after the timer; older key behind newer is ignored; flush doesn't wait the
interval and writes nothing when idle; every instantiation of the store shares one debouncer.

### 4.3 Inbound: the poller and `apply_foreign`

**Poller loop** (`sync_poller.ml`), one detached loop per domain in the daemon:

```
loop:
  try
    if paused() → sleep 0.2 s                      (held_tick; nothing read or applied)
    else
      with_timeout sweep_interval(60 s):
        wait_cursor_change last_version            (timeout swallowed)
      sync_once
  on exn → log "sync_poller: …"; sleep 2 s (retry_floor)
  loop

sync_once:
  cursor := fetch_cursor()                          (one GET)
  moved  := cursor ≠ None ∧ cursor ≠ last_version
  due    := now - last_swept ≥ sweep_interval
  if ¬moved ∧ ¬due → return 0                        (no journal listing)
  last_swept := now
  n := Replay.apply_foreign                         (may raise → last_version unchanged)
  last_version := cursor (if Some)
  return n
```

`wait_cursor_change` per store (it is only a hint; returning means "read and compare"):

| Store | Wait |
|---|---|
| Object stores (S3/GCS) | `sleep 2 s` (`Backend.default_watch_interval`) ⇒ one cursor GET per client per ~2 s |
| Local disk | directory watcher on the cursor's **directory** (writes rename into place), capped at 2 s; falls back to sleep. Watcher ignores tsync's own scratch/temp names (fixed OOM feedback loop). |
| http-proxy (another tsync) | long-poll `GET <cursor>?wait=30&last_seen=<token>`: the peer holds up to `Http_proxy.Watch.max_seconds = 30` until the object differs from the token; answered header ⇒ return; old peer/failed request ⇒ sleep 2 s floor |
| Multi-member domain store | delegates to the member the cursor is read from, never the one being probed |

Token = the cursor body bytes of `last_version` (so a store compares objects, a caller
holds keys). Tests (`cursor_watch`) pin: an idle client waits before any cursor read and
offers no token; a moved cursor ⇒ 1 cursor read + 1 listing and token advances; an unmoved
cursor ⇒ cursor read only; a failed pass keeps offering the previous token; a due sweep
lists even with a still cursor.

**`apply_foreign`** (`replay.ml:249-320`):

```
handled := load-once set of Applied_entries.keys (strings)
horizon := if read_last_sync_key() = None then None      (never synced: whole journal due)
           else Some(now_ms - 30 days)
keys := list_journal_keys()                                (full listing, sorted)
        filter: (horizon = None ∨ key.ms ≥ horizon) ∧ key ∉ handled
for ek in keys, sequentially:
  stepping_aside ek:
    if ek.uuid = my uuid → nothing   (own entries; normally already in handled)
    else ops := get_journal_entry ek
         None  → nothing (not remembered; retried next pass)
         Some ops → F.apply_foreign_ops ops
                    remove ek from stepped_aside
                    Applied_entries.note ek ops          (AFTER applying)
                    handled += ek
                    on_changed(logical key) for each keys_of_ops
                    applied++
    if last_sync < ek (or none) → write_last_sync_key ek   (forward only)
  stepping_aside on exception e:
    if classify_in_order e = Transient → re-raise (whole pass aborts, poller retries in 2 s)
    else → stepped_aside[ek] := reason (log once); continue with next entry.
           ek stays unhandled ⇒ retried on every later pass; `tsync status` shows
           "PEER ENTRIES UNAPPLIED n (reason)".
return applied
```

Key points:
- Dedupe is by **set membership over the retention window**, never "keys > mark"
  (§7.3). An entry older than 30 days that becomes visible late is lost by design.
- Mark written after each clean entry and after own entries; never moved back.
- `Unread` (a store answer missing under the lock because local state changed since the
  read-ahead) is raised as a `Transient` `Retry.Failed` ⇒ the pass aborts and is retried.

**`tsync sync`** (`resync.ml:run`) = one pass of the same engine: start both queues,
`reconcile`, drain metadata, drain uploads, `flush_cursor`, then:
- `--full`, or no last-sync mark, or `cannot_bridge(mark, all journal keys)` ⇒ refuse if
  any metadata op is still owed; else **full rebuild**: rewrite the mirror in place from the
  store's tree, report the diff via `note_local` in chunks of 64 ops, and only if the walk
  had 0 failures: sweep stale entries, `write_last_sync_key(fresh key)`,
  `mark_handled(all journal keys read)`.
- else `apply_foreign` once.
The daemon never runs `cannot_bridge` itself; a daemon whose mark predates the pruned
journal just applies what is left (see §9).

### 4.4 Applying a peer's entry — `apply_foreign_ops` and the Arrival table

Two phases so the metadata lock is **never held across a store request**:

1. **Read-ahead, without the lock** (`Foreign.read_ahead`):
   - `owed := W.owed_metadata()` (this client's unpublished metadata ops).
   - For each `Put`/`Mkdir`/`Rename`: **adopt ancestor ids** top-down — for each ancestor
     directory with no local id, read the store's marker at `(parent id, leaf)`; if it names
     an id, and the folder was not moved/removed here since with that id, write it locally.
     (A put materialises directories with no id; without adoption they can be named by
     nobody.) The store never gets a minted id here.
   - Repeatedly run `gather`+`decide` for each op against an answer table
     `{markers; manifests}`; when a lookup is missing it raises `Unread`, the missing answer
     is fetched (`marker_at_store`, or `fetch_peer` = the peer's manifest fetched in the
     namespace of the folder found **here**), and the pass restarts. For `Mkdir(_, None)`
     deciding `Make_folder`, adopt the store's id. For decisions containing `Write_theirs`
     / `Adopt_theirs_at_destination`, prefetch the peer's manifest.
2. **Apply, under the lock** (`Peer_entry.apply`): re-read `owed`, then for each op in
   order: `gather` facts from local state + the answers table, `decide`, log if clashed,
   enact actions in order. An answer missing now ⇒ `Unread` ⇒ transient failure, the entry
   is re-read on the next pass.

**Path translation** (`local_folder`): a peer names things by *its* path. Walking from the
op's parent upward: if this client moved the folder (`whereabouts = Moved(id, at)`) and the
store still files `id` under that name, the local folder is `at`; otherwise parent+leaf.
File ops also follow this client's **unpublished file renames** (`renamed_since`: follow
`src→dst` chains from owed rename records), so a peer's edit follows the file it was made to.

**Facts gathered per op** (`Peer_entry.gather`, `file.ml:800-905`):

| Op | Facts | Place |
|---|---|---|
| `Put rel` | `renamed_onto` = an owed file rename of ours has `dst = rel` (and none has `src = rel`); `folder` = local node at the name is a dir with id / without id / absent; `staged` = unuploaded bytes at the name | `at` = translated path |
| `Delete rel` | `staged` at the translated path | |
| `Mkdir(rel,id)` | `lives_elsewhere` = id already held at another local path; `staged_file` = a staged file at the name; `another_folder` = a folder with a different id at the name | `ours` = that other id |
| `Rmdir(rel,id)` | `By_id` if id found anywhere locally; else `At_path` if the path holds no other id; else `Held_by_another` | |
| `Rename` dir | `source`: `At_path` if src is a dir not holding another id; else `By_id` if id found; else `Gone`. `destination` (translated dst): `Free` (absent, or no ids to compare), `Same_folder` (holds this id), `Another_folder` (holds a different id). `already_there` = source location = destination. `ours_owed` = an owed Mkdir/Rmdir/dir-Rename of ours carries this id | `from`, `ours` |
| `Rename` file | `source_here` = manifest exists at translated src; `staged_destination` = staged bytes at translated dst | `from` |

**Arrival decision table** (`resolve.ml:194-240`, exhaustively printed by
`tests/unit/resolve`, 65 situations):

| Facts | Decision (actions in order) | Rows |
|---|---|---|
| Put | `[Retarget_our_rename if renamed_onto] ++ [Our_folder_aside(Published_as_rename) if folder has id / Our_folder_aside(Here_only) if folder without id] ++ [Our_staged_file_aside if staged ∧ ¬renamed_onto] ++ [Write_theirs]` | F7, F8, K1, F9 |
| Delete, staged | **Skip** (ours publishes later) | F12 |
| Delete, not staged | `Remove_file` | |
| Mkdir, lives_elsewhere | **Skip** (already applied) | |
| Mkdir otherwise | `[Our_staged_file_aside if staged_file] ++ [Our_folder_aside(Published_as_rename) if another_folder] ++ [Make_folder]` | K1, D6 |
| Rmdir, Held_by_another | **Skip** (held by another folder) | |
| Rmdir, By_id / At_path | `Rescue_staged_under; Remove_folder` | D7, D8 |
| Rename folder, ours_owed | **Skip** (ours publishes later) — precedence 1 | D2, D4 |
| Rename folder, source Gone | **Skip** (nothing to move) — precedence 2 | |
| Rename folder, already_there | **Skip** (already applied) — precedence 3 | |
| Rename folder, dest Same_folder | `Retire_stale_source` | |
| Rename folder, dest Another_folder | `Our_folder_aside(Published_as_rename); Move_folder` | D5 |
| Rename folder, dest Free | `Move_folder` (staged files under it move with it) | D9 |
| Rename file | `[Our_staged_file_aside if staged_destination] ++ [Move_file if source_here else Adopt_theirs_at_destination]` | F10, F11 |

`clashed` (worth a log line): any Skip except `Already_applied`/`Nothing_to_move`, or any of
`Retarget_our_rename, Our_folder_aside, Our_staged_file_aside, Retire_stale_source`.

**Actions** (`enact`, `file.ml:918-962`):

| Action | Effect here | Published? |
|---|---|---|
| `Retarget_our_rename` | move our file at the name to `aside_name`; rewrite every owed rename record with `dst = rel` (file) to `dst = conflict name` (`W.update_ops`) | yes, via the retargeted rename |
| `Our_folder_aside Published_as_rename` | `publish_aside`: record a new `Rename{src = where the store files it, dst = conflict name, is_dir, id}`, local `rename_local`, hand to metadata queue | yes |
| `Our_folder_aside Here_only` | move the id-less folder aside locally only | no |
| `Our_staged_file_aside` | move our staged file to `aside_name`, `queue_put` the conflict name | yes, as an upload |
| `Rescue_staged_under` | every staged file under the folder (deep, sorted by path) moves to `aside_name(parent-of-folder / leaf)` — i.e. beside the folder, flattened | yes, as uploads |
| `Write_theirs` | cancel our upload at the name; write the peer's manifest (as fetched) into the mirror; `None` manifest ⇒ nothing | — |
| `Adopt_theirs_at_destination` | same as `Write_theirs` for the rename's `dst` | — |
| `Remove_file` | cancel upload; evict chunks, discard staged, delete manifest | — |
| `Make_folder` | create dir; write the op's folder id (final from mkdir) | — |
| `Remove_folder` | delete dir locally | — |
| `Move_folder` / `Move_file` | `rename_local from → at` (staged uploads re-queued under new path) | — |
| `Retire_stale_source` | move the source to `aside_name`, **forget** its folder id there (`Folders.forget`), re-point the shared id at the destination (`Folders.reparent`); not published (the store already files the folder at dst) | no |

### 4.5 Publishing our own op to a store that moved on — the Publish table

Run by the metadata queue per op (`Backend_half.backend_op`), outside the lock (the
enactments that change local state take it themselves). Fact gathering *is* an attempt:
a name is the store's to grant (claim) and a file move the store's to make.

| Op | Gather | Facts |
|---|---|---|
| Put | — | `Put` |
| Delete rel | local kind at rel | `A_file_here_again` if a file is there again, else `Gone_here` |
| Mkdir(_, None) | — | `No_id` |
| Mkdir(rel, id) | `current_place` (by id, else rel if it holds id) | none ⇒ `Gone_here`; store `placed` elsewhere ⇒ `Filed_elsewhere`; else **`claim_folder id key`** ⇒ `Claimed` / `Name_taken` |
| Rmdir(rel, None) | (logged) | `No_id` |
| Rmdir(rel, id) | old marker key (fail if unnameable); store anchor of id | anchor in trash ⇒ `Already_trashed`; else ever published (anchor anywhere, or marker at old key = id) ⇒ `Published` / `Never_published` |
| Rename dir | id (op's, else `ensure_folder_id dst`); `current_place` | gone ⇒ `Gone_here`; store places it here ⇒ `Filed_here_already`; not ever published ⇒ `Never_published`; another id holds dst marker ⇒ `Name_taken`; else `Free` |
| Rename file | **attempt** `save_version src; copy manifest src→dst (+ rewrite leaf in body)` | success ⇒ `Moved`; on failure: src still on store ⇒ `Source_still_there`; dst present ⇒ `Landed`; else `Source_gone(Staged / Published / Absent)` per what we hold at dst |

Decision table (23 situations):

| Facts | Actions | Ending |
|---|---|---|
| Put | — | Publish |
| Delete A_file_here_again | — | Nothing_owed (F1, F3) |
| Delete Gone_here | Remove_from_store (save version, delete manifest) | Publish |
| Mkdir No_id | Put_marker | Publish |
| Mkdir Gone_here / Filed_elsewhere | — | Nothing_owed |
| Mkdir Claimed | — | Publish |
| Mkdir Name_taken | Ours_aside (move our folder to conflict name here, if still holding id) | **Again** (re-gather: claims the conflict name) (D6, K1) |
| Rmdir No_id | — | Publish |
| Rmdir Already_trashed / Never_published | — | Nothing_owed (D7) |
| Rmdir Published | Retire_to_trash | Publish |
| Rename dir Gone_here / Never_published | — | Nothing_owed |
| Rename dir Filed_here_already | — | Publish |
| Rename dir Name_taken | Ours_aside_as_rename (new owed rename to conflict name) | **Superseded** (D5) |
| Rename dir Free | Move_marker | Publish |
| Rename file Moved / Landed | — | Publish |
| Rename file Source_still_there | — | **Retry** (re-raise the move's failure) |
| Rename file Source_gone Absent | — | Nothing_owed |
| Rename file Source_gone Staged | Queue_upload of dst | Superseded (F5, F6) |
| Rename file Source_gone Published | Republish_here (publish our manifest at dst) | Superseded |

Endings: `Publish` ⇒ op (rewritten to where it is here) goes into the entry; `Nothing_owed`
⇒ dropped from the entry; `Superseded` ⇒ `Retry.Cancelled` ⇒ record completed (replaced by
work under its own record); `Again` ⇒ recurse; `Retry` ⇒ re-raise, classified by the
queue (link failure waits at head; own-account failure parks).

Store-side enactments (details belong to the store-layout spec): `Retire_to_trash` writes
a trash marker `trash/<short id>` with `{name, id, path}`, re-anchors the id to the trash,
then removes the live marker; `Move_marker` writes the new marker+anchor **before**
removing the old marker (crash leaves a stale marker readers skip, not an unlisted
folder); `remove_old_marker` leaves a marker that now names another id alone.

### 4.6 Startup reconcile

Must run before writes stage, after both queues are started (recovery goes through them).
For every own WAL record, in key order, sequentially:

| State | Action |
|---|---|
| `executed` | `journal_entry_published k` (HEAD)? yes ⇒ complete; no ⇒ `write_journal_entry k ops`, `bump_cursor k`, complete. Idempotent across a crash in either window. |
| `prepared`, single Put | `resume_put` (re-signal upload queue if staged data or symlink manifest exists) else complete |
| `prepared`, metadata only | `resume_meta` (re-signal metadata queue) |
| `prepared`, mixed | as `intent` below |
| `intent`, metadata | `redo_local` each op (idempotent: removal goes by id; rename only if src present and dst absent) then `resume_meta` as `prepared` |
| `intent`, other | `replay_unpublished`: `overridden_since k` = keys touched by **other clients'** entries with key > k (listing `start_after k`, fetched with ≤ 32 concurrent reads); drop ops touching those keys ("another client has since changed them"); apply remaining metadata ops (errors logged, not fatal); single put ⇒ `resume_put`; else if metadata ⇒ publish entry + bump + complete; else ⇒ "nothing staged, discarding", complete |

Failure of one record: log, `note_failure`, leave it for next start. Afterwards
`adopt_unrecorded`: every staged file no record names (crash between staging and
recording) gets a fresh put record via `queue_put`.

### 4.7 Frontend change feed (consumer of the applied log)

`ipc changes_since(anchor)` (`ipc_handler.ml:611`): anchor = `<generation>:<entry key>`; a
generation mismatch (after a full resync/reimport) ⇒ `stale`. If anchor = `head` ⇒ empty,
up to date. Else `Applied_entries.since` (limit per page); `None` ⇒ `stale` (relist);
ops are described for the frontend; an op that cannot be *named* (no folder id) is counted
as unnamed and dropped from the batch. Entries are **not** filtered by client: the CLI's
own change must still reach the mount. Because entries are kept only after they are
applied (peers) or as they are published (own), a reader never meets an item the mirror
has not caught up with.

---

## 5. Interactions

```
 frontend (FUSE/FP/Android/http-proxy)
     │ mutations                       ▲ on_changed / Change_notice / changes_since
     ▼                                 │
 File (checkout) ──WAL record──► Owed ──► Sync_queue (uploads) ─┐
     │  under metadata lock          └──► Meta_queue ──Resolve.Publish──┤
     │                                                               ▼
     │                                   File_store: write_journal_entry
     │                                     ├─ Applied_entries.note (local)
     │                                     ├─ backend put journal/<YYYY-MM>/<key>
     │                                     └─ note_cursor → debounced put cursor
     │
     ◄── apply_foreign_ops ◄── Replay.apply_foreign ◄── Sync_poller ◄── wait_cursor_change
                 │ Resolve.Arrival             │ list/get journal, dedupe vs Applied_entries
                 ▼                             ▼
            mirror, Folder_ids, staged     last-sync mark
```

Depends on: `Conf` (data_dir, cache_root, domain_name, client_name, journal_prefix,
cursor_key, max_uploads, read_only), `Backend` store (`put`, `get`, `get_opt`, `head_opt`,
`list_prefix`, `watch`), `Store`/`Layout` (markers, anchors, `claim_folder`, `placed`,
`holder_at`, trash), `Checkout`/`Manifests`/`Staged_manifest`/`Data` (mirror and staged
tree), `Folder_ids` (id↔path index incl. persisted by-path entries), `Wal`,
`Durable_queue`, `Retry`, `Change_notice`, `Bounded`, `Lock`, `Clock`.

Depended on by: `Domain_engine` (daemon start/converge/drain/stats), `Resync`
(`tsync sync`), `Retention` (`tsync expire` deletes journal entries by age), import
(`write_journal_entry_body`, spooled), rsync/revert (publishers), `ipc_handler`
(`changes_since`, `current_cursor`), status report (`pendingMetadata`,
`metadataDegraded`, `unappliedEntries`, journal backlog "N entries, M to apply"),
maintenance (`Applied_entries.prune`).

### 5.1 How each host instantiates this subsystem

The same components are reused in every host; what differs is **who converges** a
domain. Converging = reconcile + journal poller + maintenance; it writes the mirror, the
last-sync mark and the staged tree, which every process serving the domain shares, so
exactly one process per machine and domain does it (`launcher.ml:245-253`).

| Host | Outbound queues (upload + metadata) | Reconcile | Journal poller (inbound) | Notes |
|---|---|---|---|---|
| Daemon / launcher (Linux, macOS) — the parent process that forks the frontends | yes | yes, at start (after queues start) | **yes**, one loop per domain, `paused = pause switch` | Order: init mirror → start both queues → reconcile → start poller → maintenance. Frontends learn of applied peer ops through `on_changed` → a `changed` IPC notice to each frontend's socket. Drain on stop: metadata → uploads → cursor flush → notices → backends. |
| Frontend processes (FUSE mount, File Provider handler, http-proxy server) | yes, each its own, over the shared WAL dir (they post only what they were handed) | no (the launcher does it) | **no** | Receive `changed` notices; File Provider pulls `changes_since` from the applied log. The http-proxy server additionally answers peers' cursor long-polls by waiting on its own store. |
| One-shot CLI (`tsync sync`) | yes, started for the run, drained before reading the journal | yes | no loop — exactly one `apply_foreign` pass, or a full rebuild (§4.3) | Publishes owed metadata even with no daemon running. Other mutating CLI commands (import, rsync, revert) publish through the same journal store and flush the cursor before exit. |
| Per-request entry of the Android frontend (`android_frontend.ml` `answer`: one request, print reply, exit) | started only if the request mutates (`staging`); drained before exit | no | no | |
| Android app (single process) | yes (`start_queue`, which also reconciles) | yes | **no** — the Android engine runs over the *lazy* checkout, which lists folders from the store when browsed, so freshness comes from browsing rather than the journal (inferred from `android_jni.ml:75-100`; not verified further) | Maintenance runs; the change feed is served from the applied log as for File Provider. |

Swapped per host: frontend (and its `on_changed` sink), storage paths (`data_dir`,
`cache_root`), lifecycle (daemon loop vs. run-to-completion with drain), and the checkout
flavour (full mirror vs. lazy).

---

## 6. Concurrency, durability & failure semantics

- **Ordering of durability for own work**: WAL record written (atomic file write) *before*
  the local change; entry noted in applied log *before* the backend put; record deleted only
  after entry put and cursor noted. Crash windows:
  - before local half: `intent` → reconcile redoes (metadata) or re-derives (puts).
  - bytes up, entry not published: `executed` → reconcile HEADs the entry and publishes if
    missing (under the same key).
  - entry published, record not deleted: `executed` → HEAD finds it → complete.
  - entry noted locally but put failed: the applied log names an entry no peer sees; the
    record still exists so it will be published under the same key; the applied log has it
    once (dedupe by key on the feed is positional so a second note would duplicate — see §9).
  - cursor bump lost (timer never fired, crash): peers find the entry by the 60 s sweep.
- **Peer apply durability**: an entry is noted in the applied log only after all its ops
  applied; a crash mid-entry leaves it unhandled ⇒ re-applied next pass; ops are designed
  idempotent through facts (`Already_applied`, `Nothing_to_move`, write_theirs of current
  manifest).
- **Atomicity**: none across ops of one entry; an entry's ops are applied sequentially
  under one metadata-lock hold (per `apply`), so a local op cannot interleave within an
  entry.
- **Locks & bounds**:
  - metadata lock: held for each local mutation and for the apply phase of one entry,
    never across a store request (read-ahead design; `Unread` if state changed in between).
  - upload pool width `max_uploads`; one job per file key.
  - metadata queue: 1 worker, strict order.
  - reconcile journal reads: `Bounded ~max:32`, module-scoped.
  - apply_foreign: strictly sequential per entry.
  - cursor publishes serialized by `publish_lock`.
- **Offline**: local ops complete with zero round trips and stay owed; metadata queue waits
  at head on transient link failures; poller logs and retries every 2 s (or keeps waiting on
  the watch); a transient failure applying a peer entry aborts the pass without skipping.
- **One failing entry never blocks the rest** (except link failures, deliberately): peer
  entries step aside (unhandled, retried each pass); own metadata ops park (retried by
  `rearm`).
- **Multiple processes on one domain** (daemon + CLI): each runs its own queues over the
  shared WAL directory (a queue only drains what it was handed or recovers logs no live
  process claims); cursor debouncer is per process; applied log appends are unlocked but
  torn-record tolerant; last-sync writes are atomic renames; entry keys can collide within
  1 ms across processes (accepted).
- **Pause**: holds both outbound queues and the poller (no reads of the journal, no
  apply); reads by frontends still served.
- **Retention**: backend journal entries older than the `expire` cutoff are deleted except
  the one the cursor names (age is the only safe criterion: the cursor says what was
  published, not what everyone applied). Applied log: 30 days / 64 MiB.

### 6.1 Correctness that silently relies on cooperative, single-threaded scheduling

The implementation runs every domain of a process on one event loop with no preemption
between yields (a yield is any I/O or sleep). Several pieces of shared mutable state are
check-then-act sequences with **no lock**, correct only because nothing else runs until the
sequence reaches its next I/O. A rewrite with preemptive threads or parallel workers must
protect each of these explicitly:

| State | Check-then-act that must be atomic | Failure if preempted |
|---|---|---|
| Entry-key minting: process-wide `last_ms` | read `last_ms`, compute `max(now, last+1)`, store | two keys with the same ms+uuid ⇒ one journal object and one WAL record overwrite the other |
| Folder-id lease: `next` counter of the process's block; lazy lease creation | read `next`, format id, increment; "no lease / exhausted ⇒ lease a new block" | **duplicate folder ids** (ids are final and global — silent namespace corruption) |
| Cursor debouncer (`pending`, `timer_armed`, `last_published`) | `arm`: test-and-set `timer_armed`; `flush`: take `pending` and clear it and disarm; `note`: forward-only max | lost bump (peers wait for the 60 s sweep) or two timers; the actual publish *is* under an explicit mutex |
| Dedupe set `handled` (lazy load, membership, insert) and `stepped_aside` map | lazy "load if absent"; `apply_foreign` assumes it is the only pass running in the process; `unapplied()` is read by the status handler concurrently with the poller's writes | an entry applied twice by two concurrent passes (tolerated by idempotent facts, but not designed for); torn hash-table reads |
| Poller `last_version`, `last_swept` | single loop per domain | — (only if a second loop were started) |
| Metadata-queue `parked` set, upload `completed` counter | inserts/removes from job callbacks, read by stats | torn reads / lost increments |
| WAL hand-off slot (`consume` replaces the consumer function, `signal` calls it) and the per-directory log registry (lazy "create if absent") | swap vs. call; create-if-absent | two logs over one directory (the bug the registry exists to prevent), or a record signalled to a stale consumer |
| Applied-log appends from one process | each `note` is one `write` of one record with a short-write continuation loop | across *processes* this is already tolerated (torn record = one lost line); two concurrent in-process writers interleaving continuation writes would corrupt two records |

The metadata lock (an explicit mutex) is the only lock the domain's state has; the poller's
"one entry at a time" and the queues' "one worker per key / one ordered worker" are
structural (a single loop each), not locked.

---

## 7. Design choices & rationale

### 7.1 Best-effort conflicts, as two pure tables
From memory note *design-best-effort-conflicts* and PR "Local file operations never wait on
the network" (the conflict-table PR, rows N1/F1–F12/D1–D9/K1). The user rejected deferring
peer entries ("never defer the poller") and rejected stress testing as the route to
confidence ("a band-aid: specific cases, overfitting fixes"): the theory (the table) comes
first. Therefore: decisions are pure functions `facts → actions` (`Resolve.Arrival`,
`Resolve.Publish`), fact gathering and enactment live in `File` (which owns the metadata
lock and cannot reach the store), and a new clash = a new arm + a two-client row in
`tests/scenario/conflicts`. Reading the printed table against the ladder found four wrong
rows (F10, F11, F12, D9) and a queue-wedging rename.

Expected outcomes (B's op unpublished when A's arrives; every row ends identical on both):

| Row | B (unpublished) | A (arrives) | Everywhere |
|---|---|---|---|
| N1 | renames f over g | — | g holds f's content |
| F1 | deletes f | edits f | f with A's edit |
| F2 | deletes f | renames f → h | h |
| F3 | deletes f | renames x → f | A's f |
| F4 | renames f → g | edits f | g with A's edit |
| F5 | renames f → g | deletes f | g |
| F6 | renames f → g | renames f → h | h and g (both f's content) |
| F7 | renames f → g | creates g | A's g, B's as `g (conflicted copy from B)` |
| F8 | renames f → g | creates g, renames it → h | h and `g (conflicted copy from B)` |
| F9 | edits f | edits f | A's f and B's as `f (conflicted copy from B)` |
| F10 | edits f | renames f → g | g with B's edit |
| F11 | creates g | renames f → g | A's g and B's as conflicted copy |
| F12 | edits f | deletes f | f with B's edit |
| D1 | removes d and a file in it | adds d/x | d in the trash with x inside; removed file gone |
| D2 | removes d | renames d → e | folder in the trash |
| D3 | renames d → e | adds d/x | e/x |
| D4 | renames d → e | renames d → f | e (last published wins) |
| D5 | renames d → e, writes e/ours | creates e, writes e/theirs | A's e/theirs and `e (conflicted copy from B)/ours` |
| D6 | creates d, writes d/ours | creates d, writes d/theirs | A's d and `d (conflicted copy from B)`, each with its file |
| D7 | removes d | removes d | one trash entry |
| D8 | adds d/new.txt, d/sub, d/sub/new.txt | removes d | d in trash; `new (conflicted copy from B).txt` and `new (conflicted copy 2 from B).txt` beside it; empty unpublished d/sub goes with d |
| D9 | adds d/x | renames d → e | e/x |
| K1 | creates file x | creates folder x | A's folder x, B's file as `x (conflicted copy from B)` |
| K1' | creates folder x, writes x/in.txt | creates file x | A's file x, B's folder `x (conflicted copy from B)` with its file |

**Not promised**: two edits of the same *already-published* file ⇒ last write wins, loser
only in version history (`concurrent_create` scenario: A syncs and converges on B's later
upload). A kind clash where *both* sides already published is undecided. Writes into a
folder being moved aside as a conflicted copy may land at its old path.

### 7.2 The loser is the one that publishes second, and it renames itself
A kind clash cannot be fixed by "move the loser aside on each side" (that swaps the two
and stays divergent — conflict-gaps note). The rule used everywhere: whoever still holds
the op *unpublished* when the other's arrives moves its own item aside and publishes that
move (as a rename or as an upload under the new name). Winner is thus computed identically
on both machines without coordination.

### 7.3 Positional applied log + dedupe, never "keys > cursor"
Entry keys are client-minted at start time; entries become visible out of key order (slow
upload, retries, WAL records published after a crash under their original key). Any reader
that cuts at a key silently loses entries landing behind it. Symptom seen: with 4
concurrent uploads per side each peer got the first batch and lost the second, "0 to
apply" (memory note *journal-key-cursor-race*, commit `2102b6bc`/`aebaeff5`). Hence:
- `apply_foreign` lists the whole journal and dedupes against the set of handled keys back
  to the 30-day window; the mark only says "ever synced".
- The applied log is sharded by **handling** time and the feed anchor is a position.
- A full resync marks what it read as handled.
Rule: never introduce a "since key" read of the journal. Entries late by > 30 days are
lost by design.

### 7.4 Cursor as a debounced hint + a sweep
- Stores rate-limit writes to one object name (~1/s) ⇒ coalesce to newest, 2 s interval.
- The poller reads the cursor first and lists the journal only when it moved or a sweep is
  due: listing every tick costs a list request per client per interval for the common
  "nothing changed" answer.
- The sweep (60 s) is timed from the last listing, not from a wait timeout: every store
  answers a wait well within 60 s (http-proxy ≤ 30 s, object store 2 s), so a sweep tied to
  a timeout would never run (commit `2569ed4f` "the journal is swept on a clock, not on a
  wait no store runs long"). The sweep finds entries whose bump never landed or was
  overwritten by an older-key bump from another process.
- ponytail: one listing per client per minute while idle; lengthen/jitter if idle fleets
  show up on the bill.

### 7.5 Record → publish → forget
There is no "committed" WAL state: writing one only to delete it costs a disk write per
upload. `executed` + HEAD of the journal entry makes the publish idempotent.

### 7.6 Local ops never wait on the network; lock never spans a request
Metadata backend halves are queued (ordered). A peer's entry reads the store before taking
the lock and brings answers in as data; the component that owns the lock is structurally
unable to reach the store (see the [OCaml notes](ocaml/03-journal-sync.md) for how). A slow link therefore holds up that
entry, not every local operation (meta_offline tests count round trips).

### 7.7 A link failure blocks; anything else steps aside
Order must be preserved for metadata (renames before creates…) so the head is retried —
but only when the *link* is at fault. `Retry.classify_in_order` marks everything not tagged
by the retry loop as `Permanent`. Before this (memory note *foreign-rename-enotempty-loop*)
one `ENOTEMPTY` rename blocked a client's poller for 8+ hours, logging every 2 s, ~1,900
entries behind. Same principle on both directions (park / step aside), visible in status.

### 7.8 Folder ids minted locally, siloed per client, final
No coordination needed and no id changes later, so File Provider/Android references stay
valid. Names are claimed on the store at publish time (`claim_folder`); a taken name
becomes a conflicted copy rather than another id (`6b3f96c5`, `addadddc`).

### 7.9 Ops carry folder ids; peers act on the folder holding the id
Paths alone confused a folder recreated under a name with the original, and a recursive
delete removed the marker the id was read from (memory note *foreign-delete-unnameable*;
the fix persisted a by-path entry in the folder-id index because the process applying an
entry is not the one describing it to the frontend — an in-memory table fails).

### 7.10 Applied log written by the store wrapper, before publishing
Five publishers exist; recording at each would miss the sixth. Recording before the put
means "recorded and not published" describes something that did happen (it is already in
the mirror), whereas "published and not recorded" could never be reported. Recording and
announcing (`Change_notice`) are one operation because commands outside the daemon (import,
revert) forgot the second.

### 7.11 Silent guards are dangerous
`foreign-dir-rename-staged-guard`: "staged" for a folder used `file_exists` on the staged
tree, true for an empty leftover directory, so a peer's folder rename was silently skipped
on any folder this client had ever written into (`7059de7a`/`b31dbb7c`). Now a folder is
staged only if a staged manifest lies under it (`Mfs.entries ~deep:true`). When a foreign
op is "applied without effect", read the guards in `gather` first.

---

## 8. Invariants the tests pin down

**`tests/unit/resolve`** — the two tables exactly as in §4.4/§4.5 (65 + 23 situations).

**`tests/scenario/conflicts`** — one two-client scenario per row of §7.1. Harness: setup,
`A Drain; B Sync; B pauses metadata+uploads`, B's op, A's op, `A Drain; B Sync` (A's entry
arrives while B's is unpublished), B resumes and drains, `A Sync; B Sync`. Snapshot shows
both trees, file contents and backend; outcomes as in the table (contents verified, not
just names).

**`tests/scenario/sync`**:
- `foreign_put/delete/overwrite/rename/mkdir/rmdir`: plain propagation; a foreign
  overwrite evicts B's stale cache; a foreign rename moves B's cached data and manifest.
- `foreign_rename_chain`: one pass applies `foo→bar→baz` in order.
- `foreign_rmdir_after_repeated_mkdir`: repeated mkdir of one path addresses one marker;
  the final rmdir leaves none.
- `concurrent_mkdir_then_write`: one folder + one conflicted copy, each keeping its file,
  identical on both.
- `concurrent_mkdir_then_rmdir`: second publisher takes the conflicted name; rmdir removes
  only the folder it targeted.
- `offline_mkdir_renamed_onto_a_taken_name`: B's folder filed under a conflicted name at
  publish; its later rename has nothing to move and must not move A's folder; no third
  folder.
- `concurrent_create`: last uploader wins everywhere.
- `delete_rename_race`, `rename_rename_race`: B's rename whose source A removed/moved
  publishes B's copy (`Source_gone Published ⇒ Republish_here`); both converge.
- `crash_leaves_a_record`, `crash_before_commit`: bytes up but no entry ⇒ peer sees
  nothing; after `RecoverStaged` (reconcile) the entry is published under the record's key
  and the peer gets the file.
- `stale_record_discarded`: a record whose staged data is gone publishes no entry.
- `foreign_put_readopts_a_forgotten_folder_id`: a foreign put re-adopts the folder id from
  the store's marker.
- `late_visible_entry`: an entry hidden then unhidden (older key visible after a newer one
  was applied) is still applied (B's applied log order: b, a, c).
- `foreign_dir_rename`, `foreign_dir_rename_of_own_folder`: B follows A's folder rename,
  including for a folder B created and wrote into (staged-guard regression).
- `dir_rename_onto_foreign_dir`: renaming onto a different folder's name ⇒ the renamer's
  copy takes a conflicted name; the other marker is not overwritten.
- `rename_folder_with_owed_upload`: the upload owed under the old path is re-queued under
  the new one and reaches the peer.

**`tests/scenario/meta_offline`** (round-trip counting over a controllable link): local ops
return with 0 round trips and stay owed; everything publishes once the link returns; a
refused request lets nothing overtake it; a refused claim is made again; a store-permanent
refusal and an own-account failure both park, are reported (`degraded`), and land on
`rearm`; a rename with nothing to move is owed nothing and blocks nothing; a peer entry
waiting on the store holds up no local operation (also under a folder moved here); **a
peer entry that cannot be applied steps aside, the next applies, `unapplied` = 1, and it
lands on a later pass once possible**; while paused nothing of ours reaches the store and
nothing of the peer's is applied, reads are still served, and everything flows on resume;
a peer's rename announces both names.

**`tests/unit/applied_entries`**: kept under its key; oldest first; anchor exclusive;
`more` iff a full page; head = last handled; shards by handling month and reads cross
them; rename ops round-trip; an entry handled late with an older key follows the anchor and
becomes head; a torn line does not stop the reader; head found past a line longer than the
8 KiB tail; a pruned anchor ⇒ `None` (stale).

**`tests/unit/cursor_debounce`** and **`tests/unit/cursor_watch`**: §4.2 / §4.3.

**`tests/ops/resync`**: no bookmark ⇒ rebuild (reason given), findings on the applied log;
clean rebuild sets the bookmark; caught-up client applies the journal instead; `--full`
forces rebuild; rebuild rewrites in place (chunks survive, vanished manifests dropped and
reported); an anchor from before a rebuild is still bridged; folder moves/recreations/
removals reported by id; a partial walk leaves the bookmark and does not sweep; `tsync sync`
publishes owed metadata; a rebuild is refused while metadata is owed.

**`tests/unit/folder_id`, `id`, `folder_ids`**: ids from forked processes distinct and
increasing; concurrent processes agree on one uuid; a folder holding an id refuses another
except by explicit replace.

**`tests/scenario/upload_gone`**: an upload whose staged bytes vanished publishes no entry.

---

## 9. Open questions / inconsistencies

1. **Applied-log doc vs code**: `applied_entries.mli:21-26` says `note` is called "once the
   entry is published (this client's)"; `file_store_lwt.ml:301-352` notes it **before**
   publishing (deliberately). Also `cache_layout.ml` says the applied log is
   "month-sharded as the published journal is" — it is sharded by handling time.
2. **Duplicate own entries in the applied log**: an own entry noted and whose put then
   fails is re-noted when retried (same key, new line). `since` finds the *first* matching
   anchor line walking newest shard first, but within a shard `following` stops at the first
   match, so a duplicated anchor could replay entries. Harmless for convergence, noisy for
   the feed.
3. **`prune` can leave holes**: the fold drops a shard that would exceed `keep_bytes` but
   continues and may keep an *older* smaller shard, contradicting the comment "never a hole
   in the middle". Also byte-pruning can drop keys still within the 30-day dedupe horizon,
   so after a restart those entries would be re-applied (relies on apply idempotence).
4. **Handled set per process**: loaded once; entries applied by another process (CLI
   `tsync sync` while the daemon runs) are unknown to the daemon's set until restart ⇒
   possible re-application (again relying on idempotence). The set is never trimmed in
   memory.
5. **Daemon never checks `cannot_bridge`**: only `tsync sync` rebuilds when the journal was
   pruned past the mark. A long-offline daemon applies what remains and silently misses
   pruned entries until someone runs `tsync sync --full` (status shows backlog only).
6. **`get_journal_entry` swallows all errors as `None`**, so a transient read failure is
   indistinguishable from "gone"; the entry is retried next pass (not in handled), but the
   pass does not abort, and the mark advances past it.
7. **Horizon uses wall clock** (`now - 30 d`) against writer-minted timestamps; a peer with
   a badly skewed clock (> 30 days behind) would have its entries ignored by clients that
   have ever synced.
8. **Entry key collisions**: monotonic per process only; daemon + concurrent import sharing
   a uuid can mint the same key in one ms (acknowledged ponytail) — would overwrite a
   journal object and a WAL record.
9. **Stale test comment**: `open_file_guard` in `tests/scenario/sync/sync.ml` says B keeps
   its cached version while the file is open; the expected snapshot shows B converging on
   A's content immediately — there is no open-file guard in the apply path any more.
10. **Undecided policies** (conflict-gaps): kind clash with both sides published; a
    published losing write is overwritten (only version history keeps it) — detecting a
    truly concurrent edit would need more than an entry carries. Writes into a folder being
    moved aside may land at the old path.
11. **Mixed WAL records** (`prepared` with both puts and metadata) fall through to
    `replay_unpublished`, which re-applies metadata ops that were already applied locally
    (they are expected to be no-ops by facts, but this path skips `overridden_since`
    rationale of `resume_prepared`).

---


---

OCaml implementation notes for this subsystem: [ocaml/03-journal-sync.md](ocaml/03-journal-sync.md).
