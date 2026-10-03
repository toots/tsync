# C — Resource consumption

This file covers CPU, RAM, disk I/O, network round trips, file descriptors and threads. Each entry is a mechanism that already cost tsync an OOM kill, a wedged process, a saturated disk or a cloud bill. Use it in review of the OCaml 5 rewrite: for each new loop, pool, cache, body path or poller, find the matching theme and run its **Check**. Under fibers on a domain pool, a fiber per item costs the same working set as a promise per item, and a blocking call stalls every fiber on that domain.

## Reference host budget

The Pi Zero 2 W is the smallest host tsync serves. Every bound is judged against it.

- **CPU**: 4 Cortex-A53 cores. A busy-spinning worker takes a quarter of the machine.
- **RAM**: 512 MB nominal, 415-448 MB usable, 256 MB CMA, zram swap. zram compresses 2.84x on heap data and 1.54x once incompressible JPEG/MP4 bodies sit on the heap.
- **Disk and network**: one USB 2.0 bus shared by both disks and the network. A USB Bulk-Only Transport disk takes one command at a time. An SMR drive under small scattered writes hit about 95% iowait and 60-180 s command timeouts. A disk-to-disk copy on the same bus took the host down.
- **Links**: uplinks measured at about 13 Mbit/s and 1.5 MB/s; a 150 ms round trip to GCS.

Measured numbers from the material:

| What | Number |
|---|---|
| OOM kill, import of 22,378 photos | died at 19,132 files, 128-176 MB anon |
| OOM kill, previous build | 176 MB anon |
| OOM kill, mirror resync (552,135 objects) | 145,500 kB anon RSS; mirror went 35 to 96 MB in 4 min |
| OOM kill, proxy child serving a 22,504-child folder | about 280 MB |
| OOM kill, FUSE writers (8 x 16 MB groups) | 10 kills per session, available 201 / 132 / 121 MB |
| 1.1 TB import heap growth | 34 MB to 108 MB after 483 GiB (r = 0.98 with bytes), about 900 B per chunk |
| Blocking-thread pool at 256 threads | settled at about 114 MB |
| Self-waking watch loop | 140 wakes/s for 5 days, 1d12h CPU, OOM every 15-35 min via XFS slab (RSS flat at 55 MB) |
| Startup walk of 235k manifests | 2m57s at 0.3% CPU (4.8 s without serialisation) |
| Rewrite rebuild, 258k manifests | peak 1.8 GB unbounded look-ahead, 887 MiB bounded by position |
| Rewrite after rebuild | 765 MiB resident for an 81 MiB heap; 155 MiB after compact + `malloc_trim`; 325 MiB with `MALLOC_ARENA_MAX=2` |
| Rewrite 20k-file import, retained | 125-361 MiB without release, 81-85 MiB with compact + trim |
| Rewrite owner after two integrity walks | 1.1 GB resident (heap 750 MiB, peak 1.85 GB) for hours |
| Body as heap string vs bigstring, 17 MiB object | get 36.7 vs 19.5 MiB peak heap; put 19.6 vs 12.7 MiB |
| Upload of a 128 MB file at 4 KiB chunks | 68.5 MB peak, 34.5 MB after removing per-chunk tasks |

## 1. Working sets sized by the data

### C-1.1 Fan-out width chosen by the data
- **Pitfall** — Starting one task per element before any work runs makes the working set the size of the input. Instances: upload task per chunk (131,072 promises + closures + waiter cells per 1 TB, 73 live words per chunk); mirror 140 words per object; local backend walk 100 MB of tasks for 13 MB of live data on 500k manifests; cache sweep opening all 4096 shard directories against the fd ceiling; whole-file materialisation running 16k stats on a 250 GB archive; read-ahead spawning a loop per 128 KiB read; CLI resync recursing inside its own fan-out; GC `iter_p` with 100k pending per manifest; `verify_all` with 4096 PUTs; chunk check per chunk. A scheduler that bounds running fibers does not bound allocated ones.
- **Check** — Every `Fiber.all`/parallel map takes a width fixed by code. Data-sized sources use N workers pulling from an atomic cursor and stopping on first failure. Tree walks are level-by-level or depth-first with bounded breadth. A test asserts live words per item below a threshold set between the before and after values.
- **Seen** — 916868d3, 64bf2e07, 322dffb9, 11a0fdee, e6bf5bee, d76a7bde, 14eab9b1, PR #56, #68, #69, #73; recurred ×7; rewrite (fiber-per-item noted as the same hazard).

### C-1.2 Look-ahead bounded by in-flight count, not by position
- **Pitfall** — The rewrite's tree walk capped fetches in flight with a semaphore but not finished listings waiting to be visited. On a wide tree every listing and its manifests queued in memory: 1.8 GB peak for 258k manifests, 887 MiB once bounded by position.
- **Check** — Prefetch admits only the next `width` items in visit order. Completed-but-unconsumed results count against the bound.
- **Seen** — 1cc49b00, c2a52b63; rewrite.

### C-1.3 Whole data-sized listings and sets held on the heap
- **Pitfall** — Import held three lists of every directory, file and symlink (about 100 MB per million paths). Mirror listed four whole prefixes (about 79 MB each), sorted them and built a Hashtbl of the destination keyspace (20k entries = 276,392 live words; on a shared bucket, every domain's objects). The rewrite's GC dry-run held a whole chunk listing plus two key sets for a main with millions of chunks.
- **Check** — Data-sized collections spill to disk (append, then map read-only) or live in an off-heap table. Listings are processed one shard or one page at a time. Nothing retains `copied : key list` to the end.
- **Seen** — 1f1deb27, a0bd9159, d386d435, 4e29ca1c, PR #55, #61, #69, e54c7d5c, c1647b68; recurred ×3; rewrite.

### C-1.4 Per-entry state held for a whole import
- **Pitfall** — Journal ops, statuses and encoded strings held per entry for the run came to about 320 B/entry: 7 MB at 24k files, 100 MB major heap near 143k files. Keys crossed four lists and two full manifest encodings.
- **Check** — Memory scales with in-flight work, not tree size. Append-only records are spooled to disk; manifests build incrementally into an off-heap buffer.
- **Seen** — c4997728, PR #69.

### C-1.5 A queue that only records work still kept it in memory
- **Pitfall** — A frontend's never-running replica queue held each recorded job in memory: it grew for the process life, reported everything as owed, and dropped writes at its cap.
- **Check** — A process that only records work writes the record and keeps nothing resident.
- **Seen** — 80b5e045.

### C-1.6 Staging producers outran the cache cap
- **Pitfall** — Staged bodies are outside `maxCache` (the cap sweeps chunks only), so an unthrottled first camera backfill on Android would fill internal storage.
- **Check** — Producers into staging throttle on queue depth (one file at a time). Every leftover class (including `.bad` staged manifests) has a collector or a report.
- **Seen** — PR #57, PR #79.

### C-1.7 Large GCS listings asked for full resources
- **Pitfall** — Listing with full object resources returned 483 MB of JSON for 500k objects.
- **Check** — Listings request only the fields used (keep etag).
- **Seen** — notes:backends/gcs.

## 2. Pool and slot discipline

### C-2.1 Slot taken after the resource
- **Pitfall** — `staged_source` read every chunk body of a file into memory before any queued for a buffer. Range fills opened their destination outside the download slot, so every pending fill held an fd; the commit claiming to add the slot did not. Without a slot before open, a 250 MB file opened 247 descriptors in 200 ms. A share took its 256 KiB buffer before its read slot.
- **Check** — The slot is acquired before opening a file, allocating a buffer or dialling a socket. Read the code, not the commit message. A source decides cheaply and reads only into the buffer it was granted.
- **Seen** — 28290a5e, acf20d86, 9f41023b, eb40957d, PR #73; recurred ×3.

### C-2.2 Nested acquisition from the same pool deadlocks
- **Pitfall** — A composite applied `Batched` again to the member it forwarded to, holding one slot while waiting for another from the same pool. Past the width every slot was held by a waiter and http-proxy get-multi wedged permanently. The same shape forced separate pools for sweep directories vs stats, resync breadth, and range pieces vs downloads.
- **Check** — No code path takes a slot from a pool it already holds. Forward already-admitted requests, or use one pool per nesting level. Test with more concurrent callers than the width.
- **Seen** — 2736bba5, 64bf2e07, PR #56, #70, #76; recurred ×2.

### C-2.3 Bound instantiated per caller, not per resource
- **Pitfall** — `Remote.Make` was applied per role, so its buffer and download pools bounded each caller separately while all queued on one device and one memory budget. A proxy beside a domain engine admitted twice what either allowed. Separate fixed counts per transfer path (replica forwards 32 x 8 MB) collapsed a 13 Mbit/s import to 0 B/s.
- **Check** — Each bound belongs to the resource it protects (device, memory, link) and is shared through a keyed registry. No pool is created per functor application, module or request handler. Global caps derive from max uploads + downloads.
- **Seen** — 0476866a, 5e651f30, 14d94ce5, PR #104; recurred ×2.

### C-2.4 Inner layer's default width bypasses the outer bound
- **Pitfall** — A proxy admission gate of 4 served 128 reads: get-multi fanned out through the batch layer's default 32, and children-multi of 64 folders did it per folder. A cache-layer fan-out over a group is 16 concurrent requests per 16 MiB group, bounded only at the store layer.
- **Check** — Every layer that fans out takes its width from the caller's budget; no layer has its own default. Test bounds through the real store layer with a fake backend below it.
- **Seen** — 4060b0b1.

### C-2.5 Slot released before the work finished
- **Pitfall** — A folder request's slot was released when the walk took it, not when its answer arrived, so a pool of one ran two listings.
- **Check** — A slot is held for the full life of the work it bounds. Tests assert in-flight count never exceeds width.
- **Seen** — bc7af78a, 14cd2e4c.

### C-2.6 Bodies escaping the buffer budget
- **Pitfall** — Chunks larger than the pool's buffers skipped the pool. Replica forwards kept bodies alive after the slot that carried them was released, so `maxChunkBuffers` did not bound upload memory.
- **Check** — Every body counts against the bound regardless of size. Any retained reference to a body holds its slot; best-effort forwards are dropped when the link has no room.
- **Seen** — PR #51, 80b5e045, PR #104; recurred ×2.

### C-2.7 Scarce slot spent before validating
- **Pitfall** — The resolve pool was entered before knowing the entry named anything, so an unreadable folder spent a download slot finding nothing to fetch.
- **Check** — Cheap validation precedes acquisition of a scarce slot.
- **Seen** — bc679a9f.

### C-2.8 Concurrency from config, not from the device
- **Pitfall** — The http-proxy handed every request to storage; a USB BOT disk takes one command at a time and thrashes past its depth.
- **Check** — Storage concurrency is sized from the device, asked once per store. A bounded queue refuses rather than accumulates, and a refusal does not consume a slot.
- **Seen** — 45112c33, f3d4c61b.

### C-2.9 Slot released only on the path that consumes the body
- **Pitfall** — A share response took a slot and released it in the `finally` of its streamed body. The server never runs a streamed body for a HEAD request, nor when the client is gone before the head is written, so each HEAD on `/s/<token>` (a link preview, `curl -I`) kept a slot: 64 of them and every share link answered 503 until restart.
- **Check** — A resource a response holds is released by the server on every path that ends the response: written, skipped for HEAD, failed on the head or the body. A streamed body is not a lifetime.
- **Seen** — rewrite (review of PR #114).

## 3. Body bytes and mappings

### C-3.1 Bodies copied through the OCaml heap
- **Pitfall** — Every chunk body was a `string`: an 8 MiB major-heap allocation per chunk, copies at every hop. s3 get concatenated fragments then copied into a bigarray; http-proxy decode copied three times (24 MiB transient per 8 MiB answer); `fetch_range` allocated the full length up front. On the Pi this killed a photo import and halved zram's ratio. In the rewrite, ocaml-tls takes strings and put an 8 MiB chunk on the heap three times.
- **Check** — Bodies are bigstrings or file-backed mappings from store to socket. TLS converts one 16 KiB record at a time. Bulk frames decode as views. Allocation follows arriving bytes. Flag any `to_string`/`of_string`/`Bytes` on a body path.
- **Seen** — 379d4b60, 53d6fcfa, acf20d86, 197c8ed8, 9dceabfd, f841a709, bd85d523, PR #51, #53, 4c1fb295, e39437ad, c9aea5f3, 18347cd5; recurred ×5; rewrite.

### C-3.2 Re-encoding bytes already held
- **Pitfall** — Five of six manifest publishers and the sidecar writer re-encoded a manifest they already held. A third of all `Chunk` uses were string conversions.
- **Check** — Publish the bytes already in hand. One encoding per value per path.
- **Seen** — 11a0fdee, f841a709.

### C-3.3 Mappings are invisible to the GC
- **Pitfall** — `Unix.map_file` allocates a small custom block, so a mapping is released only when a major GC finalises it. A low-allocation owner copying for hours kept 87 MiB of sent chunks' mappings resident. An unbounded memo held 19,261 mappings (75 MB pinned page cache, 2.2 GB address space) on a 415 MB host.
- **Check** — `madvise(MADV_DONTNEED)` a private mapping once sent. Caches of mapped values are bounded by count (FIFO 1024). Monitor file-backed RSS and mapping count against `vm.max_map_count`.
- **Seen** — e0836894, c6fc8665; recurred ×2; rewrite.

### C-3.4 Double local write on publish (also disk)
- **Pitfall** — Staging one file per chunk and regrouping at publish cost 520 MB of writes for a 260 MB file, most of the Pi's I/O budget.
- **Check** — Bytes are written once in their final layout and published by `link(2)` (both names readable across the flip), never by copy.
- **Seen** — 99ec3cb6, 4d12062f, PR #46.

## 4. Caches and memos without capacity

### C-4.1 Per-item memo grows for the process life
- **Pitfall** — `known_chunks` had one entry per chunk and no eviction; a "session" was a two-day 1.1 TB import. Heap went 34 to 108 MB over 483 GiB, projected 190 MB against a host killed at 176 MB. The cap (reset at 100k) explained only about 100 of 900 B/chunk. The mirror's `ensured` table had the same shape.
- **Check** — Every per-item cache on a long-running path has a cap; process lifetime is unbounded. Cache size is exposed so a test asserts the bound both ways (a cache storing nothing also passes a one-sided test). Status reports live heap words to tell retention from heap ratcheting.
- **Seen** — ac2a861f (#59), PR #60, 8d57ac65 (#67), 2b648644, e0836894; recurred ×3.

### C-4.2 Cached aggregates pin more than they save
- **Pitfall** — A per-folder index object saves a read per child, but past 10k children its heap costs more than the reads.
- **Check** — Cached aggregates are bounded by bytes pinned, not entry count.
- **Seen** — f1766969, 6cd1d890, 0bcaa178, 28dd1d82.

### C-4.3 Client-sized watch tables
- **Pitfall** — One proxy watch per waiter makes store load equal client load (17 reads for 8 waiters vs 9 coalesced). A table of watches kept for reuse is a table whose size the client picks.
- **Check** — One watch per key, dropped with its last waiter. No cache whose size a client chooses.
- **Seen** — cf3684d8, PR #72.

### C-4.4 Append-only off-heap table never reclaims
- **Pitfall** — `Hashtbl_mmap` appends on every `replace` and never reclaims superseded records, so rebinding grows the blob without bound.
- **Check** — Off-heap tables hold write-once keys, or have compaction.
- **Seen** — notes:01-core B.3.2.

### C-4.5 Eviction order ignored reads
- **Pitfall** — The cache cap ordered by mtime but only writes set it, so explicitly fetched files were evicted as readily as files a `grep` touched. Refreshing mtime on every read would cost an inode write per FUSE read.
- **Check** — Reads refresh recency, throttled (only if older than a minute). Explicit fetches are pinned with a deadline.
- **Seen** — PR #89, 6c654bc9.

## 5. Server bounds against callers

### C-5.1 Bulk answer built whole before writing
- **Pitfall** — children-multi checked its byte budget only between folders. A 22,000-manifest folder (90 MB of bodies) was framed into a growing buffer plus a final copy, about 3x, killing a 400 MB host's proxy (about 280 MB). A pre-framed string was copied again into a chunk.
- **Check** — Admission is decided from listed sizes before reading bodies. Responses stream piece by piece with no whole-response framing copy.
- **Seen** — 34183bb1, 4060b0b1.

### C-5.2 Caller chooses request size or stream count
- **Pitfall** — A get-multi was read, concatenated and framed whole; the gate counted requests, not bytes, so an authenticated caller chose listener memory. A streamed listing held a connection and walked a namespace for as long as the client read, with no limit on a second.
- **Check** — Every request-scoped buffer is capped by bytes or keys at the server (1000 keys). Concurrent long-running streams are capped. Readers enforce size limits independently of writers (skip an oversized index).
- **Seen** — c4284b23, PR #55, PR #70.

### C-5.3 Unauthenticated routes share the signed pool
- **Pitfall** — Share routes carry no credential, so the public chose concurrency, each block holding 256 KB. The share pool was unnamed (absent from reports) and share bytes uncounted (a share-only host looked idle). The block bound capped bytes in flight, not open responses: memo and zip member lists ran out first.
- **Check** — Unauthenticated endpoints have their own bounded pool. Each bound documents what it does not cap. Every pool and byte path appears in reports.
- **Seen** — 20f950f2, 2ff3584e, 7984930d, bbd6f95a.

## 6. Memory the runtime does not return

### C-6.1 OCaml 5 major heap kept without compaction
- **Pitfall** — OCaml 5 returns freed major-heap pools only on `Gc.compact`, which never runs on its own. An owner held 1.1 GB for hours after two integrity walks. Background copies were not jobs, so the job-end release never ran for them.
- **Check** — Every job ends with compact + trim. Housekeeping compacts when the heap grew 64 MiB past the last compaction. Every long-running activity, job or not, reaches a release point.
- **Seen** — 3283bcaa, b3431044; recurred ×2; rewrite.

### C-6.2 glibc arenas keep freed blocks
- **Pitfall** — OCaml 5 mallocs large blocks individually and the scheduler runs several domains, so glibc's per-thread arenas kept about 560 MiB after a 258k-manifest rebuild: 765 MiB resident for an 81 MiB heap.
- **Check** — After large transient work and at housekeeping, compact then trim (`malloc_trim(0)` on Linux, `malloc_zone_pressure_relief` on macOS).
- **Seen** — 6996cb19; rewrite.

### C-6.3 Thread pools that never shrink
- **Pitfall** — The blocking-call pool grew to its ceiling and stayed, so the ceiling was a memory floor: 256 threads settled at about 114 MB. Android capped it at 16.
- **Check** — Blocking-thread pools are sized from domain budgets and shrink when idle on small hosts.
- **Seen** — notes:07-daemon-cli B.6, notes:frontends/android B-II.1.

### C-6.4 Measuring the wrong memory
- **Pitfall** — RSS conflated live allocations with paged-in mapped files. A high top heap with many majors and little retained heap is a garbage storm, not a leak. Peaks varied by about 100 MiB between identical runs; tmpfs mappings count as shared.
- **Check** — Memory tests report private, anonymous, file-backed and OCaml heap separately and compare retained figures, not peaks. Rebuild memory is benched against a real store. On small hosts, check slab as well as RSS.
- **Seen** — 63cc235b, 1d5f6f33, c2a52b63; rewrite.

## 7. Disk, descriptors and blocking calls

### C-7.1 Blocking syscalls on scheduler workers
- **Pitfall** — pwrite, `map_file` (open, FICLONE, mmap), statvfs and page faults on mapped bodies ran on the event-loop thread. On a NAS or failing disk every chunk write stalled every task. Under duppy the same holds per domain.
- **Check** — Disk and network-filesystem calls run as may-block work (spec 01 §6.5), off the workers; work named non-blocking or time-sensitive contains none.
- **Seen** — notes:backends/local B13, notes:01-core B.2.5, notes:03-journal-sync B-II.7.

### C-7.2 Long work on a thread that serves others
- **Pitfall** — Android's post-close commit ran on the descriptor handler's thread until the upload drained, stalling reads of every other file.
- **Check** — Long work never runs on a thread or domain shared with latency-sensitive handlers.
- **Seen** — fa0a4fd5, PR #86.

### C-7.3 File descriptor limit
- **Pitfall** — The default ulimit was too low for concurrent chunk work; the daemon exhausted fds. Calls abandoned on a deadline hold half-open sockets until the idle timer (70 s back to baseline); dialling twice per call would leak.
- **Check** — RLIMIT_NOFILE is raised at startup and open files are bounded below it. Deadline tests count sockets; abandonment releases or bounds the descriptor; a timed-out socket is closed, not returned to the pool.
- **Seen** — aae7fea0, 59572854, PR #49, PR #96.

### C-7.4 O(tree) work on the startup path
- **Pitfall** — The daemon walked 235k manifests for temp files before forking: 2m57s before the socket existed, finding one file, and aborting on ENOENT from a directory vanishing mid-walk.
- **Check** — Startup does no O(tree) work. Sweeps are commands or background tasks. Walks tolerate concurrent removal.
- **Seen** — 2cd7c353.

### C-7.5 Size answered by walking 4096 shards
- **Pitfall** — `Chunk_cache.entries` read every shard and stat'd every body after each upload and each status poll.
- **Check** — Size and quota come from a counter per cache root, updated by every write route through one function (by size delta: range fills extend sparse files). One anchoring walk at start; a stat guard discards a count that outlived a resync.
- **Seen** — 82e0adea, 432277a7.

### C-7.6 Periodic rescan read every record body
- **Pitfall** — Housekeeping every 60 s opened all ~94k queue records before checking whether each was running; sweeps took 2.5-3 min and competed with the worker.
- **Check** — Filter by record id before reading bodies.
- **Seen** — PR #67.

### C-7.7 Workloads hostile to the small host's disk
- **Pitfall** — On one shared USB 2.0 bus, a disk-to-disk copy took the host down; an SMR drive stalled under small scattered writes (95% iowait, 60-180 s timeouts); a full client resync OOM-killed the proxy child.
- **Check** — Avoid many small scattered writes and simultaneous read+write on one bus. Full-resync load is tested against the smallest host's budget.
- **Seen** — session memories (small-host USB disk failure, small-host proxy OOM).

### C-7.8 An index over the tree built by reading every file, inside a request
- **Pitfall** — The file-id index was built lazily by the first request naming an `i:` reference: a walk opening every marker (274k on the reference Mac domain, about 80 µs per small-file read on macOS, so 1-2 min), past the 30 s request deadline. It ran after every restart, the requests behind it waited on a system mutex, which stalled their runtime domain, and the system's retry backoff turned the minute into a longer gap before a new file reached the owner. Neither a sized read buffer nor skipping manifest decode changed the time: the cost is one `open` and `read` per file.
- **Check** — No request walks the tree. An index over every file survives a clean stop as one snapshot read at start, and is rebuilt in the background only after a crash; a waiter for it waits as a fiber, outside the metadata serialisation.
- **Seen** — rewrite.

### C-7.9 Deadline-bound work queued behind blocked calls
- **Pitfall** — Every task of the runtime ran in the one class that holds a blocking slot: fiber resumes, timers, descriptor wake-ups. A worker with no slot left takes none of them, so calls stuck on a stalled disk (256 slots) also stopped timeouts from firing, `ping` from being answered and uplink leases from being renewed: a disk stall read as a dead owner and lost leases.
- **Check** — Timeout, stop and wake-up delivery, non-blocking socket I/O, the liveness answer and the governor's admission and renewal run in classes that hold no blocking slot (spec 01 §6.5). A test pins every slot and shows they still run, and that a may-block task does not.
- **Seen** — rewrite.

### C-7.10 A descriptor released on some failure paths but not on a raising step
- **Pitfall** — `Dqueue.Records.hold` opened a record and raised when it could not lock it, without closing the descriptor. `Owner.acquire` took the ownership lock, then wrote the holder record: a failing truncate or write raised past the lock, so the descriptor, and the domain's ownership lock with it, stayed held by a process that reported failure. A cleanup written as a copy per branch (closing a held batch record in each branch of its release) had the same hole for any step that raises.
- **Check** — Every step after an acquisition either runs under `Fun.protect ~finally` (released on every path) or under `match … with exception` (released on failure, handed over on success). A branch that releases by hand is a branch a later raise skips.
- **Seen** — rewrite (review of PR #118); rewrite (resource inventory: the durable queue's keyed worker, whose slot a raising decode or completion left running, killing the worker and stranding its key; a job slot claimed before its finally, which also sent a progress line before freeing it, leaving the domain busy; four forward slots taken in a loop before their finally, which a cancel mid-loop stranded until every later deletion blocked; three single-flight claims — a status listing refresh, the File Provider change debounce, an http-proxy key watch — given back only on the path that reached the end, so one raise stopped that refresh, relay or watch for good; a FUSE edit whose upload record was owed by a close that a raising open or close_read skipped; six sockets — an IPC listener, client and accepted connection, an HTTP client socket, listener and accepted connection — closed on some failures but not when a setup step such as set_nonblock, bind or the spawn handing them to their fiber raised; `Fs.or_close` is now their one form; temporary files in the cache and the local store left behind when a step before their rename raised; a child left unreaped by an interrupted wait, a pipe by a failed read, the service log descriptor by a failed dup2; staged bodies made for an edit and orphaned when a step before the manifest naming them raised, now owed back by one helper that spares any body the manifest on disk names; engines, sockets and children cleaned up only when the owner, store server or supervisor returned normally; a promotion temporary, a download destination, superseded bodies released after a step that could raise, and a bucket-function probe left on a store with no function). recurred ×10.

## 8. CPU loops and polling

### C-8.1 A watcher woken by its own writes
- **Pitfall** — A read's reflink snapshot temp file in the watched object directory woke the poller, which read again: about 140 wakes/s for five days, two processes feeding each other, OOM every 15-35 min on XFS deferred-intent slab with RSS flat at 55 MB. ext4 never showed it.
- **Check** — A handler's side effects cannot re-trigger it: temp names are filtered or scratch lives elsewhere. Wake-driven loops are rate-limited. Where events carry no names (macOS), poll.
- **Seen** — 21f93132, a3701654, PR #92, f2b70a45; recurred ×2; rewrite.

### C-8.2 Busy-spin in a worker loop
- **Pitfall** — The keyed upload worker looped immediately when paused with a record ready: neither the timed nor the open wait applied. It burned a core and starved fibers on its scheduler domain.
- **Check** — Every worker loop's wait covers all state combinations (paused x ready x empty); a branch without a blocking wait is a bug.
- **Seen** — 34502f53; rewrite.

### C-8.3 Retry loops without backoff
- **Pitfall** — A wedged peer entry was re-applied every 2 s for hours. A "debug" line was written every 2 s per skipped read of a dead main.
- **Check** — Every retry loop backs off; stuck items step aside and are reported.
- **Seen** — mem:foreign-rename-enotempty-loop, dbdfbc27.

### C-8.4 Status cost proportional to poll rate
- **Pitfall** — Each status call listed a thousand journal keys, the corruption prefix and the cursor per store; `status --watch 1` kept a small server's disk busy. In the rewrite a status page re-listed both journals per poll (8,084 entries on GCS) and burned a core parsing. Each of four processes described its whole domain and probed every backend.
- **Check** — Expensive status inputs are cached and shared (journal listing 60 s, probe 5 s) and refreshed behind the reply. Machine-level probes run once, in the converging process. Tests count store requests per status call.
- **Seen** — b0d8d9c0, 2bd96b50, a0b1de78, 58b482c9; recurred ×3; rewrite.

### C-8.5 Pollers pile requests behind a slow server
- **Pitfall** — `StatusMenu.poll` issued a request every 3 s regardless of outstanding ones. The web page polled while hidden.
- **Check** — A periodic poll waits for the previous answer. UI polls at 10 s or slower and pause when hidden.
- **Seen** — 12cfb681, PR #101, 58b482c9.

### C-8.6 Quadratic processing of data-sized lists
- **Pitfall** — Batches split with `length` plus two `List.filteri` passes in a loop taking the head. In the rewrite, batching 258k elements by filtering the remainder drove the heap past 1.6 GB with 700 major collections. Others: `List.length (List.concat acc)` per page, expire's `List.mem` over survivors.
- **Check** — Batch, split and filter in one pass through one helper. Membership uses sets. Grep for `filteri`, `nth`, `List.length`, `@` inside loops over data-sized lists.
- **Seen** — 99695932, PR #56, 688e3cbc; recurred ×3; rewrite.

### C-8.7 Log volume from per-item lines
- **Pitfall** — `--verbose` printed a line per manifest (hundreds of thousands); every retry attempt and every unreadable child warned.
- **Check** — Progress is summarised (every 1000). Retries warn once after the first attempts. Failures aggregate with a sample. Hot paths log nothing per call.
- **Seen** — a699ecea, dbdfbc27.

### C-8.8 A process per request
- **Pitfall** — On Android each stat, listing and change exec'd a process that booted a runtime and read the manifest tree.
- **Check** — One long-lived runtime answers requests.
- **Seen** — cc90f688.

### C-8.9 Paging re-walks the whole set
- **Pitfall** — `list_all` walked and parsed every manifest per page: a minute per page on 220k items; the File Provider daemon held 40k and never finished.
- **Check** — Paged enumeration snapshots once and pages over the snapshot.
- **Seen** — fed3bc67.

## 9. Round trips and network cost

### C-9.1 Cost proportional to the shard space, not the data
- **Pitfall** — GC reconcile listed all 4096 shard prefixes on each copy, even for a 12-chunk domain; across a network it looked wedged. `verify_all` enqueued 4096 requests at once, needing a ceiling on Lambda/Cloud Run.
- **Check** — When the work set can be named, never walk the shard space. A cost-counter test asserts listings per copy (0 for close). Burst fan-outs to a remote function have a concurrency ceiling.
- **Seen** — 18e77119, e80a7593, bfd2761d, PR #42; recurred ×2.

### C-9.2 One request per object where a bulk verb exists
- **Pitfall** — GCS JSON deleted 1,000 objects in 1,000 requests, 32 at a time. GC close waited a round trip per batch per copy. In the rewrite, client-side deletes on a remote media-library copy cost one request per chunk (1235 per run, millions possible).
- **Check** — Use bulk verbs (1000 keys per request). Remote copies delete through a confirmed, durable bucket-side function; a collection that would send per-chunk deletes to a remote copy is refused before it opens.
- **Seen** — 73326a5c, 27685a67, PR #42, 639c7761, 7a856cf6, b794ad9b; recurred ×3; rewrite.

### C-9.3 A TLS handshake per request
- **Pitfall** — GCS and HTTP drivers dialled per request: three round trips per handshake on a 150 ms link. Draining 94k deferred ops ran 25.6 KB/s of egress for 395 B/s of payload (1.5%), with 380+ sockets in TIME_WAIT.
- **Check** — One shared HTTP client pools connections per endpoint (idle timeout about 60 s) and redials dead connections.
- **Seen** — 8d57ac65 (#67), PR #96.

### C-9.4 Per-object existence checks instead of a listing diff
- **Pitfall** — Mirror HEADed each destination object (200 HEADs vs 1 listing); deferred manifest jobs HEADed each chunk (160 vs 4 shard listings); a body was fetched once per destination (258 vs 129).
- **Check** — Compare sets by listing both sides; fetch each body once for all destinations. Watch wall time: per-shard listing costs more requests than paging a prefix.
- **Seen** — PR #55, #67, #69; recurred ×3.

### C-9.5 A round trip per folder child or per folder in series
- **Pitfall** — S3 and GCS answer a folder with one read per child (101 reads for 100 children). A resync fetched each folder only on reaching it: two serial round trips per folder, about 30,000 for a large domain, with `--parallelism` bounding nothing. Share path resolution listed whole folders (20k children per segment).
- **Check** — Walks prefetch in visit order up to the pool width and use batched listing (children-multi, up to 64 folders). Folders use an index object or get-many. Paths resolve by computed key, one read per segment.
- **Seen** — f1766969, 6cd1d890, 14cd2e4c, d9d96fb7, 2de0986d, 6ccc2034, 3f90a977; rewrite.

### C-9.6 Backend reads on metadata paths
- **Pitfall** — `stat` and `pread` fell through to backend GETs for keys the mirror lacked: 85 ms per missing-name getattr (about 1 s on shell startup), O(files) GETs on a cold listing. A folder-id miss walked 235k manifests treating the miss as a stale index.
- **Check** — The mirror answers existence; no backend read on a metadata path. A miss means absent; rebuilding an index is the resync's job. Tests count backend reads.
- **Seen** — 1f091af5, 5396b942, bac2b877, 1b08744e.

### C-9.7 Hot paths re-fetched remote state
- **Pitfall** — Before every File Provider enumeration the change feed listed the whole journal prefix with a GET per entry, then stat'd per op because replies named items by reference.
- **Check** — Hot paths answer from local state. Change replies carry whole items.
- **Seen** — 20a26efa, a06abe2f.

### C-9.8 Copies re-transferred stored content
- **Pitfall** — Copying a tree within a domain through the mount downloaded and re-uploaded every byte though the chunks were already stored.
- **Check** — Intra-store copies republish manifests; local copies move only what differs.
- **Seen** — 96c30ced.

### C-9.9 Parallelism above link capacity
- **Pitfall** — Eight 8 MiB reads on a 1.5 MB/s link each exceeded the request timeout and were refetched; most bytes were discarded.
- **Check** — Large-transfer parallelism adapts to the link via a governor on measured queueing delay, shared per link across processes. Partial progress is kept.
- **Seen** — 338d01b4, 243d32ee, PR #104.

### C-9.10 Live cloud suites on every push
- **Pitfall** — The conformance suite against real GCS and S3 ran per push: 22.1k writes, 20.5k lists, 20.5k deletes a day, 56% of the cloud bill.
- **Check** — Provider suites run on demand and clean every prefix they create.
- **Seen** — 60810a3d, PR #58, PR #71.

## 10. Read path: demand vs speculation

### C-10.1 Demand reads queued behind prefetch
- **Pitfall** — A ~100 KB range read waited on an in-flight 16 MiB group prefetch; then ranges shared the download budget, so a 128 KiB player read queued behind refilling 1 MiB prefetches at 6 s per read. Phones abandoned the descriptor and playback stopped.
- **Check** — Reader-blocking I/O has its own pool and never waits on a fetch it did not need.
- **Seen** — 6bd091b6, ff9b1855; recurred ×2.

### C-10.2 Small read fetches a whole group or file
- **Pitfall** — Cache bodies were all or nothing: a few bytes fetched two 8 MiB objects and wrote 16 MiB. Android openDocument downloaded 2 GB to start a film; range reads fetched 24 MB to serve 256 KB (16 s cold).
- **Check** — On link-backed stores fetch the requested range and record partial intervals; fetch whole chunks only from a fast local main. Never materialise a whole file for a partial read.
- **Seen** — 8b026378, b0ea0213, f18f85db, PR #76, PR #107; recurred ×2.

### C-10.3 Read-ahead window of zero
- **Pitfall** — The window started at the group being read and a group exceeded the budget, so lookahead was zero and every next-chunk crossing was a foreground fetch.
- **Check** — Window = current group + N ahead, independent of budget vs group size. Tests assert which chunks were requested, not durations.
- **Seen** — 00585588, 96e990ea, PR #107.

### C-10.4 Read-ahead multiplied with frontend pipelining
- **Pitfall** — On macOS each extra concurrent range fetch costs a group read plus read-ahead, burying slow stores.
- **Check** — Read-ahead defaults to about one group (clamp(4 MiB / group, 1, 8)) and does not multiply with frontend pipeline depth.
- **Seen** — notes:frontends/file-provider B7.

### C-10.5 Desktop tools read whole files
- **Pitfall** — A local-looking FUSE mount let file managers read whole files for thumbnails.
- **Check** — The mount reports a network filesystem type (fuse.sshfs by default).
- **Seen** — fcbba236.

### C-10.6 Bulk export through the cache
- **Pitfall** — Export routed every chunk through the local cache one file at a time and could not handle a 51 GB file.
- **Check** — Export streams from the store, preallocates, verifies per chunk and resumes from a record.
- **Seen** — 26f139bc.

### C-10.7 Maintenance scaled with the archive
- **Pitfall** — Old `expire` held every live key in memory, did a sequential GET per manifest, then listed the whole chunk store on every backend, all-or-nothing.
- **Check** — Maintenance scales with the work, keeps no all-keys set, resumes from disk state, and is paced by budget, pause and I/O concurrency.
- **Seen** — PR #40.

## Review checklist

1. **Working sets** — Is any fiber, list or table count proportional to input size? Are finished-but-unconsumed results bounded by position? Is there a live-words-per-item test? Does a record-only queue keep anything resident?
2. **Pools** — Is the slot taken before the fd, buffer or socket? Held until the work's answer arrives? Can this path acquire a slot from a pool it already holds? Is the pool keyed by resource, not by functor instance? Does any inner layer have its own default width?
3. **Bodies** — Does any body pass through `string`/`Bytes`? Is a mapping `madvise`d once sent? Are mapped-value caches count-bounded? Are bytes written once in final layout?
4. **Caches** — Does every cache on a long-running path have a cap, tested both ways? Is its size client-chosen? Does an off-heap table reclaim superseded records?
5. **Server bounds** — Is every request buffer capped by bytes or keys? Is admission decided before bodies are read? Do unauthenticated routes have their own pool, visible in reports?
6. **Runtime memory** — Does every long-running activity reach a compact + `malloc_trim`? Do thread pools shrink? Do tests compare retained anonymous/file/heap figures rather than RSS peaks?
7. **Disk and blocking** — Does any disk or NFS syscall run on a fiber worker, or inside work named non-blocking or time-sensitive? Does deadline-bound work need a blocking slot? Is there O(tree) work at startup? Are sizes counters rather than walks? Are sockets counted in deadline tests?
8. **CPU loops** — Can a handler's side effect re-wake it? Does every worker-loop branch block? Does every retry back off? Is status cost independent of poll rate? Any `filteri`/`nth`/`@` in a loop over data?
9. **Round trips** — Is cost proportional to what exists, not 4096 shards? Bulk verbs used? Connections pooled? Existence checked by listing diff? Any backend read on a metadata path?
10. **Read path** — Do demand reads have their own pool? Are slow stores read by range? Is read-ahead at least one group ahead and not multiplied by pipelining?
