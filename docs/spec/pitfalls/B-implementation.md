# B. Implementation-specific pitfalls

This file collects the traps that came from the implementation medium rather than from the design: the OCaml runtime and stdlib, C stubs and FFI, POSIX and OS corner cases, platform frameworks (FUSE, File Provider, Android), cloud store APIs, the build and the test harness. Themes are tagged **[runtime]** (OCaml, stdlib, C stubs, FFI), **[platform]** (POSIX, OS and framework behaviour) or **[store]** (S3, GCS, HTTP and cloud APIs), plus **[build]** and **[tests]**. They are ordered by danger, data loss first. In review, read each **Check** against the rewrite's code, and assume fibers on a domain pool: nothing is atomic between two statements, a blocking call stalls a whole domain, and any test whose determinism came from cooperative scheduling is suspect.

## 1. Durable writes, file mapping and local filesystem semantics [platform]

### B-1.1 Rename or link published a name before its data was durable
- **Pitfall** — The temp file was renamed or hard-linked into place without fsync. On ext4 and XFS, delayed allocation can commit the rename first, so after a power loss a chunk or manifest name points at an empty or truncated file.
- **Check** — Every publish path fsyncs the data fd before `rename`/`link`; a test asserts the syscall order. A lost rename (missing object) is acceptable; a named empty file is not.
- **Seen** — 3c4187fc, PR #91.

### B-1.2 mmap of a file that can shrink or be rewritten gives SIGBUS
- **Pitfall** — Off-heap bodies use `MAP_PRIVATE` mappings. A staged body or a user file mid-import can be truncated under the mapping, which is SIGBUS (a dead daemon), not a short read; a file rewritten in place reads through to the new bytes. The import fix maps a reflink clone and unlinks it once opened, but ext4 and tmpfs have no reflink, and the fallback once mapped the live file again. The s3 bigstring change widened the window by holding the body for the whole request.
- **Check** — Only immutable, rename-published files are mapped, from a read-only fd. User files, live staged bodies and cache bodies read per kernel request are never mapped by path. User sources re-check size or identity after hashing and publish nothing if it moved (`Source_changed`). The no-reflink fallback never maps the live file. Tests assert the platform mmap contract and count the checks that ran.
- **Seen** — acf20d86, e0836894, 0a245a9d, 99695932, PR #51, PR #53, c9aea5f3; recurred ×3, rewrite.

### B-1.3 Mapping before the writer is closed
- **Pitfall** — An append-then-map spool is sound only if the write channel is closed before mapping; the wrong order is SIGBUS. The rule was restated in two modules, and a killed import left its spool under the cache root.
- **Check** — One module owns the spool lifecycle: append, close, map, unlink immediately after mapping, so a crash leaves nothing to reap.
- **Seen** — f841a709, PR #56, PR #69.

### B-1.4 `Unix.map_file` and network filesystems
- **Pitfall** — `Unix.map_file` on a writable fd extends a short file instead of failing. EIO on a failing disk or ESTALE on NFS arrives as SIGBUS at page touch, inside hashing or a socket write. tmpfs mapped pages count as RssShmem, not RssFile.
- **Check** — Mapping lengths are clamped to size − offset and use a read-only fd. Roots on a network filesystem (decided by `statfs`) are read with positioned reads, never mapped. Memory accounting knows which RSS field mapped pages land in.
- **Seen** — rewrite notes (01-core, memory, 06-backends, backends/local).

### B-1.5 A capability fallback that silently changes cost
- **Pitfall** — GC marking used a second hard link. `Local_backend.copy` fell back to read-and-rewrite on `EXDEV | EMLINK | EPERM | EOPNOTSUPP` while `caps.gc` said true, so on exFAT, Android shared volumes and network mounts a GC rewrote the whole live set (the old code read a copy counter of 89). Some Android cache roots also cannot hard-link the staged body for group publish.
- **Check** — Link support is probed once on the actual filesystem and remembered. Promotion uses rename. No capability is advertised whose fallback changes cost class without being visible. Tests assert the property (`nlink=2` after link, `nlink=1` after move, copy counter at 0), not just the outcome.
- **Seen** — 18e77119, 4d12062f, PR #40, PR #42, PR #46; recurred ×2.

### B-1.6 Concurrent ranges through one fd share a seek position
- **Pitfall** — Several ranges of one file are read and written concurrently through one fd. Unpositioned bigarray I/O shares the seek offset, so ranges interleave.
- **Check** — All shared-fd I/O is `pread`/`pwrite`. No code does seek-then-read on an fd another fiber or domain can reach.
- **Seen** — PR #51.

### B-1.7 The store's own temp files leaked into listings
- **Pitfall** — The local driver listed `.tsync-tmp-<pid>-<n>.tmp` staging files. Mirror copied half-written bodies to every backend under names nothing reclaims, and a listing could hand out a key already renamed away (resync ENOENT). A user's `.syncthing.x.tmp` is real data. Reaping temps at startup would delete another client's live upload on a shared root.
- **Check** — One recogniser (prefix and `.tmp` suffix) filters scratch names at the listing point; consumers filter again for older writers' leftovers. Temps are hidden, never reaped at start. Any C copy of the recogniser matches the OCaml one.
- **Seen** — PR #63.

### B-1.8 Listing order sorted by name, not by key
- **Pitfall** — Diffing two listings needs ascending key order. A directory sorts as `name/`, so `a-` < `a/z` < `a0`; sorting children by bare name failed 5 checks.
- **Check** — Listing order is part of the driver contract, and the consumer raises on a key not exceeding its predecessor.
- **Seen** — PR #55, PR #69.

### B-1.9 Lazily created directories read as ENOENT
- **Pitfall** — An unknown folder reference on a fresh domain raised ENOENT from directories the index sweep reads, which do not exist until something is written.
- **Check** — A directory created on first write reads as empty when missing; ENOENT there is not an error.
- **Seen** — 93b75364.

### B-1.10 Sizes without `LargeFile`
- **Pitfall** — `Unix.lstat`/`stat` on a file over 2 GB gives `EOVERFLOW` on 32-bit; sizing a tree and `Spool.seal` both used the non-LargeFile variant.
- **Check** — Every size goes through `Unix.LargeFile`; grep for bare `Unix.stat`/`lstat`/`fstat`.
- **Seen** — PR #62, rewrite notes (02-remote-model); recurred ×2.

### B-1.11 Syscall error names the wrong operand
- **Pitfall** — `Unix.link` ENOENT carried the destination path; the missing thing was the source, which cost a wrong first diagnosis.
- **Check** — Wrappers re-raise two-path syscall errors naming the operand at fault.
- **Seen** — PR #94.

### B-1.12 `syncfs` is not a barrier on macOS
- **Pitfall** — macOS has no `syncfs(2)`; the stub falls back to `sync()`, which only schedules the flush. A bulk pass that wrote without a fsync per file and then relied on one `syncfs` before a durable record (the file-id backfill's completion record) could lose or tear files behind a record that survives the crash: the backfill never ran again, and the files without an id never appeared in Finder. The rebuild's last-sync mark, written after a `syncfs`, still has the directory half of this exposure.
- **Check** — Writes that a later durable record depends on keep their own data fsync, and their directories are fsynced before the record. No code treats `syncfs` as a barrier on a platform where it is `sync()`.
- **Seen** — c2d525c8, rewrite.

## 2. Store API semantics: S3, GCS, S3-compatibles, http-proxy [store]

### B-2.1 Conditional write silently ignored by an S3-compatible
- **Pitfall** — rclone's S3 server ignores `If-None-Match`, so `put_if_absent`, the store's only conditional write, overwrites.
- **Check** — Conditional-write support is verified per endpoint (a probe that must see a 412) before any protocol relies on it; an endpoint that fails the probe is refused or flagged, never trusted.
- **Seen** — 57556da2; rewrite.

### B-2.2 S3 multi-object delete returns 200 with per-key refusals in the body
- **Pitfall** — The driver bound the per-key error list to a wildcard, so a refused delete looked like success. Survivable while reconcile re-swept; a permanent leak once it did not.
- **Check** — Bulk APIs parse per-item results. Anything not "already gone" is a failure, and one owner (`absent_code`) says which codes mean absent.
- **Seen** — PR #42.

### B-2.3 Signed bytes differ from sent bytes (SigV4)
- **Pitfall** — `+` was signed as `%2B` but sent raw; `%` was signed literally but sent as an escape. Each gave 403 on every such key and cost a day. In the rewrite, a Host header without its non-default port made SigV4 to a custom port fail.
- **Check** — The canonical request is built from the exact bytes on the wire, Host port included. Conformance keys include `+`, `%`, `&`, `<>`, quotes, `#?`, space and non-ASCII, plus XML metacharacters in delete documents, run against real buckets.
- **Seen** — 7a92d2b1, 678d4e0d, 49edc5c6, PR #42, PR #43, 3c1affd8; recurred ×2, rewrite.

### B-2.4 A truncated streamed response looks finished
- **Pitfall** — A streamed `/list` that stops early is indistinguishable from a complete one; a truncated source listing means objects silently never copied. Batched bodies have the same risk.
- **Check** — Streams carry an explicit terminator and the client refuses one without it. Batched answers are refused when truncated or reordered, never read as absences.
- **Seen** — PR #55, PR #70.

### B-2.5 Range at or past EOF differs per store
- **Pitfall** — `get_range` at or past the end is 416 on GCS and S3, classified permanent, while the local driver returns empty. rclone answers ranges with 200 plus `Content-Range`.
- **Check** — Range-at-EOF behaviour is defined in the driver contract and every driver conforms. A 200 carrying `Content-Range` is read as a range.
- **Seen** — rewrite notes (backends/gcs), 57556da2; rewrite.

### B-2.6 XML entities in keys not decoded
- **Pitfall** — Bulk-delete `<Key>` values were not entity-decoded. rclone writes numeric references (`&#34;`, `&#39;`) that named-entity decoding left in place.
- **Check** — The XML reader decodes named and numeric character references; tests cover keys with quotes and `&`.
- **Seen** — rewrite notes (backends/gcs), 7560f124; recurred ×2, rewrite.

### B-2.7 An empty namespace lists as its own directory key
- **Pitfall** — An empty trash or namespace lists as a zero-byte directory placeholder key with no marker, which cannot be fetched on a filesystem store; readers other than expire choked on it.
- **Check** — The placeholder is filtered once, at the listing point all readers share.
- **Seen** — 25db5912, 9327a879.

### B-2.8 GCS wire-format quirks
- **Pitfall** — `Uri.of_string` keeps an encoded `%2F` while `with_path` re-encodes it; `add_query_param'` re-serialises the whole query. `size` is a JSON string on GCS and an int on emulators. RFC 3339 offsets were ignored and garbage sizes read as 0. A `fields=` listing (483 MB down to 70 MB) silently dropped `etag`. Last-Modified needs the shared HTTP-date parser.
- **Check** — Wire helpers are pure and unit-tested against real responses. Parsers accept both encodings of numbers, honour offsets, and reject garbage instead of defaulting to 0. Any `fields=` mask lists every field read downstream.
- **Seen** — rewrite notes (backends/gcs), 9cfcac36; rewrite.

### B-2.9 Auth failures classified as transient
- **Pitfall** — OAuth failures were a bare `Failure`, read as transient, so a revoked key climbed the retry ladder and marked the link lost. There was no re-mint on 401. The JWT `iat` must be wall time. RSA signing ran without a mask because no RNG was initialised.
- **Check** — Token-endpoint 4xx is permanent; a 401 re-mints once. JWT times use the wall clock. The crypto RNG is initialised before the first signature.
- **Seen** — rewrite notes (backends/gcs), 8d746482; rewrite.

### B-2.10 Each API surface has its own auth and header rules
- **Pitfall** — A `devstorage.read_write` token was refused for GCS XML bulk delete but accepted by the JSON API; the request without `Content-MD5` got 400.
- **Check** — Every API surface used is exercised against the real service with the production token scope.
- **Seen** — a89ec286, 7beac8b1.

### B-2.11 Error classification by accident
- **Pitfall** — In the old S3 client, a 5xx's class depended on whether its body parsed as XML, and 409 `ConditionalRequestConflict` (retryable) was treated as permanent.
- **Check** — Classification uses the status code and documented error codes only; retryable 409s are transient.
- **Seen** — rewrite notes (backends/s3).

### B-2.12 S3 client hard-coded assumptions
- **Pitfall** — The old fork hard-coded the region list (new regions failed at construction), took a host-only endpoint on 443, resolved AF_INET only, issued HEAD then DELETE regardless, and returned listings exceeding `max_keys` by a page.
- **Check** — Regions are free strings, endpoints take scheme and port, resolution covers IPv6, delete is one request, and page sizes are honoured.
- **Seen** — rewrite notes (backends/s3).

### B-2.13 Per-object write rate limit on a hot object
- **Pitfall** — One object name accepts about one write per second before 429. An `rm -rf` bumped the cursor once per file and spent its time backing off; a stub hook in `tsync sync` dropped the bump entirely.
- **Check** — Writes to a single hot object (cursor, head) are coalesced process-wide per object, and every path that should bump does.
- **Seen** — cd2cf2bb.

### B-2.14 GCS bulk delete: no XML multi-delete, batches fail whole, emulators diverge
- **Pitfall** — The GCS function issued 2000 HTTP deletes per 1000-key request, half for markers that did not exist; a real bucket rate-limited it (11 RetryErrors), and 1000 single deletes take about a minute, the function's whole budget. The JSON batch endpoint (100 per call) fails as a whole, so a failed batch is redone key by key. fake-gcs-server answers it with a non-multipart body, so the emulator only exercises the fallback.
- **Check** — Bulk deletes list once and use the batch API, with key-by-key retry of a failed batch. Batch behaviour is verified against a real bucket, not an emulator.
- **Seen** — 27685a67.

### B-2.15 Canonicalisation drift between signer and verifier
- **Pitfall** — The http-proxy server recomputed the canonical target with ocaml-uri (own safe sets, splits and rejoins on `,`); `add_query_param'` prepends; `Uri.with_path` dropped a base path; timestamps were rounded (`%.0f`) while the JS and Kotlin signers floor; the verifier accepted `1.7e9`.
- **Check** — One wire module serves both ends, with byte-exact canonicalisation and shared test vectors run by each language's signer. Numeric fields parse strictly.
- **Seen** — rewrite notes (backends/http-proxy), cff6235d; rewrite.

## 3. Signals, syscalls and C stubs [runtime]

### B-3.1 EINTR surfaces as a `Sys_error` string; `Sys.file_exists` answers false
- **Pitfall** — OCaml installs signal handlers without `SA_RESTART`. A SIGCHLD from reaping a `df` child interrupted syscalls; `runtime/sys.c` does not retry and raises `Sys_error "<path>: Interrupted system call"`, which no `Unix_error EINTR` handler matches, and the daemon died 5 s into start-up. `Sys.file_exists` returns false on EINTR, which nearly re-minted the client uuid and orphaned every WAL record. Under FUSE signal delivery, unshimmed calls surfaced as spurious ENOENT or EIO.
- **Check** — Every Stdlib/Sys/Unix file call goes through a retry recognising both spellings; `file_exists` is rebuilt on a retried `Unix.stat`; `In_channel`/`Out_channel` are covered too; C stubs loop on EINTR. Verify the shim reaches every call site (grep for direct `Sys.`). Treat any installed signal handler as making every blocking syscall interruptible, and avoid spawning children in the daemon.
- **Seen** — 83197636, 37c0d67d, bbc08deb, PR #83; recurred ×2.

### B-3.2 C stub discipline: runtime lock, errno, moving heap, bounded loops
- **Pitfall** — Blocking calls (statvfs, pread/pwrite, fallocate) were made holding the runtime lock. OCaml strings were used after releasing it (the heap may move). errno was read after reacquiring. A kqueue registration without `EV_CLEAR` made the drain spin forever in C holding the lock, beyond any timeout. An inotify buffer not aligned for `struct inotify_event` got EINVAL.
- **Check** — Strings are copied to C buffers before `caml_enter_blocking_section`; bigarray data may be used directly. errno is saved before reacquiring and raised via `caml_uerror`. Every C loop under the lock is bounded (drain capped, e.g. 64 passes). Cheap calls keep the lock. Under OCaml 5 a stub that blocks holding the domain lock also stalls stop-the-world GC for every domain.
- **Seen** — f9f136d5, PR #72, rewrite notes (01-core, backends/local); recurred ×2.

### B-3.3 Blocking syscalls on the scheduler
- **Pitfall** — The FUSE mount answered "is this key a directory" with blocking `Sys` calls on the event loop.
- **Check** — Filesystem syscalls go through the blocking-I/O offload. Under fibers on domains, a blocking call in a fiber stalls every fiber on that domain; audit every `Unix.`/`Sys.` call reachable from the pool.
- **Seen** — PR #85.

### B-3.4 Non-reentrant lock reachable from a signal handler
- **Pitfall** — memtrace 0.2.3's sampling callback, reached from a signal handler, spun on a lock its interrupted frame held; an import on a Pi-class host spun 8 hours at 100% CPU. The cross build still carried 0.2.3 after the fix.
- **Check** — No non-reentrant lock in code reachable from signal handlers or allocation/GC callbacks (memprof, finalisers). Instrumentation versions are pinned in every build, cross builds included.
- **Seen** — 9a810da0, 86294048; recurred ×2.

### B-3.5 SIGPIPE on a closed peer
- **Pitfall** — Writing to an IPC socket whose peer closed raised SIGPIPE on macOS and killed the process.
- **Check** — SIGPIPE is ignored process-wide and `SO_NOSIGPIPE`/`MSG_NOSIGNAL` is set on every socket, in every language's client.
- **Seen** — f81bb083, PR #101; recurred ×2.

### B-3.6 `select` cannot watch descriptors past FD_SETSIZE
- **Pitfall** — Android ran on a select-based engine, which cannot watch an fd number above FD_SETSIZE (1024); macOS hit the same.
- **Check** — The scheduler's poller (vendored duppy included) uses poll, epoll or kqueue, never `Unix.select`, on every platform. A test opens more than 1024 fds and still serves.
- **Seen** — 47040bc1, rewrite notes (frontends/file-provider); recurred ×2.

### B-3.7 Per-connection errors killed the accept loop
- **Pitfall** — The server set `TCP_NODELAY` on every accepted connection and tolerated only EOPNOTSUPP; macOS answers EINVAL on a unix socket whose peer already hung up. One connect-and-leave client killed the accept loop; Finder and the File Provider hung until restart.
- **Check** — Every error of one accepted connection is caught inside the loop. No TCP options are set on unix sockets.
- **Seen** — 10a77333, PR #87.

### B-3.8 Readiness inferred from a socket file
- **Pitfall** — The socket file appears at `bind`; a connect between bind and listen is refused, which a loaded runner hit. A test slept 50 ms and recorded a "null" answer; Android's status screen trusted the socket file of a dead daemon.
- **Check** — Readiness and liveness are a successful connect and answer, never file existence or a sleep.
- **Seen** — 641ad8a4, e163bd6f, 1ba3f1bb, PR #99; recurred ×3.

### B-3.9 Wall clock used for intervals
- **Pitfall** — Rate measurements over seconds used wall time, which NTP steps by about that much.
- **Check** — Durations, deadlines and rates use a monotonic clock; wall time only for timestamps another party reads (JWT `iat`, manifest mtimes).
- **Seen** — 80b5e045.

### B-3.10 A poller backend that swallows an error on registration
- **Pitfall** — The scheduler fires a wait at once when its descriptor cannot be watched, so the fiber meets the error from its own I/O. The epoll backend reports `EBADF` on `EPOLL_CTL_ADD`; the kqueue backend treated `EBADF` and `ENOENT` as success for an `EV_ADD` as well as an `EV_DELETE`, so on macOS a wait on a closed descriptor registered nothing, reported success, and slept until its timeout, or forever without one.
- **Check** — Each backend ignores "not registered" or "bad descriptor" only on removal. The closed-descriptor check runs on every poller backend the build can select, not only the Linux one.
- **Seen** — rewrite (rt_fd_test, run on macOS).

## 4. Fork, randomness, locks and per-process identity [runtime]

### B-4.1 Shared or replayed PRNG state
- **Pitfall** — The id generator was seeded at module load, so forked processes drew the parent's sequence and named staged bodies and trash entries identically. Global `Random` was seeded by whichever module called `self_init` first. Under OCaml 5 a shared `Random.State` is a data race. `Id.short` fell back to pid+time without `/dev/urandom`.
- **Check** — A private, pid-tagged state reseeds from the kernel after fork and is split per domain (or locked). Security tokens raise instead of falling back. A test draws ids from several forked processes and several domains.
- **Seen** — a42c99e5, PR #92.

### B-4.2 One-time identity files created non-atomically
- **Pitfall** — Concurrent processes could each create a client uuid.
- **Check** — Identity files are created with `O_EXCL` or link-into-place, and every process reads back the winner. Combined with B-3.1: "cannot stat" never means "absent".
- **Seen** — PR #92.

### B-4.3 Per-process state inherited across fork
- **Pitfall** — Module-level values were evaluated once in the launcher: a forked frontend reported the launcher's start time, and two processes on one memtrace fd dropped about half their samples into a file that still read clean.
- **Check** — Start time, pid-derived names, trace and log fds are re-established in the child.
- **Seen** — a0b1de78, 3d37f32f; recurred ×2.

### B-4.4 Fork under OCaml 5
- **Pitfall** — `Unix.fork` is refused once a second domain exists. Forks ran inside `List.map`, whose evaluation order is unspecified.
- **Check** — Fork (if at all) happens before any domain or scheduler starts, in an explicit ordered loop.
- **Seen** — rewrite notes (07-daemon-cli, 06-backends, 08-frontends).

### B-4.5 POSIX record locks are per process
- **Pitfall** — `lockf`/`fcntl` locks merge with a lock the same process holds, and closing any fd to the file drops all the process's locks on it, so two claims in one process (GC and queue, or two copies sharing a log directory) did not detect each other. GC's in-process `held` flag was set after an await, so two sessions in one process both passed. The "held" errno varies (EAGAIN, EACCES, EDEADLK); `lockf` needs a writable fd; flock/fcntl independence holds on Linux only.
- **Check** — An in-process check-and-set (mutex or atomic, no await between test and set) precedes the kernel lock. One fd is held for the claim's lifetime and no other fd to the file is ever closed. Claims are tested with a real second process. Duplicate names are refused at config time.
- **Seen** — PR #40, PR #52, rewrite notes (05-ops-config, algorithms/gc); recurred ×2.

## 5. Exceptions, FFI totality and process lifetime [runtime]

### B-5.1 The scheduler thread died and the process hung
- **Pitfall** — FUSE handlers reach the loop via `run_in_main`. An exception raised inside C callback dispatch (an SSL read in libev), outside any promise, killed the loop; every FS call then blocked silently for 47 minutes until systemd aborted. `at_exit` handlers would drain through the dead loop and hang too.
- **Check** — Every callback the scheduler dispatches has a top-level guard. If the scheduler (or a pool domain) dies, the process exits with `Unix._exit`. Cross-thread submissions observe a stopped flag and fail instead of waiting.
- **Seen** — 80a1f462.

### B-5.2 A handler's error path allocated and changed the errno
- **Pitfall** — The binding mapped any non-`Unix_error` to ERANGE. `on_loop` formatted and logged (allocating) before settling the errno; a second exception escaped and rclone saw `pwrite64 = -1 ERANGE`, with 0 log lines. When finally recorded, the cause was a deterministic `Invalid_argument "String.sub / Bytes.sub"` in the write path, not OOM.
- **Check** — At an FFI crossing the errno is settled first with a preallocated exception, the failure counted with a non-allocating increment, and reporting deferred to the loop. Backtraces are recorded. A failure counter is exposed in stats.
- **Seen** — deeb5204, PR #44, PR #45.

### B-5.3 An inner catch made the outer guard unreachable
- **Pitfall** — `mknod` mapped every exception to `Unix_error EIO`; the outer guard only fires on non-`Unix_error`, so it never ran and errors never reached the ring.
- **Check** — Exceptions are converted at exactly one layer; only `Unix_error` is answered in OCaml and everything else reaches the error ring.
- **Seen** — c94929fe, PR #41.

### B-5.4 An OCaml exception crossing into C aborts the host
- **Pitfall** — An exception escaping a callback kills the host process (Dolphin, the Android app, which has no supervisor).
- **Check** — Everything registered for or reachable from C (JNI, `Callback.register`, shared-object entry points) catches everything and returns a neutral value or `-errno`.
- **Seen** — 57e9008b, rewrite notes (08-frontends, frontends/android).

### B-5.5 Exit, backtrace and finaliser traps
- **Pitfall** — Calling `exit` inside the loop ran `at_exit` mid-run and skipped the drain. Re-raising on another thread replaced the backtrace. `Fun.protect` raises `Finally_raised` if the finaliser raises.
- **Check** — The scheduler returns an exit code and the process exits after it. Raw backtraces are captured before any cross-domain re-raise. Finalisers (close, unlink_quiet) never raise.
- **Seen** — rewrite notes (07-daemon-cli, frontends/fuse, backends/local).

### B-5.6 Process lifetime held by accident
- **Pitfall** — On Android the sweep loop doubled as the scheduler keep-alive. Replacing it with a call that returns made the scheduler exit; host threads whose `on_loop` blocks until the loop takes the job then hung forever. Stopping from the FUSE main thread needed a notification that is a no-op once the loop is gone.
- **Check** — The main fiber awaits a stop that only stop resolves. Cross-thread submission is an atomic flag plus a wakeup fd and refuses when stopped.
- **Seen** — PR #79, rewrite notes (frontends/android, frontends/fuse); recurred ×2.

### B-5.7 Foreign threads and JNI
- **Pitfall** — An unregistered foreign thread has no `Caml_state` and segfaults at its first blocking section. Registration returns with the lock released. Registering the startup thread fails (`caml_c_thread_register` answers 0). Dead threads left registered make the GC scan a vanished stack. `GetPrimitiveArrayCritical` stalls the JVM GC for a whole network read. HOME and `SSL_CERT_FILE` must be set before `caml_startup`; a raising getenv is `exit 2` to an unread stderr. JNI `caml_shutdown` leaks threads bionic cannot cancel.
- **Check** — Threads register lazily, acquire/release around every entry, and unregister in a key destructor. No critical array spans I/O. The environment is ready before runtime start; every entry checks the runtime is up. Embedding that must shut down execs a process instead.
- **Seen** — 5ac172e2, rewrite notes (frontends/android).

### B-5.8 Names that cannot cross an FFI encoding
- **Pitfall** — JNI strings are modified UTF-8; `NewStringUTF` aborts the process on non-BMP characters. On macOS a lenient UTF-8 decode put replacement characters into a file's reference, so writing created a second file and deleting the first failed.
- **Check** — Names cross FFI as bytes (`byte[]`, `Data`). An item whose name does not decode losslessly is read-only.
- **Seen** — cc90f688, 1eb17120; recurred ×2.

## 6. Deadlines, cancellation and connection pools [store]

### B-6.1 Network calls with no deadline park forever
- **Pitfall** — No GCS request, nor the token fetch inside it, was bounded. A pooled connection whose peer vanished without FIN left a read pending forever, and the single-worker deferred queue stalled all day. The first bound, 300 s, was copied; measurement over 61,956 objects found 14 timeouts, all succeeding on first retry, arriving in clusters of 2-4 against a pool of 4. The bound became 60 s.
- **Check** — Every network call, including token minting and connection setup, sits inside a deadline chosen from measurement as a stall detector. A timeout is transient. Expect a pool's whole in-flight set to die together.
- **Seen** — 110862db, 55ca68f8, 8d57ac65 (#67); recurred ×2.

### B-6.2 A stall timeout implemented as a total budget
- **Pitfall** — The "stall detector" bounded the whole request: eight 8 MiB reads on a 1.5 MB/s link each passed 60 s, were refetched, and most bytes were discarded.
- **Check** — Read timeouts reset on each received piece; request bodies being sent have their own budget.
- **Seen** — 243d32ee, 338d01b4.

### B-6.3 A cancelled request left a dead connection in the pool
- **Pitfall** — A request cancelled by timeout left its pooled connection failed, and every later request drew the same corpse.
- **Check** — Cancellation or timeout evicts the connection it used. Under fibers, cancellation between "taken from pool" and "returned" must not leak or recycle a half-used connection.
- **Seen** — 07385f4f.

### B-6.4 A deadline cancelled an inner step, not the waiter
- **Pitfall** — A deadline around the dial fired on time but left the connection cache's waiter parked, so the call still took 300 s. The cache also ran its own silent retry loop under the backend's retry.
- **Check** — Deadlines cancel what the caller actually waits on (the pool waiter). There is exactly one retry layer, and it logs.
- **Seen** — PR #49.

### B-6.5 Cancellation does not interrupt a blocked syscall
- **Pitfall** — Swift `Task.cancel()` does not reach a thread blocked in `recv`. Threads come from a small global pool, so each cancelled fetch leaked one until none were left. A late `shutdown` could hit a reused fd number. Failed or cancelled fetches also leaked temp files. (also platform)
- **Check** — Cancelling a fiber or thread blocked in a syscall actively unblocks it (shutdown the fd under a lock guarding against fd reuse). Temp files are removed on every exit path.
- **Seen** — d0e0c1d4, PR #101.

### B-6.6 OpenSSL per-thread error queue leaks between connections
- **Pitfall** — One connection's shutdown error stayed in the thread's OpenSSL error queue and failed the next handshake (Backblaze B2 "shutdown while in init").
- **Check** — The error queue is cleared before each SSL call. Under domains, fibers migrating between threads must not inherit another connection's queue.
- **Seen** — rewrite notes (backends/s3).

### B-6.7 Error body excerpts lost the message
- **Pitfall** — Bodies were cut at the first line break, so pretty-printed JSON logged `HTTP 429: {`; an nginx HTML error page put thousands of lines in the log per stalled fetch.
- **Check** — Error bodies are flattened and truncated by length (about 200 chars); the status code carries the meaning.
- **Seen** — c943088c, 8d57ac65.

## 7. FUSE and directory watches [platform]

### B-7.1 FUSE stop hung while another process held a file open
- **Pitfall** — `fusermount3 -u` refuses while busy; the failure was ignored and the process waited on `Fuse.main`, which returns only when the kernel drops the connection. A lazy detach alone still hung 20 s; systemd killed it at 90 s with SIGABRT. Only closing `/dev/fuse` (exiting) ends the session; aborting via `/sys/fs/fuse/connections` is root-only.
- **Check** — On a requested stop: drain, lazy-detach, exit. The test holds an fd open across stop and asserts a prompt exit without a signal.
- **Seen** — c099c4d7, PR #39.

### B-7.2 FUSE reads with no deadline block suspend
- **Pitfall** — A read of uncached bytes waited under a retry ladder over minute-long timeouts; a process in a FUSE read cannot be frozen, so suspend with the link gone sat 44 s and failed.
- **Check** — Kernel-served reads have a deadline (15 s) answered as EIO, while the fetch continues for the cache.
- **Seen** — 0f9a529e.

### B-7.3 Kernel caches need explicit invalidation
- **Pitfall** — Timeouts cover lookups, but a stale `readdir` survives until the directory is reopened; fixing it needs `fuse_lowlevel_notify_inval_entry`. Invalidating the mount root answers ENOSYS (the rewrite logged it on every change). Invalidation needs fuse3 ≥ 3.10.
- **Check** — Remote changes invalidate kernel entries, skipping the root. The minimum fuse3 version is checked at build.
- **Seen** — PR #38, c63691db; rewrite.

### B-7.4 libfuse logs to unflushed stderr and rewrites bad errnos
- **Pitfall** — `fuse_send_reply_iov_nofree` turns an out-of-range error into `-ERANGE` and writes `fuse: bad error value` via `fuse_log` to stderr, which under journald is a fully buffered socket that never flushes.
- **Check** — `fuse_set_log_func` routes libfuse logging into the daemon logger. Only valid errnos are returned.
- **Seen** — PR #44.

### B-7.5 Binding and operation semantics
- **Pitfall** — Wrapping the `undefined` op in a closure registers it, so ENOSYS replaces libfuse's default. libfuse installs signal handlers only where the disposition is SIG_DFL. `Fuse.main` must keep the main thread. With no `create`, the kernel falls back to mknod+open. `readdir` ignored offsets; directory mtime was "now" on every getattr; fsync/flush were no-ops. Startup ran `fusermount3 -uz` on whatever was mounted. Mount points were not normalised, so discovery by exact string missed trailing slashes.
- **Check** — Signal handlers are installed before `Fuse.main`. create, offsets, stable attributes and real fsync are implemented. Only a mount that is ours is unmounted. Mount points are normalised.
- **Seen** — rewrite notes (frontends/fuse).

### B-7.6 File managers treat an unknown FUSE type as a local disk
- **Pitfall** — Dolphin's thumbnailers opened every file in view; each seek pulled a 16 MB cache chunk (8 download slots busy, 32 reads waiting). KIO's slow-mount list is hardcoded by fs type.
- **Check** — Mount with a subtype file managers treat as remote and a distinct `fsname`; characters going into the `-o` list are validated.
- **Seen** — PR #107.

### B-7.7 Watch targets and network mounts
- **Pitfall** — Writes go to a temp name and rename into place, so a watch on the object follows an inode unlinked immediately. Network mounts deliver no events for remote writers.
- **Check** — Watch the directory, arm the watch before reading, and cap every wait at the poll interval. Native watches are an accelerator over a poll fallback.
- **Seen** — f9f136d5, PR #72.

### B-7.8 A watch woken by its own scratch files
- **Pitfall** — A read's reflink temp inside the watched store woke the watch on its own directory (an OOM loop). Filtering by temp name works on Linux only: macOS vnode events carry no name, and `O_TMPFILE` still fires on close with no name. On non-clonable filesystems the first read per directory still creates and unlinks a temp.
- **Check** — Scratch files live outside any watched tree. Name filters, if any, are not relied on portably; macOS polls.
- **Seen** — 21f93132, a3701654, rewrite notes (04-checkout-cache, backends/local); recurred ×2.

### B-7.9 Watcher lifecycle
- **Pitfall** — Local watchers were never closed, one per directory for the life of the process. A watcher whose directory was deleted went silent and the store fell back to 2 s polling for good. In rewrite tests, a write's close event queued after the create woke the next test case early.
- **Check** — Watchers have an owner that closes them; a removed directory drops and re-arms its watcher. Tests drain leftover events between cases.
- **Seen** — PR #72, f2b70a45, 60124181; rewrite.

## 8. macOS, Android and desktop platform traps [platform]

### B-8.1 The File Provider sandbox denies daemon-written files
- **Pitfall** — The extension read the resync token, and later the read-only flag, from group-container files written by the daemon; the sandbox denied it, so every anchor carried an empty token (reimport expired nothing) and every domain read as writable.
- **Check** — The extension gets every fact from the daemon over IPC, never from daemon-written files.
- **Seen** — 807e1454, 061b7ab7, PR #88, PR #101; recurred ×2.

### B-8.2 File Provider enumeration contract
- **Pitfall** — Returning a cached anchor from `currentSyncAnchor` meant "nothing new" and stopped sync (tried twice, reverted). Filtering changes by the materialized set dropped removals under unbrowsed folders. Page tokens are capped at 500 bytes; a working-set token carrying pending folders silently ended enumeration at about 26 folders. Initial-page sentinels (`"FPPageSortedByName "`) are valid UTF-8 and would resume mid-folder if left to a decode.
- **Check** — Follow the documented sequence (anchor, full enumeration, changes from the anchor); report every change; keep tokens small and opaque; match system sentinels before decoding.
- **Seen** — a06abe2f, PR #80, PR #81, PR #87; recurred ×2.

### B-8.3 File Provider completions and errors
- **Pitfall** — `createItem`/`modifyItem` could complete with neither item nor error. Moving into the system's directory is EPERM, and `NSPOSIXErrorDomain` errors are rejected outright, so failures surfaced as bare I/O errors. An aligned range came out empty when the file was shorter, the daemon rejected length 0, and the system retried the unknown error forever.
- **Check** — Every completion supplies an item or an error. Content is written to the caller-named destination. Errors are Cocoa-domain; "version no longer matches" maps to the framework's version-gone error.
- **Seen** — 9cb2f9c4, eff2c3ac, 51c9b0f6.

### B-8.4 File vs package detection from absent fields
- **Pitfall** — A nil contents URL was taken as "package", but the system also omits it when the requested fields exclude contents, so a flat file with a package-like extension was created as a folder, bypassing the reimport guard. The plain extension lookup invents dynamic UTTypes.
- **Check** — File vs directory comes from what the system positively offers; only declared UTTypes are trusted.
- **Seen** — 018472fc, bdf8a44f.

### B-8.5 Platform-generated names follow undocumented rules
- **Pitfall** — A domain named "Media Library" became `TsyncApp-MediaLibrary`; the guess `TsyncApp-media-library` made every file read cloud-only, and substring path claiming failed on spaces and fell through to the first domain.
- **Check** — Platform-generated names are matched loosely (alphanumerics) in one helper, tested with spaces.
- **Seen** — ed0084b3, 9a9322a9.

### B-8.6 macOS process and launchd traps
- **Pitfall** — `pkill -f` on the app path also killed the daemon, which exited 0 on SIGTERM, so `KeepAlive{SuccessfulExit=false}` never restarted it. Unix socket paths cap at 104 bytes. launchd starts processes with an fd limit of 256. `SMAppService.agent` reports notFound for a correct agent. Re-signing must preserve derived entitlements, inside-out. Reads over ssh bypass fileproviderd and cannot trigger enumeration.
- **Check** — Daemons are never matched by app path; unexpected stops exit non-zero. Socket path length is checked before bind and connect. The fd limit is raised at start.
- **Seen** — 08c29b9f, rewrite notes (frontends/file-provider); rewrite.

### B-8.7 QuickLook and sandboxed UI work
- **Pitfall** — The sandboxed menu bar app opening shared-container files caused a prompt/relaunch loop. QuickLook types by extension (staged bodies are uuid-named) and resolves symlinks. A generator may never answer; worker threads have no autorelease pool. `getUserVisibleURL` is security-scoped.
- **Check** — File-touching work for sandboxed UIs runs in the daemon; previews use a temporary hard link under the real name; every platform callback is bounded (10 s).
- **Seen** — PR #36.

### B-8.8 Android freezes a cached process that serves reads
- **Pitfall** — Proxy-descriptor reads are served in the app process; with no stable client reference Android froze it mid-movie (audio underrun 3 s later, then zero CPU), killing playback 38-58 s in. It looked like a read-path stall.
- **Check** — A foreground service is held while any served descriptor is open, the count and claim taken and released together, released on partial-open failure. Slow reads and open counts are logged.
- **Seen** — 76905162, PR #78.

### B-8.9 Android foreground-service limits
- **Pitfall** — Android 15 limits dataSync services to about 6 h a day and kills the process 10 s after asking it to stop; the camera backup service died on start and WorkManager rescheduled it into a crash loop. The manifest must merge `foregroundServiceType` onto WorkManager's service. Background starts are barred on Android 12+.
- **Check** — Every foreground service handles `onTimeout` by stopping itself; the merged manifest declares the type; start refusal is handled.
- **Seen** — 6195b248, PR #57; recurred ×2.

### B-8.10 Android IPC and child supervision
- **Pitfall** — The abstract unix socket namespace is device-wide, so any app could drive the daemon. The service restarted the daemon only if its field was null, and the field held the dead Process.
- **Check** — Sockets live under app-private storage. Child exit (EOF) is supervised with restart and a give-up after N rapid deaths.
- **Seen** — 5ac172e2, 1ba3f1bb.

### B-8.11 Android libc and platform API differences
- **Pitfall** — A Linux guard let `getloadavg` through on Android, where it is absent before API 29. `LIMIT` in a MediaProvider sort order is rejected by recent versions. The trust bundle was built once and never rebuilt. A domain cannot be reopened in-process after a config change. SELinux denies `link(2)` in an app's data directory with EACCES, not EPERM: a hard-link fallback keyed on EPERM never ran, and the first boot on a phone failed with "permission denied" while creating an identity file. Reading `/proc/loadavg` is denied too, and the read raised instead of answering "unknown", so every `stats` request failed on the phone. Bionic has no `malloc_trim` and declares `syncfs` from API 28 only.
- **Check** — C platform guards distinguish Android and API level. Trust material is rebuilt on change. Every `link` call site falls back on EACCES as on EPERM, and was run on a device, not only cross-compiled.
- **Seen** — 7a9ba837, rewrite notes (frontends/android). recurred ×2, rewrite: first device run of the rebuilt app.

### B-8.12 Desktop plugins doing IPC on the UI thread
- **Pitfall** — The Dolphin plugin swept daemon sockets on the menu thread: two daemons accepting without answering cost 0.3 s per right-click, and one sending bytes without a newline froze Dolphin. KF6 reads `MimeTypes` at the JSON root as empty, and `QDir::AllEntries` excludes unix sockets.
- **Check** — No unbounded IPC on a UI thread; static facts computed in-process; network round trips asynchronous with a deadline.
- **Seen** — PR #74, PR #75.

### B-8.13 Logging under a service manager
- **Pitfall** — Under systemd stderr is the journal, so syslog `LOG_PERROR` doubled every line. Carriage-return progress was dropped when stderr was not a TTY, so a run teed to a file recorded hours of nothing; gc took no `--verbose`.
- **Check** — Echo to stderr only when it is a terminal; long operations log progress through the logger otherwise; every command exposes verbosity.
- **Seen** — 51d1bb53, PR #98, 27685a67.

### B-8.14 systemd unit traps
- **Pitfall** — The default 90 s stop timeout masked a hanging drain. With a bad config, `tsync start` exited 0 and the unit had no `RestartPreventExitStatus`; a stale unit pointing at a missing binary restart-looped every 5 s. The fd soft-limit target (8192) disagreed with the unit (65536). In the rewrite a first start failed when the data directory did not exist, and an unanswered socket surfaced as a raw exception. `graphical-session.target` is unpopulated on XFCE and Cinnamon.
- **Check** — `TimeoutStopSec` matches the designed grace (30 s). Config errors exit with a status the unit will not restart on. Parent directories are created at start. Every IPC failure is a sentence. Desktop autostart uses XDG autostart.
- **Seen** — PR #105, PR #48, dd18fa63; rewrite.

### B-8.15 A throwing Swift initializer still runs `deinit`
- **Pitfall** — Once every stored property is set, a `throw` from an initializer still runs `deinit`. The subscription closed its socket and then threw, and `deinit` closed the same number again; the second close can hit a descriptor another thread just reused (a request socket, a manager's descriptor). The relay retries every few seconds while the service is down, so it fires often.
- **Check** — A descriptor is closed in exactly one place, `deinit`, or marked invalid before any `throw`.
- **Seen** — ed6931d6, rewrite.

### B-8.16 A full backlog on macOS reads as nothing listening
- **Pitfall** — `Ipc.Client.connect` promises a deadline when a server's backlog stays full and `Not_serving` only when nothing listens. Linux tells the two apart (`EAGAIN` on a non-blocking connect against a full backlog, `ECONNREFUSED` for a stale socket); macOS answers `ECONNREFUSED` for both, so a busy owner is reported as absent and a caller may fall back to acting as if no owner ran.
- **Check** — "Nothing listens" is decided from a fact that cannot be confused with load (the ownership lock), not from the connect errno alone, on every platform the client runs on.
- **Seen** — rewrite (ipc_test, run on macOS); open.

## 9. Cloud functions, IAM and event pipelines [store]

### B-9.1 Function wiring failures look like a clean store
- **Pitfall** — The Eventarc trigger lacked `roles/run.invoker`, so all 4096 deliveries failed with `lacks run.routes.invoke` while everything read ACTIVE. The GCP runtime picked the background signature (`TypeError ... 2 were given`). Without `RETRY_POLICY_DO_NOT_RETRY` an unreadable bucket retries forever; with it, and with a Lambda lacking a DLQ, a failed request vanishes. Events are at-least-once and unordered.
- **Check** — Handlers are tested under every invocation convention. Undelivered work stays visible from the client ("requests not draining"). Handlers are idempotent and order-independent (clear the marker before the check).
- **Seen** — 85eec164, 228b73b3, 0d3fc3a1, PR #50, PR #58, PR #95; recurred ×3.

### B-9.2 Key layout constrained by prefix-only policies
- **Pitfall** — GCS IAM conditions only support `startsWith` (no `contains`), and notification filters take literal prefixes, but chunk keys had the domain in the middle; markers and requests moved to domain-first, and chunks needed an `extract` condition in a custom delete-only role. Once a policy has conditional bindings, gcloud refuses unconditional adds without `--condition=None`.
- **Check** — Any key family that needs scoping by domain has the domain as a literal prefix.
- **Seen** — 27685a67, PR #50, PR #58; recurred ×2.

### B-9.3 Notification and infrastructure-as-code traps
- **Pitfall** — S3 rejects overlapping notification prefix filters; `aws_s3_bucket_notification` replaces the bucket's whole notification config; Eventarc storage triggers have no prefix filter. A terraform attribute on the wrong var failed only at plan (`tofu validate` was silent). `archive_file` packs gitignored files. The share function refuses anything over 10 GiB.
- **Check** — Infrastructure changes run `plan` in CI; notification configs are owned in one place; function archives list their files explicitly.
- **Seen** — bfd2761d, 9a9322a9, 09a7e77f, PR #50, PR #58.

### B-9.4 One capability gated in two places
- **Pitfall** — Whether a bucket has a function was gated by an env var and a backend field; only one was set, so the delete suite ran against a store answering Unsupported.
- **Check** — One fact feeds every gate that depends on it.
- **Seen** — 27685a67, PR #95.

## 10. OCaml language, stdlib and OCaml 5 semantics [runtime]

### B-10.1 `Lazy` forced from two domains raises
- **Pitfall** — Forcing a lazy value from two domains raised `Lazy.Undefined`; the old code had lazy per-store device probes and similar values.
- **Check** — No `Lazy.t` reachable from the domain pool; build eagerly or use a mutexed once-cell. Grep for `lazy` and `Lazy.force`.
- **Seen** — 4fe6ec7f; rewrite.

### B-10.2 Bounds checks that overflow
- **Pitfall** — Decoders computed `pos + len` before comparing with the end; on 32-bit this overflowed into `String.sub` raising `Invalid_argument` where `Failure` was promised. http-proxy frame decoders had the same `pos + n > len` form.
- **Check** — Bounds compare `len > total - pos`. Decoders of untrusted input raise only their documented exception (fuzz with huge lengths).
- **Seen** — c4284b23, PR #70, cff6235d; recurred ×2, rewrite.

### B-10.3 Integer width and sign traps
- **Pitfall** — `Int64.to_int` of a size truncates on 32-bit. Reading unsigned int32 into a 63-bit int made negative-length checks dead code. The rewrite's disk-space report read the total as free.
- **Check** — Wire integers are range-checked at decode; 32-bit builds are tested; statvfs fields are named, not positional.
- **Seen** — aa3264af, rewrite notes (02-remote-model, 05-ops-config); rewrite.

### B-10.4 Unspecified evaluation order
- **Pitfall** — Record field and function argument evaluation order is unspecified: it reordered pool creation and reporting, ran forks inside `List.map` in unknown order, and evaluated `Sys.file_exists p`/`read_file p` as arguments outside their guard (3 of 16 harness runs died on that TOCTOU).
- **Check** — Order-sensitive effects are bound with sequential `let`; no effectful expressions as sibling arguments or record fields.
- **Seen** — 6d5315e8, rewrite notes (02-remote-model, 07-daemon-cli); recurred ×3.

### B-10.5 Semantics resting on physical equality
- **Pitfall** — A claim's won/lost result was decided by physical equality of a buffer; anything that copied it flipped the answer.
- **Check** — No outcome depends on `==` of buffers or strings; results are explicit variants.
- **Seen** — rewrite notes (03-journal-sync).

### B-10.6 Stdlib functions that raise on edge input
- **Pitfall** — `List.take` raises on a negative count a proxy client can send (and needs a newer compiler than the opam files allowed). Yojson `Util.to_*` raise `Type_error`, not `Failure`. `Unix.realpath` raises on dangling paths. Staging discarded short writes.
- **Check** — Client-supplied numbers are validated at the boundary. JSON access catches `Type_error`. Writes loop on short counts.
- **Seen** — 07369f79, rewrite notes (01-core).

### B-10.7 Float timestamps compared for equality
- **Pitfall** — Manifest mtimes stored as doubles cannot hold nanoseconds exactly, so rsync's mtime fast path never compared equal.
- **Check** — Timestamps that are compared are integers (ns) or compared with explicit tolerance; content decides identity.
- **Seen** — PR #82.

### B-10.8 Type-system traps
- **Pitfall** — A shared `return_none` bound as a value was monomorphised by the value restriction to the first option type used. A package type cannot constrain a parametrised type, and two identical package types are distinct unless the module type is equated.
- **Check** — Polymorphic helpers are eta-expanded. Monad-parametrised first-class modules use `with type` equations and name the instantiated signature at use.
- **Seen** — 4b60fb43, fb433875, f6df70b7.

### B-10.9 An effect run through a short-circuiting fold
- **Pitfall** — The shared socket's `pause` applied the request to every domain with `List.for_all (fun s -> Handler.call s.handler (Pause on))`, folding the effect and its answer in one pass. `for_all` stops at the first `false`, and a resume answers `false`: only the first domain resumed, and the menu, reading the reply as "not paused", offered Pause only.
- **Check** — An effect applied to every element is a `List.iter` or `List.map`; its answers are folded afterwards. `for_all`, `exists`, `&&` and `||` take pure predicates only.
- **Seen** — rewrite (review of PR #114).

### B-10.10 A fold that keeps only part of its best element
- **Pitfall** — Choosing a trashed folder's newest entry folded over triples `(entry, marker, path)` and, when the current element was not newer, returned `(best_entry, current_marker, current_path)`: the date of one entry beside the path of another. A folder trashed twice under different paths reported the path of whichever entry the fold visited last, so `trash --purge PATH` missed the folder just trashed or purged an older one.
- **Check** — A fold selecting an element keeps or replaces it whole (`if better cur best then cur else best`), never rebuilding the accumulator from pieces of both; or it selects by a key (`List.sort`, a max by key) and destructures once.
- **Seen** — rewrite (review of PR #114).

## 11. Build, link and packaging [build]

### B-11.1 Link-time registration silently drops drivers and frontends
- **Pitfall** — Drivers register as a link side effect. Without `-linkall` an unused module was dropped. Removing an "unused" dependency compiled and linked, then failed with "unknown backend type" in 61 rules; leaving the flag behind when moving a driver made every store unknown. Resolving the registry at module init depended on link order. A dependency-remover script did nothing on single-line stanzas and said nothing. fuse was a C library needed at link but named nowhere.
- **Check** — Release and conformance builds assert the registry lists every intended driver and frontend (CI fails if the binary lacks fuse; conformance exits 2 when no store ran). Registries resolve at call time. Cleanup tools report "changed nothing".
- **Seen** — 38d92756, 8b266eed, 5a897988, dc1472ef, 584e3521, ffcbe492, 4fe6ec7f, 4c812de8, 5cd0c1e6; recurred ×5, rewrite.

### B-11.2 `(optional)` libraries vanish and the build stays green
- **Pitfall** — An edit joined two dependency names into one; `(optional)` turned that into absence, `select` fell to `s3_link.disabled.ml`, and s3 was not compiled for several commits, including the one adding its claim. Missing `aws-s3-lwt` or fuse3 did the same; the FUSE and s3 frontends never compiled on macOS. `select` resolves against installed libraries, so an orphaned `~/.opam/<switch>/lib/...` changed what was compiled and `-p` failed with "inconsistent assumptions".
- **Check** — Anything meant to be built fails when it is not: non-optional on its platform, or an artifact assertion (`build-info`, `.cmxa`). Suspect orphaned opam lib dirs when packaged builds break.
- **Seen** — c51dba7f, PR #40, PR #42, PR #44, PR #45, PR #46, PR #49, PR #67; recurred ×4.

### B-11.3 An optional TLS dependency degraded to a stub
- **Pitfall** — The opam file named `tls`, not `tls-lwt`, so a plain install linked conduit's `No_tls` stub, refusing every https connection at run time. Builds worked only because another package pulled it in; stress CI ran with no TLS at all. TLS alternatives cannot be expressed in dune, so opam files are hand-written.
- **Check** — Selecting a TLS backend fails loudly when none is linked. A minimal install makes a real https request in CI.
- **Seen** — e7398f8a, ab65b6ab, PR #47, 639b97ea; recurred ×2.

### B-11.4 Package metadata out of sync with the build
- **Pitfall** — The executable belonged to no package, so `dune build -p tsync` installed nothing. CI installed from a hand-written dependency list that missed `re`.
- **Check** — Dependency lists are generated from one source. CI tests the packaged install path (`opam install`, deb, rpm) for the features it must carry.
- **Seen** — 30297254, e49f4648; rewrite.

### B-11.5 Cached opam switches froze or mixed revisions
- **Pitfall** — Branch pins keep their version string, so a restored opam root satisfied deps with stale fork revisions. `restore-keys` fell back across fork revisions and restored http and cohttp from different commits of one monorepo. The android key was bumped by hand.
- **Check** — Cache keys include every pinned revision with no cross-revision fallback; cached switches re-pin, update and reinstall forks; release builds use fresh switches.
- **Seen** — 549b1c75, 80eb18cf, 5ff6edb1, 8aaee2bb, PR #51; recurred ×4.

### B-11.6 Dune flags and transitive dependencies
- **Pitfall** — `(flags (:include ...))` replaced dune's defaults and dropped `-fPIC`; x86-64 linking failed while aarch64 passed. A scripted edit reached only the first of three per-OS stanzas, and Linux still built through a transitive dependency. Without `implicit_transitive_deps false`, 24 libraries were reached transitively, and a missing dependency produced an error naming no file.
- **Check** — Added flags include `:standard`. Every module a stanza opens is a direct dependency. Every arch and per-OS variant is built in CI.
- **Seen** — 73989748, 106ef170, 3050edc1.

### B-11.7 Doubled doc comments silently disable formatting
- **Pitfall** — Two consecutive `(** *)` blocks trigger warning 50; ocamlformat then skips the whole file and odoc drops the first comment. 35 stale pairs had built up, each reading as authoritative for the wrong definition. It recurred in the rewrite.
- **Check** — Never two comment blocks back to back; a file ocamlformat leaves unformatted fails CI.
- **Seen** — 8e308e4a, 5a412c0f, 757e02bd, 79591952, cb792b48; recurred ×3, rewrite.

### B-11.8 Shared objects: soname, rpath, PIC, alignment
- **Pitfall** — dune sets no soname, but the loader searches by it. `(modes object)` links the runtime without -fPIC (rejected inside a .so on aarch64). A plugin kept a build-machine rpath (rpmbuild refused it). A missing `-llog` and 4 KB page alignment (Android 15 needs 16 KB) fail only at dlopen. Including KDEInstallDirs before Qt gave a path without qt6.
- **Check** — `(modes shared_object)` with an explicit soname equal to the file name. Release checks assert no build path survives in shipped binaries and test loading the artifact, not linking it.
- **Seen** — c5d8b464, 9d93eeee, 896b0b1d, 57e9008b.

### B-11.9 Package checks that pass because the build environment is present
- **Pitfall** — `ldd` ran inside a container with `-dev` packages and the `_build` rpath still present, so undeclared runtime deps passed. apt reads `Packages.gz`, so tampering with `Packages` proved nothing; two repo sites built in the same second looked identical (304); a per-run GPG key made apt keep the old index. Container installs no-op scriptlets without `/run/systemd/system`, and the deb had no maintainer scripts, so upgrades left the old binary serving.
- **Check** — Package checks run in a clean environment with a negative control (the daemon must not depend on libdbus). Scriptlets are asserted present in the archive.
- **Seen** — PR #48, 82d7324e, 5baa98c5, cc65dd2d, c83131f8; recurred ×3, rewrite.

### B-11.10 Release artifact naming and signing
- **Pitfall** — rpm outputs named by distro and arch only overwrote each other. GitHub rewrites `~` in asset names, so a prune glob never matched and 9 generations piled up. Packagers named a moved target by hand. AGP's per-machine debug key on ephemeral runners gave every nightly APK a new signature, so each install wiped the app's config.
- **Check** — Artifact names include package name and are matched after the host's rewriting. APKs are signed with one persistent key and CI refuses others.
- **Seen** — 5c560e55, 722cc3f5, b4ab5e52, PR #48.

### B-11.11 A rewrite that deletes code deletes the checks resting on it
- **Pitfall** — The rewrite removed the old implementation and, with it, the generators of golden files that a second implementation reads: `tests/unit/hash` and `tests/unit/gc_job`, whose output the bucket functions' Python tests check their chunk and delete-request keys against. It also dropped the workflows that ran those tests, and left `release-repo` pointing at `scripts/setup_repo_signing.sh`, which no longer existed. Nothing failed: the checks simply stopped existing.
- **Check** — Before deleting a tree, list what reads from it (golden files read across languages, scripts named in workflows and docs, workflow `uses:` and `run:` paths) and carry each over or delete its reader. Every path a workflow names exists in the tree.
- **Seen** — rewrite (ci-workflows).

## 12. Test harnesses that pass while testing nothing [tests]

### B-12.1 Suites that verified nothing and reported success
- **Pitfall** — Crash mode injected 0 faults and passed 112 ops; all nine scheduled fault cells landed 0 faults; a CI sweep scored 16 aborted runs clean ("no FAIL lines"); an unpublished store counted as "all checks pass"; conformance passed with no store configured; Gradle and `connectedAndroidTest` pass with zero tests. 17 hand-rolled check helpers, only 6 counting; one suite reported 0 checks; "does not raise" checks were constant `true`.
- **Check** — One counting harness; every suite asserts a positive expected count of what it exercised (faults landed, store non-empty, mount is a mount, N racers, N tests) and exits non-zero when nothing was verified.
- **Seen** — e28d940f, 5412f45f, a8216afb, 698cdef5, 6933cc16, b2e6f69b, 332aac1b, PR #56, PR #57, PR #68, PR #77; recurred ×8.

### B-12.2 Tests never seen red
- **Pitfall** — Inverting a listing predicate left mirror suites green. An idempotence test passed against the mutant because records had already completed. A prefetch count asserted that a fire-and-forget loop had done nothing, which the bug also produces. GC scenarios read a cached file whose chunk was gone. 5-byte conformance bodies fit one socket read, where framing cannot be wrong. Completion tests used an `ls` that exits 0 on a missing path. A zsh unsplit `$VAR` turned a planted type error into file-not-found.
- **Check** — Each new test is run against a planted defect and seen red, grepping for the specific planted error. Content oracles bypass caches. Bodies are realistic size with position-dependent data. Contents are compared, not name sets.
- **Seen** — 22819312, c7ec7a55, 61c66680, c7aaea56, PR #40, PR #41, PR #42, PR #52, PR #53; recurred ×6.

### B-12.3 Tests that were never built or ran stale
- **Pitfall** — A plain `dune build` compiles neither the scenario runner nor reliably the test executables; a stale `.exe` matched its golden and a removed API left tests broken behind green builds; test trees outside the run did not compile on main for days. `dune.inc` generated before the snapshot existed diffed nothing. `--force` replays cached `.output`. Environment variables are not tracked deps. A platform-gated test with no default alias ran on a plain build; an empty default alias under `tests/` did nothing because the root recurses through `all`. A golden file was committed but no step ran its reader.
- **Check** — CI runs the `runtest` aliases per tree and reads their exit code. Every test file is wired into a runner. A golden diff unchanged after adding a print means a stale binary.
- **Seen** — d44d4feb, 947d0bd0, 1c36c301, df1da81b, 0c2faa51, 3050edc1, 27685a67; recurred ×5.

### B-12.4 Snapshot rules that hide failures
- **Pitfall** — A test died with status 2 before the diff, its exception on the stderr dune discards, so CI said "exited with code 1". An ls test configured a frontend macOS lacks, exiting 1 with the error on stderr while the snapshot captured stdout. A step's usage error (`ls -R`) was recorded and compared against itself. A scenario step failure is printed and exits 0. An explicit `waitpid` raised ECHILD after a signal handler reaped the child.
- **Check** — Snapshot tests print exceptions with backtrace to stdout and exit 0 so the diff is the verdict; stderr is captured. Snapshots are reviewed for error output. ECHILD is best effort.
- **Seen** — 3d6699fd, b6dba370, 96e66e46, 7bf631a4, 7aa1fc9e; recurred ×4.

### B-12.5 Waiting on durations instead of conditions
- **Pitfall** — A fixed 1.5 s fault delay let fast CI finish first (later faults landed 218 times per run). A 3 s settle compared trees mid-apply. "Queue still for 0.2 s" was satisfied by a queue not yet started. Counts were taken between two steps of a publish (1 in 24 runs). Overlap checks compared wall clock to a constant. Scenarios passed by running out a silent 10 s deadline polling for a cursor never written. download_progress asserted on an instant the scheduler decides.
- **Check** — Waits are for states (`reached`/`held`, first journalled op, quiescence that has started). Deadlines that expire fail. Fault rates scale with workload (ops/4).
- **Seen** — 698cdef5, a990dc6d, 5372ed84, 291e583d, 7077fa7f, 4ca10217, 1e1715a1, bc7af78a, 2bd96b50, cc228921; recurred ×10; rewrite (composite_test listed parked copies right after settling, before the backfill had parked: one run in eight); rewrite (dqueue_test posted a job 50 ms after another and assumed the first had started, which a loaded CI runner did not honour); rewrite (import_test printed whichever of two detectors of a source rewritten mid-read fired first; the product now reports the one condition one way).

### B-12.6 Determinism that came from cooperative scheduling
- **Pitfall** — Exact-width assertions ("pools peak at exactly 4"), busy-waits on yield and a fake clock relied on "all ready work has run" being reachable by yielding. Race tests (promote race, racing `put_if_absent`, one GET per group) hit interleavings only at binds. Under domains these pass while missing real races. A single-reader race test would pass almost always without the retry. Six suites fail a few percent of runs under load. `Gc.stat` `live_words` counts unswept garbage; `top_heap_words` is a process high-water mark. Rewrite: export failures came in completion order; a store-watch case needed 1.5 s under load; one owner_test failure was never reproduced.
- **Check** — Use an explicit run-until-quiescent hook or conditions, never yield counts. Race tests use real parallelism and are mutation-checked (old ordering fails 10/10); run TSan where possible. Parallel outputs are ordered deterministically. Memory tests measure retained figures after a full major. A red run is rerun, then A/B'd in a separate worktree.
- **Seen** — 6b7a586c, ac32ae99; recurred ×3, rewrite.

### B-12.7 Racing an asynchronous component
- **Pitfall** — A scenario wrote and edited a file before draining; the upload raced the cancel and disk speed decided the outcome (macOS lost; Linux failed 7-10 in 100 concurrently). Concurrent uploads made kept-log order racy. The key lock prevented a guard's two writes in one promotion on CI.
- **Check** — Tests that depend on ordering hold the component (pause switch). Flakiness fixes are verified with concurrent repeat runs (150 agreed) and against the pre-fix binary.
- **Seen** — 96506c49, 4c32fa96, 291e583d.

### B-12.8 Nondeterministic and environment-dependent snapshots
- **Pitfall** — Readdir order differs between Linux and macOS, and conflict copy numbers followed it. A locale ignoring a leading dot sorted `.tsync-dir` after `pic.txt`. Random folder ids leading backend keys made dump order nondeterministic (hidden by `Id.reseed`). A tree dump dropped the count of id-less folders, so different trees snapshot identically. Lines printing clone availability passed on btrfs and APFS and failed on ext4. cmdliner styling depended on the terminal. A harness sorted items before printing and hid order.
- **Check** — Product code names deterministically; snapshots sort by byte with `LC_ALL` pinned; no ordering depends on random ids; snapshot lines state facts true on every filesystem; dumps keep every count.
- **Seen** — 724acc4f, aae5a3bf, 5b64da0d, 6468cf84, 331fec2b, bcb38107, 27bbae0e, 1c511433, e28d940f, PR #52; recurred ×6.

### B-12.9 Doubles and fixtures that bypass the code under test
- **Pitfall** — The scenario runner dropped `on_cursor` and called replay directly, so the whole suite ran with the cursor mechanism disabled. An Outage double stalls while Flaky refuses. `Fixture.conf ~store` wrapped the store while chunk reads walked members (0 round trips). A test's own fetch function bypassed the wire pools, so a redundant bound was built. A fake `LocalServerSocket(String)` bound the abstract namespace the client never used. A "mirror" fixture was an import. A Pub/Sub handler was tested under one calling convention. A conformance assertion held only while no verifier consumed the requests. Rewrite: a GC resume test built an unreachable state and failed 1 in 12.
- **Check** — Doubles sit below the layer under test; runners use production paths; faults name the call they target; fixtures come from real runs and build only reachable states; assertions state their environmental preconditions.
- **Seen** — b2e6f69b, 723493c9, 228b73b3, 27685a67, b4db4cd1, PR #57; recurred ×5, rewrite.

### B-12.10 Harness bugs that masked product defects
- **Pitfall** — The stress harness waited on paths staging had already created and accepted writes under a not-yet-mounted mount point. The oracle recorded `Rename_onto` unconditionally as `Acked`. A readdir-then-stat on a vanished name aborted the run instead of reporting "listed but unopenable". Remount after crash cleared dentries and masked a stale-cache bug. A Python checker reimplemented the binary manifest parser. Environment zeros passed trivially (missing `lsof`, `/proc/self/fd` off Linux, unsupported fallocate).
- **Check** — Observe and act in one guarded step; record only what happened; treat harness flakiness on live mounts as a candidate product bug; check with the product's own parsers; assert a must-be-non-zero count is non-zero.
- **Seen** — 6d5315e8, 15cfc5a6, 5412f45f, 4de57247, e28d940f; recurred ×3.

### B-12.11 Test isolation leaks
- **Pitfall** — Tests exported only HOME; `XDG_CONFIG_HOME` (set on CI runners) wins on Linux and macOS uses a group container, so tests read the runner's config. Fixed `/tmp` dirs and socket paths were shared and deleted by concurrent runs. Conformance cleanup hand-built the jobs prefix, which would have left 4096 objects per run after a layout move; two CI jobs sharing `GITHUB_RUN_ID` would delete each other's objects. A fire-and-forget background task of one case (a store's deferred generation settle) outlived it and recreated a lock file while the suite's teardown removed the scratch directory, failing about one run in eight under parallel load.
- **Check** — The harness sets every XDG variable and asks the binary where its files go. Scratch dirs and socket paths are per run (pid). Tests ask the layout module for paths. Cleanup scopes are unique per job. A case stops or waits for the background work it started before the next one, or the teardown tolerates it and says why.
- **Seen** — f2729184, e163bd6f, 5aa45ac1, df10ce32, PR #57, PR #77, rewrite (resume_test, then file_ids_test, on macOS); recurred ×6.

### B-12.12 A suite written on one platform pins that platform
- **Pitfall** — The rewrite's suite, written and run on Linux, failed ten tests on macOS, most of them the tests and not the code: descriptor counts from `/proc/self/fd`, memory from `/proc/self/status`, a path cut by the length of `/tmp/...` when the library reports the resolved `/private/tmp/...`, an owner's socket under a home rooted in dune's long temp directory (past the 104-byte limit), configs naming the `fuse` frontend a macOS build does not contain, a snapshot of a directory watch macOS lacks. Among them hid one real bug (B-3.10), found only because the suite finally ran there.
- **Check** — The gate runs the full suite on every platform tsync ships for. A test uses facilities present on each (`/dev/fd`, resolved paths, a short socket root), or declares the platform it needs and is reported "not run" elsewhere, never silently skipped.
- **Seen** — rewrite (ci-workflows).

### B-12.13 A check matching output styled for a terminal
- **Pitfall** — The user-install job asserted `opam list --installed --short | grep -qx tsync-tls`. setup-ocaml sets `OPAMCOLOR=always`, so each name arrived wrapped in escape codes and the exact-line match failed on a correct install: the job was red on every run of the `rewrite` branch, and a gate that is always red is read as noise.
- **Check** — A check that parses a tool's output asks for its plain form (`--color=never`, `--porcelain`, JSON). A check is seen passing on a correct build before it is trusted, as it is seen failing on a broken one (09 §10.2).
- **Seen** — rewrite (conformance, then test).

### B-12.14 A fallback branch behind a lookup that exits the script
- **Pitfall** — `macos/build.sh` looked up a signing identity with `security find-identity | grep "Apple Development" | head -1 | sed ...` under `set -euo pipefail`, then branched on an empty result to sign ad-hoc. With no such identity `grep` exits 1, the pipeline fails and the script dies in the assignment: the ad-hoc branch was unreachable, and the unsigned build a fork is promised (10 §5.3) was red on every runner. It passed on every developer machine, which all hold the identity.
- **Check** — Under `pipefail`, a pipeline whose empty output is a handled case ends in `|| true`. Each branch of a build script is run once in the environment it exists for; a "no secrets" path is seen green on a runner without them.
- **Seen** — rewrite (ci-workflows).

## Review checklist

1. **Durability and mapping** — Is every renamed/linked file fsynced first? Is anything mapped that is not immutable and rename-published? Does a no-reflink fallback map a live file? Is shared-fd I/O positioned? Do listings hide scratch names and keep key order?
2. **Store APIs** — Is `put_if_absent` probed per endpoint? Are bulk-delete per-item errors parsed? Are signed bytes the sent bytes, Host port included? Do streams and batches refuse truncation? Is range-at-EOF uniform across drivers? Are token 4xx permanent?
3. **Signals and stubs** — Does every Sys/Unix/channel call retry both EINTR spellings? Does any stub block holding the domain lock or loop unbounded? Does any fiber make a blocking syscall on a pool domain? Does the poller avoid `select`? Is SIGPIPE ignored?
4. **Fork, RNG, locks** — Is any `Random.State` shared across domains? Does anything fork after a domain exists? Are identity files created with `O_EXCL`? Is there an in-process check-and-set, with no suspension point between test and set, before every kernel lock?
5. **Exceptions and lifetime** — Is every C-reachable entry total? Does the error path at FFI avoid allocation? Does scheduler or domain death `_exit`? Can a cross-thread submission block on a stopped scheduler? Is exception conversion done in exactly one layer?
6. **Deadlines and pools** — Does every network call, token mint and dial have a progress-resetting deadline? Does cancellation evict the connection and unblock the actual waiter or syscall? Is there exactly one retry layer? Is the OpenSSL error queue cleared per call?
7. **FUSE and watches** — Does stop exit with an fd held open? Do kernel reads have a deadline? Is root invalidation skipped? Are scratch files outside watched trees, watches armed before read, and every wait capped by poll?
8. **Platforms** — Does the extension read any daemon-written file? Does every completion carry item or error? Are names passed as bytes? Is a foreground service held per open descriptor and stopped on `onTimeout`? Is UI-thread IPC bounded?
9. **Cloud functions** — Is undelivered work visible from the client? Are handlers idempotent, order-independent and tested under every invocation convention? Is every scoped key family domain-prefixed? Is each capability gated by one fact?
10. **OCaml semantics** — Any `Lazy` reachable from the pool? Any `pos + len` bounds check? Any effectful sibling arguments or record fields? Any outcome resting on physical equality? Any float timestamp compared for equality?
11. **Build** — Does CI fail when a driver, frontend or TLS backend is missing from the binary? Are dependency lists generated? Do caches key on pinned revisions? Is every arch and per-OS stanza built? Does ocamlformat format every file?
12. **Tests** — Does every suite assert a positive count? Was each new test seen red? Does any wait use a duration? Does any race test rely on yields instead of parallelism? Do doubles sit below the layer under test, and fixtures build only reachable states?
