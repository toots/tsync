# 06 — Backends: the store contract


Scope: the contract every backend implements, and everything that is generic over backends: the composite of several stores with roles, health and failover, deferred replica/backfill jobs, the write guard, server-side work as an optional capability, and the uplink governor that paces every remote store. Code: `lib/backends/api`, `lib/backends/uplink`, `lib/lwt/backends`.

Each implementation has its own spec:

| Driver | Spec | What it is |
|---|---|---|
| `local` | [backends/local.md](backends/local.md) | A directory on this machine or a mounted NAS. |
| `s3` | [backends/s3.md](backends/s3.md) | AWS S3 and S3-compatible services. |
| `gcs` | [backends/gcs.md](backends/gcs.md) | Google Cloud Storage. |
| shared by `s3` and `gcs` | [backends/object-store-common.md](backends/object-store-common.md) | The HTTP object-store shell, and the bucket-side functions (verify, discard) deployed by terraform. |
| `http-proxy` | [backends/http-proxy.md](backends/http-proxy.md) | Another tsync machine serving its stores. Owns the http-proxy wire protocol; the server side is [frontends/http-proxy.md](frontends/http-proxy.md). |

Abstract treatments: [data-model/backend.md](data-model/backend.md) (what a domain stores), [algorithms/replication.md](algorithms/replication.md) (several stores with roles), [algorithms/uplink-governor.md](algorithms/uplink-governor.md) (the rate law), [algorithms/failure-model.md](algorithms/failure-model.md) (error classes).

---

## 1. Problem

tsync stores a user's tree as content-addressed chunks plus small metadata objects (manifests, folder markers, journal, cursor, shares) in storage the user controls. Everything above this layer thinks in **keys and bodies**; this layer turns that into requests against a concrete service and hides:

- **which service** (S3-compatible bucket, GCS bucket, a directory on this machine, or another tsync process over HTTP);
- **how many stores** a domain has and what each is for (a source of truth, a full second copy filled in the background, a lazily filled copy, a read-only archive);
- **link health** (a store whose link is gone is passed over quickly, not retried for a minute per read);
- **upload pacing** (writes over a shared WAN link are admitted at a rate chosen from measured queueing delay, so tsync does not saturate the user's uplink).

It is a separate abstraction because the domain logic (sync, GC, mirror, checkout) must be written once against a minimal, honest contract, and because the multi-store composite must itself *be* a store (same interface), so callers never know whether they face one bucket or five.

Layering rule (`lib/backends/dune` comment): "A backend sees lib/model and lib/utils and nothing else in the tree: it knows how bytes are stored and found, never what the domain does with them." The only domain knowledge leaking in is injected as functions (`chunk_keys` for Deferred, `excluded`) or is the shared key-layout module `Chunk_layout`.

Process-global state owned here: the driver registry, the drain hooks, the default batch-read pool, the uplink process governor, and the list of resumable deferred targets. There is exactly one of each per process.

---

## 2. Concepts & data model

### 2.1 Keys

`Stored_key.t` (lib/core, abstract string). Constructed only by a namer (`in_space ~prefix path`) or taken from a store listing (`listed s`). There is no `of_string`. Keys are `/`-separated paths; a key ending in `/` is a **directory marker** (`is_dir_key`): a zero-byte object on S3/GCS, a real directory on `local`.

The key layout of a domain on a store (chunk shards, manifests, journal, cursor, GC spaces, corruption markers, job objects, shares) is specified in [02 §2](02-remote-model.md) and abstractly in [data-model/backend.md](data-model/backend.md). A store never interprets keys, with one exception every driver shares: the chunk-key test and the corruption-marker key derived from a chunk key (`Chunk_layout.marker_key`), which decide whether a written object is a chunk to verify.

### 2.2 `file_entry`

```
file_entry = { key: Stored_key; size: int; last_modified: float (epoch s);
               etag: string option }
```
`etag` is the store's own version name (S3/GCS listing carries it, filesystem none, http-proxy passes through what its store says). It is the only validator worth caching a body against: S3 reports whole seconds, and a manifest rewritten within a second to the same length is invisible in size+mtime (`backend_intf.ml`).

### 2.3 `caps` — what a store says about a domain

```
caps = { share_url: string option;     (* share base URL if this store serves shares *)
         chunk_size: int option;        (* recommended chunk size for new files *)
         max_concurrency: int option;   (* object ops this store usefully serves at once *)
         verified: bool }               (* every chunk taken is checked against its name *)
no_caps = { None; None; None; false }
```
`merge_caps` (one definition so composites cannot drift): `share_url`, `chunk_size` = first `Some`; `max_concurrency` = minimum of the `Some`s; `verified` = `cs <> [] && all verified` (one unchecked store makes "no corruption found" mean "nothing looked"; empty list is nobody's claim).

### 2.4 `children` (batched folder read)

`{ listed: file_entry list; bodies: (Stored_key * Bigstring option) list }` — a folder's full listing plus a body for each child object.

### 2.5 Members and roles

```
role = Main | Replica | Backfill | ReadOnly         (config spellings "main","replica","backfill","readOnly")
member = { name; role; readable: bool; backend_type: "local"|"s3"|"gcs"|"http-proxy";
           config: (string*string) list (secrets masked); backend: store;
           pending/in_flight/degraded: (unit->int|bool) option  (deferred targets only);
           traffic: {uploaded; downloaded} counters option (None for local);
           local_path: string option; link: string option (None for local) }
```
`readable` is false only for a backfill target; it also means "a share link must not point into it". `Backend.main` = first `Main`; `Backend.deferred` = replicas + backfills. `named_exn` fails listing available names, or on ambiguous duplicate names.

Config (per backend object in a domain): `type`, `name`, `role` (required), `link` (default `"wan"`, refused on `local`), plus driver fields. `order_backends` stable-sorts Main(0) < Replica(1) < ReadOnly(2) < Backfill(3): **config order within a rank picks the read primary**. `validate_roles`: no main ⇒ no replica, no backfill, and at least one readOnly. A domain with no non-readOnly backend is forced `read_only`.

### 2.6 Persistent formats owned here

**Deferred job log** (per domain, per target): directory `<data_dir>/deferred-pending/<domain>/<escape(target name)>/`, one record per job via `Durable_queue.Records` (atomic write, listed in record order). `escape` keeps `[A-Za-z0-9._-]`, every other byte → `%XX` (so a name with `/` cannot escape the root). Job body is JSON, **bodyless**:
```json
{"op":"put","key":"tsync/d/manifests/…"}
{"op":"copy","src":"…","dst":"…"}
{"op":"delete","key":"…"}
{"op":"delete_multi","keys":["…","…"]}
```
Unparseable records read as `None` (logged, discarded, counted as dropped → degraded).

**Corruption marker body** (JSON, every field optional; unknown fields ignored; unparseable body = marker with nothing, never "no marker"):
```json
{"computed":"<h1>-<h2>","size":8388608,"at":1727600000.12,"reason":"EIO …"}
```
`computed`+`size` for a wrong hash; `reason` (no `computed`) for an unreadable chunk (bit rot on a failing disk is `EIO`, not wrong bytes). `at` accepts int or float.

**Verify and discard jobs**: object-store formats, see [backends/object-store-common.md](backends/object-store-common.md).
**Watch token**: `Watch_token.of_body b = String.trim (to_string b)` — the trimmed body of the watched object (the cursor). `to_wire`/`of_wire` (trim again). Compared only with `equal`.

**Local store on disk**: see [backends/local.md](backends/local.md).

---

## 3. Interface

### 3.1 The seam: `Backend_intf.S` (every driver and the composite)

Quoted in pseudo-signature; all are `io`-returning; keys are `Stored_key.t`.

| Operation | Contract |
|---|---|
| `put key data` | Last-writer-wins write. Must not expose a partial object. |
| `get key` | Body or raise (missing = permanent failure). |
| `get_opt key` | `None` iff key absent; any other failure raises. Saves HEAD+GET. |
| `get_range key offset length` | `length > 0`. Exactly `length` bytes, fewer only where the object ends (possibly 0 when `offset ≥ size`). **More than `length` is a failure** (`Backend.checked_range` raises `Backend_error "…asked for N bytes, got M"`): a store that ignored the range must be distinguishable from one that honoured it. `None` for absent key. |
| `put_if_absent key data` | Atomic claim: write only if nothing is there; return what is there afterwards — `data` itself (physically the same buffer) if this call won, the other writer's body if not. Only for claim keys (folder identity); content is either content-addressed or single-owner. Must be a real server-side precondition, never HEAD+PUT. |
| `head_opt key` | `file_entry option`. |
| `delete key` | Returns whether an object was there (a folder-marker move needs it: a silent no-op delete leaves a folder at two paths). |
| `delete_multi keys` | Delete all or raise. Absent keys are success (GC sends every copy the same list; resumed runs repeat). Driver pages over service limits. **Per-key failures inside a 200 bulk answer must be read and raised** (as Transient), except codes `NoSuchKey`/`NotFound` (`Backend.absent_code`). |
| `copy src dst` | Server-side or emulated copy. |
| `list_prefix ?max_keys prefix` | All entries under the prefix (recursive, flat). `max_keys` stops pagination once reached. An empty list is a real answer. |
| `watch key last_seen` | Returns when `key` *may* have changed, or after a bounded store-chosen wait. Early wake allowed, late not; callers re-read and compare. Always bounded (a watch that cannot fire must slow, not stop, a caller). `last_seen` lets a store answer at once if its value already differs. |
| `get_many : optional capability (entries -> [(key, body?)])` | Native multi-GET or `None`. If `Some`: every key answered exactly once in request order; absent → `None`; driver pages; per-key failure **raises** (a caller told "absent" writes a mirror missing the file). Only http-proxy declares one. |
| `list_many : optional capability (prefixes -> [(prefix, children)])` | Many folders' listing + child bodies in one request; answered in request order; the store may stop early / skip folders (caller asks those singly). Only http-proxy. |
| `verify_all chunk_prefix` | Queue a server-side whole-store check → `Queued n` (units queued, not findings) or `Unsupported`. |
| `discard chunk_prefix run name keys` | Hand unreferenced chunks to the store's server-side deleter → `Queued` (request durably stored before return; never detached) or `Unsupported` (caller falls back to `delete_multi`). A store must never wrongly claim `Queued`. |
| `capabilities prefix` | `caps` for the domain `prefix` identifies. |
| `fast_read : bool` | Whether reading more than asked (a whole cache chunk) is cheaper than a range. True only for local. |
| `local_path : string option` | Grants filesystem access to the store's tree (read/rename/remove), used by GC's rename-based collection and space reports. |
| `health : Health.t` | Per-member link health cell; `Health.always_up` for a linkless store. |

Exceptions / classification:
- `Backend_error msg` — the store's considered answer that an object is absent / not as recorded. Always `Permanent`.
- `Not_writable` — every backend is readOnly; printed as `no writable backend: every backend in this domain is "readOnly"`. Its own exception so a frontend maps it to EROFS without matching prose.
- `Retry.Failed {kind: Transient|Permanent; op; detail}` — what drivers raise.
- `Backend.classify` = `Not_writable|Backend_error → Permanent`, else `Retry.classify` (a `Failed`'s kind; **anything unrecognised is Transient**).
- HTTP status mapping (`Http_client.failed`): `5xx` and `429` Transient; every other 4xx Permanent.

### 3.2 Process-wide services (one instance per process)

- `batched_get_many(store, entries, ?slots)` — the only way callers batch-read. If `B.get_many = Some f`: `entries` packed into runs of ≤ 256 keys **and** ≤ 8 MiB of listed sizes (`max_batch_keys`, `max_batch_bytes`; a single entry over budget goes alone), runs issued through the slot pool, results concatenated. Else: `get_opt` per key through the pool. Default pool: one process-wide semaphore of 32 ("batch reads"). Pool is taken once per path — never a run holding a slot while its keys wait for others (nesting deadlock).
- `on_drain f` / `drain ()` — background-work settle hooks run in parallel before a one-shot process exits.
- Registry: `register ~spec name factory`, `spec_for`, `types` (sorted), `make ?traffic ?admission ~backend_type ~get_field ()`. Drivers self-register at startup; `s3` may be absent from a build (the registry then simply lacks it; `types()` is what a UI offers). `make` raises `Failure "unknown backend type: …"`.
- `make` wraps every store whose `local_path = None` in **`counted`**: `put`/`put_if_absent` go through the admission gate (`acquire ~bytes` before, `completed ~bytes ~elapsed` on success, `abandoned ~bytes` on failure), and body bytes are added to both the process-wide `Metrics` counters and the store's own `traffic` pair (`put`: up; `put_if_absent`: up, plus down of the winner's body iff `held != data` physically; `get/get_opt/get_range/get_many/list_many`: down). Local stores are neither counted nor gated.
- `max_batch_folders = 64`, `max_batch_bytes = 8 MiB` are shared by both ends of the wire. `default_watch_interval = 2.0 s` (a store caps writes to one name at ~1/s, so polling faster only spends requests).

### 3.3 Field specs (registry → `tsync config --edit`)

Every backend object in a domain has `type`, `name`, `role` (required) and `link` (default `"wan"`; refused on `local`), plus the driver's own fields. Each driver registers a field spec (name, label, type, default, secret flag) that `tsync config --edit` prompts for and status reports mask. The per-driver fields are in each driver spec.

### 3.4 Other interfaces here

- `composite(mains, target_constructors, archives) -> Store` (§4.3).
- `deferred_target(...) -> Target` with `accept(op)`, `skip(key)`, `readable: Store?`, `stats()`, `backend`, `name`; process-wide `release(root,name)`, `start_resumed()`, `set_on_recorded(fn)` (§4.4).
- `write_guard.ensure(members, cursor_key, what, dst)` and `probe(store, cursor_key)` (§4.5).
- `object_store_shell(verbs) -> Store`: see [backends/object-store-common.md](backends/object-store-common.md).
- The http-proxy wire contract: see [backends/http-proxy.md](backends/http-proxy.md).
- `Uplink`, `Uplink_budget`, `Uplink_control`, `Uplink_lease` (§4.9).
- `Verifier.queue`, `Discard_job.{queue,encode,decode}`, `Corruption_marker.{to_string,of_string}`.

---

## 4. Behaviour / algorithms

### 4.1 Retry ladder and health (shared by all remote drivers)

`Retry.with_retry` (lib/core): up to 8 attempts; delay before attempt n+1 = `min(20, 0.5·2^(min 10 (n-1))) × U[0.5,1.5)`; `Cancelled`/`Shutdown.Stopping`/clock-cancellation are never retried; a Transient failure reports `Health.lost`, a success or a *Permanent* failure reports `Health.answered` (a considered "no" proves the link is up). Timeouts are tallied separately (`Health.timed_out`) — the uplink governor reads that tally. Retries sleep interruptibly: a stop does not wait out a backoff.

`Health.t` per member: trips after ≥ 2 consecutive failures spanning ≥ 1 s (`trip_after`, `trip_span`); failures more than `hold_initial` apart restart the run. Held for 30 s, doubling to 300 s each time the probe fails. `check` → `Up | Held | Probe` (exactly one caller per expired hold gets `Probe`, and taking it pushes the hold out so a probe that never reports back is retried at the next expiry). `is_down` = tripped and not heard from since (even if the hold expired). `on_held` watchers fire when the member goes/stays out. `probe_timeout = 10 s`.

`Health_wait.until_held h ask` races `ask ()` against "h went out" and cancels `ask` with a Transient `Retry.held` failure — so a request to a member found down elsewhere stops climbing its ladder.

HTTP clients (`Http_client`): pooled keep-alive connections (idle keep 60 s, ≤ 32 parallel per client), redial once on an unusable pooled connection; `timeout` is a **stall detector** (time without a byte of the answer), not a latency budget. http-proxy: 300 s; gcs: `Uplink_budget.stall_timeout` (60 s). `call_retry` raises on transient statuses so the ladder retries; other statuses return for the verb to interpret (404 included).

### 4.2 Drivers

How each driver realises the contract (requests, conditional writes, listing, ranges, error mapping, capabilities, watch) is in its own spec: [local](backends/local.md), [s3](backends/s3.md), [gcs](backends/gcs.md), [object-store common](backends/object-store-common.md), [http-proxy](backends/http-proxy.md). Summary of the choices that differ:

| | local | s3 | gcs | http-proxy |
|---|---|---|---|---|
| `put_if_absent` | temp + fsync + `link` (EEXIST = lost) | `If-None-Match: *` | `ifGenerationMatch=0` | arbitrated by the server's composite |
| `watch` | directory watch, 2 s cap | 2 s sleep | 2 s sleep | 30 s long-poll |
| `verified` | = `verifyWrites` | assumed (bucket function) | assumed (bucket function) | inherited from the server |
| `verify_all` / `discard` | Unsupported | job objects in the bucket | job objects in the bucket | Unsupported |
| `get_many` / `list_many` | none | none | none | native |
| `fast_read` / `local_path` | true / root | false / none | false / none | false / none |
| Stall timeout | — | none | 60 s | 300 s |

### 4.3 The composite: `Domain_store.make ~mains ~targets ~archives`

Inputs: `mains` and `archives` are `{name; backend}`; `targets` are constructors taking `~source`. If any targets exist: register the drain hook once per process; build `source = make ~mains ~targets:[] ~archives:[]` (**mains only** — a target must never re-read from a copy that is itself behind, because a job is consumed once it succeeds and a wrong body would never be corrected); instantiate each target with it.

`readable = mains @ [targets whose readable = Some _]` in order; `writers = mains`.

**Writes** (sequential over mains in order, then `fill`):
- `put`: `iter_s put writers`, then for each target in order: skip if `D.skip key` else `D.accept (Put{key;data})`. No mains → `Not_writable`.
- `put_if_absent`: arbitrated by the **first main alone** (asking each in turn would let two clients each win somewhere); the held body is then `put` to the remaining mains and filled to targets as a Put of the held body.
- `delete`: delete on every main; result = any removed; fill Delete.
- `delete_multi`: on every main; per target, the keys it does not skip, as one `Delete_multi`.
- `copy`: on every main; fill `Copy` (skip decided on `dst_key`).
- A write returns once **all mains** have it and each target has *durably recorded* the job (not once it landed).

**Reads** — `walk chain`: for each member `s` with `rest`:
- `ask_member`: if it is the last candidate (no `rest`, and no archives after when `others_after`), ask it unconditionally (a held member is still the only one). Otherwise: if `probing` (default), `Health.check`: `Held` → fail fast with `Retry.held`; `Up`/`Probe` → ask under `until_held`. If not probing (watch, capabilities): `is_down` → fail fast, else ask.
- On exception: log a warning once (only if the member is not already known down) and continue with `Err exn`.
- `Got (Some v)` → answer. `Got None` → with `stop_on_miss` the first reachable member's miss is the answer (`Miss`); else continue.

`read f`:
1. walk `readable` with `stop_on_miss = true`, `others_after = archives <> []`.
2. If answered → `Some v`. Otherwise walk `archives` with `stop_on_miss = false` (archives hold *different* content, so each is asked).
3. Archive answer → `Some v`. Archives all unreachable → raise the first phase's unreachable error if any, else the archive's. Clean miss everywhere → if phase 1 was unreachable, **raise** its error (never turn "could not look" into a confident ENOENT), else `None`.

Consequence (tested): main + replica, main reachable and missing → `None` (a replica miss is not consulted: same content). Main unreachable → replica answers. Archives are consulted both on a source-of-truth miss and when it is unreachable.

Verbs on top of `read`: `get_opt`, `get_range`, `head_opt`; `get` = `get_opt` then, on `None`, `Retry.failed Permanent "get" "not found: <key>"`; `list_prefix` = first reachable store's listing, **never merged**, `None → []`; `watch` = `read ~probing:false` (a 30 s long poll must never be the request spent finding out whether a member is back).

**Batches** (`get_many`, `list_many`): declared only if the *first readable member* declares one, and forwarded to it directly (not through `Batched`: the caller already holds a slot from the same pool — taking a second deadlocks). If there are ≥ 2 readable members, the batch goes through `ask_member ~others:true` on the head. On exception: if the head is now down (`passed_over`) → answer `[]`; Transient → re-raise (a lost link would lose every key the same way); Permanent (refused) → warn, answer `[]`. `get_many` then re-asks every key the batch did not return with a body via `read` (sequential per key: misses are rare because the keys came from a listing of the same store, and `read` keeps archive fallback + unreachable-vs-absent). `list_many` returns `[]`/partial and the caller asks folder by folder.

**verify_all**: if `Write_guard.State.state mains = Ok` ask all readable members, else only writers (publishing markers onto a copy is a write); sum `Queued n`; `Unsupported` only if every member was. Backfill targets are never reached (`tsync data-integrity --verify` asks every configured member instead).

**discard** → always `Unsupported` at the composite: `Gc` asks each member itself so stores with and without a deleter are handled differently.

**capabilities**: asked of readable members not currently held (all of them if every one is held), `probing:false`; a member that fails and is down is passed over when others exist; if nobody answered and something was passed over, raise (an empty merge would be memoised as fact by callers). Archives have no say. Merge with `merge_caps`.

`fast_read` = first main's. `local_path = None`. `health = always_up` (the domain is not a member).

### 4.4 Deferred targets (replica and backfill)

One implementation, one bit: `reads_reach` (`= role = Replica`). A resynced backfill is promoted by changing one config word.

`make ?resume ?chunk_from_prefix ?max_chunk_forwards(=32) ?room_for ~name ~backend ~source ~chunk_prefix ~chunk_keys ~journal_prefix ~cursor_key ~excluded ~reads_reach ~root`:

- `skip key` = `excluded key` (the caller passes `Stored_key.is_index_key` — folder index caches describe the store that wrote them) `|| (not reads_reach && (key under journal_prefix || key = cursor_key))`.
- `accept`:
  - `Put` of a key under `chunk_prefix` → **chunk forward** (best effort, not recorded): skipped if the queue is not running here, the chunk is already known ensured, `chunks_in_flight ≥ max_chunk_forwards` (the daemon passes `maxChunkBuffers`, since a forward keeps a body alive past its buffer), or `room_for ~bytes` (the target store's uplink `try_admit`) says no. Otherwise async `Target.put`; success → remember ensured; failure → warn only. Chunk forwards never block the write and never queue in memory.
  - other `Put` → `Job_put key`; `Copy` → `Job_copy(src,dst)`; `Delete` → `Job_delete`; `Delete_multi` → `Job_delete_multi`.
  - `post`: if running here, `Q.post` (durable then queued); else `Q.record` (durable only) and call `on_recorded` (lets a one-shot command poke the daemon to pick it up).
- Queue: `Durable_queue.ordered` — **one worker, record order, head blocks on transient failure** (so a rename's copy never overtakes its delete), `classify = Backend.classify`, `poison = Drop` → a permanent failure unlinks the record and marks the target **degraded** (needs `tsync mirror --source <main>`; patience will not fix it).
- Job execution:
  - `Job_put key`: `Source.get_opt key`; `None` → done (deleted since; a later delete job says so). Else for each chunk key named by the body (`chunk_keys`: manifest parse, `[]` for non-manifests) run `ensure_chunk` **sequentially**, then `Target.put key body`. Invariant: *a manifest reaches a target only after every chunk it names is confirmed there* — "partial coverage, never partial files".
  - `ensure_chunk c`: key = `chunk_prefix/<shard>/c`; if in `ensured` → done; else `learn_shard` (list the target's shard prefix once, fold every key into `ensured`, mark shard known); if now present → done; else fetch body from source (`get_opt`; if absent and `chunk_from_prefix` set, from `chunks.from/<shard>/c`, else `get` to raise) and `Target.put` at the **plain** chunk key.
  - `ensured`/`known_shards` memo capped at 100 000 keys; past it **both** tables are reset (a key forgotten while its shard stayed "known" would never be relearned). Deleting via jobs removes keys from `ensured`.
  - `Job_copy(src,dst)`: `Target.copy`; on any failure except `Stopping`, fall back to `run (Job_put dst)` (target lacks `src`: added after it was written, or its job was dropped). A copy cut short by a stop stays owed (not rebuilt) — c3c4a983.
  - `Job_delete`, `Job_delete_multi`: target delete(s).
- `resume`: only the daemon passes it. A resuming target is built **stopped**; `start_resumed ()` (once per process, by the process that will run them — after the daemon forks frontends, otherwise every child would run the queue too) starts them with `recover:true`. One-shot commands record and drain their own jobs but never run another process's (two runners would reorder a rename's copy and delete). `release ~root ~name` drops this process's claim (lock) on the log dir.
- Settling: `Queues.register_settle chunks_quiet` waits for in-flight chunk forwards; the composite's drain hook calls `Queues.settle_all`.
- `stats = {queued; in_flight = chunk forwards; degraded}`.

Why bodyless jobs: repeated puts to one key converge on the latest body; a put whose key was deleted reads nothing and is skipped; the log stays small. Why one record per user-visible op rather than per chunk: dedup means a copy/re-upload issues no chunk PUTs at all, and correctness rests entirely on the manifest job's chunk check (`deferred.ml`).

### 4.5 Write guard: never write a copy while the main is offline

`ensure(members, cursor_key, what, dst)`: if `dst.role = Main` → allowed (that is how a main is refilled from a replica). Otherwise `look`: probe every main that is unsampled, or down with an expired hold (a main heard from and up is taken at its word — one look per run of guarded writes). `probe` = `get_opt cursor_key` under `until_held`, bounded by `Health.probe_timeout` (10 s) including retries; on timeout call `Health.probe_lost` (the deadline cancels the request, which would otherwise tell the cell nothing). Then if any main is down → fail **Transient**: `refusing to <what>: the main "<n>" is not online (<why>). A replica is never written while the main is offline, or it holds what nobody can check`. A domain with no main → `Ok`. Used by every command that writes a named member directly (mirror, data-integrity repair/verify, etc.); the composite's own writes cannot violate it because targets only ever receive what a main took.

### 4.6 Server-side work (verify and discard)

`verify_all` and `discard` are optional capabilities: a store either queues the work durably and answers `Queued`, or answers `Unsupported` and the caller does the work itself (GC falls back to `delete_multi`, integrity to a client-side sweep). A store must never claim `Queued` wrongly, and GC may discard a copy's chunks only after `Queued` returned. The object-store drivers implement both by writing job objects that a bucket-side function consumes ("the bucket is the queue"): see [backends/object-store-common.md](backends/object-store-common.md).

### 4.7 Corruption markers — lifecycle

Filed by: local driver on every chunk write (verifyWrites), the cloud function on every chunk object-created event and every verify job. Cleared by: a good rewrite of the chunk (local: after verify; cloud: marker deleted before checking), or a GC discard that removes the chunk (the function derives and deletes the markers; local driver prunes dirs). A marker's existence is the finding; `verified` caps say whether anyone is looking.

### 4.8 The http-proxy wire protocol

Specified in [backends/http-proxy.md](backends/http-proxy.md) (both sides of the wire and the client driver). The server is [frontends/http-proxy.md](frontends/http-proxy.md).

### 4.9 The uplink governor

The control problem, the law and its properties are specified abstractly in [algorithms/uplink-governor.md](algorithms/uplink-governor.md). This section is the current implementation: records, constants, the lease wire and the config.

Goal: write each link (a named network path, default `"wan"`; a backend's `link` field) at a rate chosen from **queueing delay**, LEDBAT-shaped (RFC 6817), so background uploads leave room for other users of the connection. Upload only; reads are never gated (the user is waiting).

#### Admission record (the seam between stores and gates)
```
admission = { acquire: bytes -> io;              (* returns once bytes may be sent *)
              completed: bytes -> elapsed -> unit;
              abandoned: bytes -> unit;
              now: unit -> float;                 (* monotonic *)
              waiting: unit -> int;
              try_admit: bytes -> bool }          (* pure; valid until the turn yields *)
```
A record of callbacks (an interface value, not a compile-time type) so a store built once can be handed any gate. `unbounded`, `capped ~rate` (a per-store budget; **not used in production any more** — see §9), `compose a b` (ask a then b, tell both), and the process governor's `admission link class_`.

#### `Uplink_budget` (pure, handed `now`)
- Token bucket: `rate` B/s (floor 1), depth `burst = rate × burst_seconds(2)`; starts full; refill `min(burst, tokens + rate·Δt)`.
- A body asks `min(bytes, burst)` tokens; `take` subtracts the full size (bucket may go negative: an oversize body is admitted on a full bucket and the debt is paid off before the next).
- In-flight window: `window = rate × stall_timeout(60 s) × window_safety(0.5)`. Admit iff `tokens ≥ asks && (in_flight = 0 || in_flight + bytes ≤ window)`. One body always goes alone when nothing is in flight, however large. Rationale: a body is sent whole and unheard; one queued behind others crosses only after them, so past the window it would hit the stall timeout before it arrived.
- `wait_for` = 0 if admissible now, `∞` if only a `release` can help (window full), else `(asks − tokens)/rate`.
- `set_rate` refills at the old rate up to now, then clips tokens to the new depth.

#### Gate (FIFO line over a budget)
- `acquire`: if `room` → take synchronously (no bind between check and take). `room` = (queue empty, or `bytes ≤ small_body(64 KiB)` and `overtaken + bytes ≤ head's size`) and budget admits. Small bodies (cursor, journal entry) may pass a waiting chunk, but in total by no more than the head's own size. Otherwise set `held_back`, enqueue, arm a single timer for the head's `wait_for`.
- `pump` wakes in order every head the budget admits; `arm` sets at most one timer; a completion/abandon releases in-flight bytes, then pumps and re-arms (a head blocked by the window is freed by a completion, not a timer).
- `cancel_waiting exn` fails every waiter having taken nothing (on shutdown: the work is owed on disk).

#### `Uplink_control` — the law (pure)
Settings: `enabled` (default true), `headroom` 0.8, `target_delay` 50 ms, `min_rate` 64 KiB/s, `max_rate` none. Constants: `initial_rate` 256 KiB/s, `tick_interval` 2 s, `probe_timeout` 10 s, `gain` 0.25, `decrease_floor` 0.5, `base_window` 600 s (10 cells × 60 s, min), `rate_window` 10 s (1 s cells, sum), `probe_up_every` 60 s, `backoff_hold` 10 s.

Inputs: `completed now bytes elapsed` spreads `bytes` evenly over `ceil(elapsed)` (≥ 1) one-second cells back from now (a long body must not read as a burst then nothing). `observe_delay ?path now d` queues samples. `timed_out`. `dropped` (counter only). `achieved = sum(rate_window cells)/10`.

`read_delay` each tick: no samples → `queueing ← 0.5·queueing` (decay). Else for each sample, update that path's base-min window and compute `max(0, d − base(path))`; `current = min over samples`; `queueing ← 0.5·queueing + 0.5·current`. Per-path bases because stores on one link sit at different distances; the far one alone would read its distance as a queue.

`tick now limited`:
```
over_target := (q > target) ? over_target+1 : 0
off := clamp((target − q)/target, −1, 1)
limited := limited && achieved > 0          (* grow only while bytes are completing *)
Ramping:
  if q > target && over_target ≥ 2:          (* two ticks: one probe behind one body is noise *)
     step := never_saturated ? 2 : 1+gain; never_saturated := false
     capacity := max(achieved, min(rate/√step, 2·achieved if achieved>0))
     → Steady; next := max(rate·0.5, headroom·capacity)
  elif q ≤ target/2 && limited: next := rate × (never_saturated ? 2 : 1+gain)
  else next := rate
Steady:
  if q ≤ target: settled := true
  elif settled && over_target ≥ 2: capacity := min(capacity, achieved)   (* someone else took a share *)
  if now − since ≥ 60: → Ramping (lift the ceiling to discover a freed link)
  next := (off > 0 && not limited) ? rate : rate × (1 + gain·off)
Backing_off:
  if now − since ≥ 10: → Ramping ; next := rate
rate := clamp(min(next, ceiling), min_rate, max_rate)
   where ceiling = ∞ while Ramping or capacity unknown, else headroom × capacity
timed_out: capacity := min(capacity, achieved) (if achieved > 0); never_saturated := false;
           → Backing_off; rate := clamp(rate × 0.5)
```
`limit` for reports: `Configured` once rate ≥ 0.999·max_rate; else `Measured` if capacity known; else `Estimating`. Growth only when *held back* (a body waited or was refused since the last step) — otherwise an idle daemon reached "terabytes a second" and read its capacity off a rate that never met an edge (80b5e045).

#### Process governor
A process has `links : name → link` (made on first mention with `overrides[name]` else `defaults`; `configure` is applied once per process, before the first store, from config `uplink` and `links`). Each link: one `Uplink_control` (law), one `Uplink_budget` share (what *this process* admits against), one gate, attached probes, and for an owner a `Uplink_lease` table.

Modes (per process, for all links):
- **Owner** — the daemon (`own` before its engines start; starts the ticker). Runs each link's law, splits the rate among lessees (its own writes are a lessee row), answers renewals.
- **Leased** — every command/job beside the daemon and every forked frontend (`lease_through ~send` over the daemon's sync socket, 1 s timeout per renewal). Runs no law; admits at the granted rate.
- **Local** — no daemon, or it refused (old build), or 3 renewals in a row unanswered; runs laws itself; retries the daemon every 30 s.

Ticker (one loop per process, started lazily on first `acquire`/`try_admit`/`attach`): sleeps `interval` (lessee: owner-given; else 2 s). Leased: for each used link, probe round (own in-flight only) + own report → one renewal. Owner/Local: `step` each used link, then maybe retry the daemon.

`step link`: timeouts since last step (sum of attached stores' `Health.timeouts` deltas + lessees' reported) > 0 → one `timed_out`; lessee completed bytes → `completed` spread over one tick; probe round (only if anyone has bytes in flight: probes are billed requests) — each attached, not-held store's probe (`head_opt cursor_key`) timed; a probe that times out counts as `probe_timeout` seconds (enormous delay → hard cut); probe failures otherwise ignored (health is the retry loop's business); feed delays; build own report; `limited` = own or any lessee `wants`; `tick`; owner → `split` and set own share to `own_rate`; local → share rate = law rate; log state changes; pump/arm.

Wire (JSON line over the daemon's IPC socket):
```json
→ {"action":"uplink","pid":1234,"links":{"wan":{"inFlight":8388608,"completed":16777216,"timeouts":0,
     "waiting":3,"heldBack":true,"probeMs":41.2,"probesMs":{"gcs":41.2,"s3":55.0}}}}
← {"ok":true,"interval":2.0,"links":{"wan":{"rate":1250000.0,"limit":"measured"}}[, "rate":1250000.0]}
```
The top-level `rate` is added for a lessee that asked in the old one-link (flat) shape. An answer without `links` is a refusal. A link named by a lessee but unknown to the owner is created for it on the owner's settings, its law run from the lessee's probes. `probeMs` (least) is sent alongside `probesMs` for old owners; old lessees without `heldBack` are read as held back iff `inFlight > 0`.

`Uplink_lease` split (max-min fair, water-filling): each party's usable cap: `wants` (waiting > 0 or held_back) → ∞; bytes in flight → `max(min_rate, 1.25 × completed/interval)`; else `min_rate`. Sort by cap ascending; each gets `max(min_rate, min(cap, remaining/left))`; leftover split evenly among all (costs nothing, lets a waking lessee burst). `held_back` is consumed by the split. Lessees silent for `3·interval + probe_timeout` are dropped. A lessee not in the last split gets `max(min_rate, last_total/(1+live))` at once (a job beside a daemon does not start cold). Owner's own grant before any split = total.

`try_admit` (the chunk-forward drop path): enabled and room now → true; else mark held_back, count a drop, false. Disabled link or Foreground class → always admits. Every store uses `Background`; `Foreground` exists for a future download path.

Status JSON per link: `enabled, state (ramping|steady|backingOff|leased), limit, maxRateBytesPerSec, rateBytesPerSec, capacityBytesPerSec, baseDelayMs, queueingDelayMs, inFlightBytes, windowBytes, drops, headroom, targetDelayMs, waiting, mode` + owner's `ownRateBytesPerSec`, `lessees[{pid, rateBytesPerSec, inFlightBytes, waiting, heldBack, probeMs}]`. Dormant links (no probes, never used, no live lessees) are kept but not listed.

Config (`uplink` top-level and `links.<name>` overrides, field by field): `enabled`, `headroom`, `targetDelayMs`, `minRate`, `maxRate` (sizes); `maxRate < minRate` refused; a `links` name no backend uses refused. A per-store ceiling = give that store its own link name and cap the link.

---

## 5. Interactions

Depends on (below): `lib/core` (`Stored_key`, `Chunk_layout`, `Chunks`/`Xxhash`, `Retry`, `Health`, `Http_client`, `Durable_queue`, `Metrics`, `Field_spec`, `Log`, `Shutdown`), `lib/io` signatures (`Io`, `Bounded`, `Clock`, `Lock`, `Fs`, `Syscalls`), `Device.max_concurrency`, the directory watcher (`Watch_lwt`), cohttp, aws-s3, digestif/eqaf/base64/x509/mirage-crypto.

Used by (above), through `Backend.S` and `member` lists carried on `Conf.S` (`C.store` = composite, `C.members`):
- **Domain config** (`lib/domain/config/domain/domain.ml`): the only place roles become behaviour — builds leaves via registry with per-store traffic + link admission, attaches a probe per remote store, builds deferred targets (`chunk_keys` = manifest chunk list, `excluded = is_index_key`, `reads_reach = role=Replica`, root `<data_dir>/deferred-pending/<domain>`, `max_chunk_forwards = maxChunkBuffers`, `room_for` = the store's admission `try_admit`, `chunk_from_prefix` = `chunks.from/`), then the composite and the member list.
- **Content/remote layer** (chunk upload/download, manifests, cursor/journal sync, inode tree walk using `list_many`/`get_many`), **GC/Collection** (uses `local_path` renames on the main, `discard` per member, `delete_multi`, `verify_all`), **mirror/resync** (copies between named members, guarded by `Write_guard`), **data-integrity** (lists `corrupted/`, `capabilities.verified`), **shares** (`capabilities.share_url`, `readable`), **status/diagnostics** (member rows, `Health.json`, deferred stats, uplink `json_links`), **frontends** (http-proxy server wraps a domain's composite; fuse/file-provider read via `C.store`), **launcher/CLI** (`own_links`, `lease_from`, `lease_renewal` over the sync socket, `start_resumed`, `drain`).

Main data flows:
1. *Chunk upload*: content layer → composite `put chunkkey` → `counted` gate acquire (may wait on link) → each main driver `put` → per target: `forward_chunk` (if room/memory/not known) → return.
2. *Manifest publish*: composite `put manifest` → mains → per target `Job_put` durably recorded → worker later ensures every chunk on target (shard listing, source fetch) then puts manifest.
3. *Read with main down*: composite `read` → main `Health.check = Held` → fail fast → replica answers; one caller per hold probes the main.
4. *Remote client via proxy*: client driver signs → proxy verifies/routs/gates → server's composite → framed/streamed answer.
5. *Cursor watch*: sync engine → composite `watch` (non-probing) → proxy long-poll / local dir watch / 2 s sleep → re-read cursor.
6. *GC on a cloud copy*: Gc → member `discard` → gc-job object → bucket notification → function deletes chunks+markers → deletes request.

### 5.1 How each host repurposes the backend stack

Every host builds a domain's stores the same way — config → registry → per-store traffic counters + link admission + probe → deferred targets → composite + member list (`lib/domain/config/domain/domain.ml`) — and differs only in which process-wide roles it takes.

| Host | Builds stores with | Deferred queues | Uplink role | Notes |
|---|---|---|---|---|
| **Daemon parent** (`tsync start`, launcher) | `resume = true` for every domain | Built *stopped*; `start_resumed()` after the frontends are forked, so it is the only runner; its IPC `rescan` action re-scans the logs when a child records a job | **Owner**: `own()` before engines start; answers `{"action":"uplink"}` renewals | Also runs each domain's converge engine. |
| **Forked frontend children** (fuse mount; **http-proxy server**) | Inherit the stores built before the fork (`resume = true`, stopped) | Never run; `accept` only *records* the job and calls `on_recorded` → IPC `rescan` to the parent | **Leased** from the parent's sync socket | The http-proxy server wraps each served domain's composite as a *route*: its object API is a thin, authenticated, gated re-export of the composite's `Store` operations (§4.8), so the server applies its own replicas/backfills/archives/health transparently and a client never sees roles. It also exports the composite's `capabilities` (verified, share URL), its config's chunk size, and the listener bound derived from `merge_caps(...).max_concurrency`. It coalesces `watch` per key over the composite's `watch`. It has no journal/sync of its own beyond what the parent runs, and it may additionally serve `/s/` share links from the same stores. |
| **One-shot CLI commands** (gc, mirror, data-integrity, sync, …) | `resume = false` | Started at once; run only jobs *this process* recorded (no recovery of others' logs); `drain()` settles them before exit | **Leased** from the daemon if one answers; else **Local** (own law), retrying the daemon every 30 s | Direct member writes go through `write_guard.ensure`. |
| **Android app** (JNI host, `android_jni.ml`) | `of_config` with default `resume = false`; no fork | Started at once, in-process (no recovery of a previous run's log — see §9) | Never leases or owns → **Local** | Same drivers; typically an http-proxy or cloud main. |
| **Remote http-proxy client** (any of the above whose backend is `type: http-proxy`) | The `http-proxy` driver is just another leaf store | — | Its link is governed like any remote store | Inherits chunk size, max concurrency, verified and share URL from the server via the capability endpoints. |

The macOS File Provider host is covered by its own spec; from this layer's point of view it is another store-building host.

---

## 6. Concurrency, durability & failure semantics

- **Atomicity**: local writes are temp+fsync+rename (put) or temp+fsync+link (claim); readers never see partial files; mmapped reads stay valid across replacement. S3/GCS single-request PUTs are atomic by the service. `put_if_absent` is a true server precondition everywhere (S3 `If-None-Match: *`, GCS `ifGenerationMatch=0`, local `link` EEXIST, proxy arbitrates on its store, composite arbitrates on first main only).
- **Durability of multi-store writes**: return = all mains landed + target jobs on disk. A crash after return loses no target work (jobs replayed by the daemon with `resume`). Chunk forwards are not durable by design; the manifest job re-derives missing chunks.
- **Ordering**: one worker per target, record order, head blocks on transient errors → copy-then-delete order of a rename preserved on targets. Permanent errors drop the job and mark degraded.
- **Offline**: main down → reads fail over to readable replica (then archives), writes fail (Transient) — never redirected to a replica; direct member writes to non-mains refused by the write guard. Target down → jobs accumulate on disk, catch up when the link returns.
- **Idempotence**: all proxied ops idempotent; `delete_multi` tolerant of absent keys; gc-job consumption idempotent under redelivery; verify is re-runnable; deferred jobs converge (bodyless puts).
- **Bounds**: batch reads pool 32 (default) — callers should pass their own; verifier 32 PUTs in flight; local walk 64 stats per store, 8×8 workers; http client ≤ 32 connections; proxy listener gate `max_concurrent` (+16× queue, else 503); proxy request key limits 1024 / 64 folders; bulk answers ≤ 8 MiB of bodies per batch; chunk forwards ≤ maxChunkBuffers per target; ensured memo 100k; uplink window = rate×30 s.
- **Shutdown**: `cancel_waiting` fails link waiters (`Shutdown.Stopping`); retry backoffs are interruptible; copies cut short stay owed; `drain` settles queues and in-flight forwards before a one-shot exits.
- **Process roles**: only the daemon (after forking frontends) runs resumed queues and owns links; forked children and commands lease.

### 6.1 Correctness that relies on cooperative, single-threaded scheduling

The current implementation runs on one thread with cooperative scheduling: code between two suspension points cannot be interleaved. A rewrite with preemptive threads or parallel tasks must add explicit synchronisation (or keep these on one executor) at each of these points:

1. **Uplink admit-then-take**: `try_admit` answers "room now" and the caller's following `acquire` takes it with no suspension between (deferred chunk forward: `room_for` check → spawn → counted `put` → `acquire`; the spawned task runs synchronously up to `acquire`). Gate `acquire` itself checks `room` and `take`s in one step. With preemption another sender can take the room in between → needs a single atomic "try-take".
2. **Uplink state** (`budget` tokens/in-flight, gate queue/`overtaken`/`held_back`, law state, lessee table, process mode) is mutated from store callbacks, timers and the ticker without locks.
3. **Health cells**: `check` hands `Probe` to exactly one caller per expired hold by mutating `held_until` in the same step; `lost`/`answered` read-modify-write counters. Needs an atomic/locked cell.
4. **Deferred target**: `ensured`/`known_shards` tables, `chunks_in_flight` counter and `running` flag are unguarded; `chunks_in_flight ≥ max` check and increment must be one step.
5. **Proxy watch gates**: a waiter increments `waiters` before starting the loop, and the loop removes the gate when `waiters = 0` "with no await between the two lines" — the removal is race-free only without preemption.
8. **Proxy counters, composite `hooked` flag, `resumed_starts` list, driver registry, `Batched` default pool creation**: plain mutable globals.
9. **Claim winner detection** in the counting wrapper uses *reference identity* of the returned buffer (`held` is the very buffer passed in ⇔ this call won). A rewrite must return an explicit won/lost flag or compare pointers; comparing contents is wrong only in the sense that it costs a compare (bodies are equal by construction when won).

---

## 7. Design choices & rationale (don't undo these)

Driver-specific choices are in each driver spec.

1. **Minimal verbs + declared optional capabilities** (`get_many`/`list_many` as `option`): a store without a native batch says so and `Batched` supplies the fan-out once, so no driver picks its own concurrency width without seeing the process (`backend_intf.ml`).
2. **`get_range` is mandatory** (not derived from `get`): the generic form would satisfy callers while fetching what the range exists to avoid. Over-long answers are errors, not trimmed.
3. **Bulk delete per-key errors are raised, as Transient**: previously discarded, which made GC report success while keys stayed on a copy nothing walks again (s3/gcs comments; `absent_code` shared so drivers can't disagree).
4. **Composite `put_if_absent` arbitrated by the first main only.**
5. **Deferred targets re-read from mains only** (not the composite read path) — a job consumed from a stale copy is never corrected.
6. **Replica/backfill differ by one bit** — promotion is a config edit.
7. **Bodyless durable jobs; chunk pushes unrecorded; manifest job ensures chunks** — "partial coverage, never partial files"; log size = user ops, not chunks.
8. **Never write a replica while the main is offline** (`Write_guard`; 58a5ffaf) — otherwise it holds content nobody can check against the source of truth.
9. **"Could not look" ≠ "not there"**: unreachable stores surface errors; `None` only when every candidate was actually asked.
10. **Health holds + single probe per hold**: an 8-attempt ladder against a dead host costs a minute per read; failover within ~1–2 s instead. Long polls never serve as the probe.
11. **Listings never merged** — one store's view wins.
12. **Local verify-then-act vs cloud act(delete marker)-then-verify** — ordering chosen by event semantics (writer vs at-least-once unordered notifications).
13. **Uplink: delay-based, not throughput-based** — "two megabytes a second is all of a small pipe or half of a large one"; grow only when held back and bytes complete; capacity from geometric mean of last two ramp steps bounded by 2× achieved; two ticks over target to end a ramp; periodic ceiling lift; per-path base delay; small bodies overtake by at most the head's size (c3c4a983); daemon owns the law, others lease (a job must not start cold and N processes must not each run an independent law against one link).
14. **Uplink budget/law/lease are pure and handed `now`** (monotonic clock) — tests read decisions at chosen instants with a fake clock; wall time steps under NTP by about the lengths a rate is read over.
15. **Counting/gating in `Backend.make`**, not the content layer — GC, mirror, repair go to stores directly, so the figure must be at the store.

---

## 8. Invariants the tests pin down

Tests of a single driver are listed in that driver's spec. The conformance suite below runs the contract itself against real stores.

`tests/backends`:
- **backend_failure**: classification table (s3 503 transient, 403 permanent, Not_writable/Backend_error permanent, unknown exn & Unix error transient); retry counts (transient exhausts max, permanent/cancelled 1 attempt); health tripping after a gone link, recovery after one success, a "no" answer keeps a member up, `always_up` never held; deadline cancellation does not hold the member.
- **fallback**: exact read semantics of §4.3 (miss on reachable main authoritative over replica; archives consulted on miss and on unreachable; unreachable errors surface; read-only domain writes → Not_writable message; empty listing is an answer; unreachable main listing falls to archive).
- **held_failover**: replica not asked while main up; main asked once then passed over without waiting its ladder; in-flight request called back; batch answered key by key from replica; long poll never used as probe; single-member domain always asked; both down → error not "absent"; hold expiry: exactly one of concurrent reads probes.
- **main_down**: every write verb fails with main down and the replica is byte-for-byte unchanged and owed nothing; a previously taken write stays owed and lands when the main returns.
- **deferred**: job durable before put returns and survives a failure; permanent failure → dropped + degraded; offline target accumulates jobs; next daemon start picks them up; non-running process records (owed +1, in memory 0, told 1); replica carries journal+cursor; mains are what writes wait for; copy cut short by stop stays owed.
- **deferred_shards**: 40 manifests × 4 chunks over 4 shards → 0 HEADs, 4 shard listings, 160 chunk puts; again under new names → 0/0/0.
- **deferred_governed**: dropped forwards fetched by the manifest job; forwards asked once per chunk with exact bytes; only granted ones land before the job.
- **backfill**: chunk order, dedup hole filled, symlink manifests name no chunks, rename = copy then delete, copy with missing source rebuilt, journal/cursor not carried to backfill.
- **claim**: 5 racing claimants → 1 distinct answer = stored body; later claim returns holder, holder untouched; free name returns own body; release/reclaim; delete returns true then false.
- **get_range**: exact ranges, short at EOF (0 past end), absent → None, over-long answer refused with exact message.
- **write_guard**: probe once then trust; down main refuses non-main writes with exact message; expired hold re-probed; never-answering main bounded by probe timeout and then counted as heard; no-main domain allowed; data-integrity --verify refused with main gone.
- **probe_deadline**: never-answering backend → `"no answer within 10s"`; asked again within window answers at once with the same finding.
- **gc_targets / gc_queued / gc_cost**: collection deletes reclaimed chunks from copies, never touches chunks the main never had, never fills copies, keeps chunks re-uploaded mid-run; discard queued (not done) leaves the copy holding the chunk until consumed, re-sendable, keys intact; consumption drops chunk and its marker; collection uses only rename on a filesystem (0 `copy` calls), never lists or marks replicas.
- `tests/conformance` (real S3/GCS in CI): put/get/get_opt/head/copy/list/max_keys; get_many ordering and paging; chunk-sized bodies; 5 racing claims → one body, all told holder; delete true/false; `verified = true`; verify_all queues 4096 objects naming shards (or already consumed); discard request carries exactly the keys; the deployed function drops the chunk.

`tests/unit`: **backend_traffic** (which verbs count up/down, winner/loser of claims, local not counted, per-store vs process totals); **backend_capped** (burst 2 s, FIFO line, per-second release, abandoned body frees the line, small body overtakes a chunk); **backend_render** (status rows); **uplink_budget** (full at birth = 2 s; debt for oversize bodies; long-run rate holds; window = half stall × rate; lone oversize body; set_rate keeps earned tokens, clips depth; rate floor 1 B/s); **uplink_control** (doubling ramp, steady within 40 s at headroom of measured capacity, queue drained; lowers to competing share and recovers within a probe interval; timeout → cut ×0.5, hold 10 s, then ramp; max_rate ceiling reported `configured`; min_rate floor; no growth without being held back or without completions; base delay learning and expiry; held-down near store doesn't cut); **uplink_lease** (even split, idle floor, 1.25× usage, leftover split, stale rows after 3 intervals+probe timeout, newcomer share, heldBack spent, JSON compat); **uplink_modes** (lease/local transitions: 2 silences leased, 3rd local, refusal immediate, owner ignores lease offers; newcomer grant; owner probes for a busy lessee; per-link cuts; multi-link single request); **uplink** (gate ordering, try_admit is pure and records a drop, window wait, probes only while in flight, held stores unprobed, cancel_waiting).


---

## 9. Open questions / inconsistencies

Driver-specific questions are in each driver spec. Numbering is kept from the first extraction.

1. **`Uplink.capped` is dead in production.** `maxUploadRate` (per-backend) was added and later removed in 80b5e045's series; per-store ceilings are now "a link of its own". `capped`/`compose` survive only for `tests/unit/backend_capped`. A rewrite can drop them.
7. **Composite `capabilities`** with the main held answers from the replica alone, chunk size included (ponytail note).
8. **Domain-name collisions** with `corrupted`, `verify-jobs`, `gc-jobs`, `shares` are unchecked.
12. Deferred `ensured` memo reset is all-or-nothing (ponytail note).
15. **Android never resumes deferred logs**: it builds stores with `resume = false`, so jobs a killed app process left on disk are not replayed by the app itself (only a process built with `resume` recovers a log). Whether anything ever drains them on that device is unclear.

---

OCaml implementation notes for this subsystem: [ocaml/06-backends.md](ocaml/06-backends.md).
