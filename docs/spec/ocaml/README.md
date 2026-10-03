# OCaml implementation notes

These notes describe the OCaml implementation of tsync: how it maps onto the spec, where it
departs from it, and what it learned. They are descriptive, not normative; the spec is in the
parent directory, and each note names the spec concept it implements.

The code is direct style on OCaml 5: fibers on the vendored `duppy` scheduler, run by a pool of
domains (`lib/core/rt.ml`). It has its own HTTP client and server (`lib/http`) over OpenSSL or
ocaml-tls, store drivers that register themselves (`lib/store`), bigstring bodies, and a typed
request protocol between a domain's owner and its clients (`lib/owner/protocol.ml`). Every module
has an `.mli` whose doc comments are the first thing to read.

Each note gives a map from spec concept to module and function, the departures the code has from
the spec, and what the code learned. A known pitfall is cited by its ID in
[`../../pitfalls/`](../../pitfalls/README.md) (`A-7.9`) instead of being retold; a departure that
is an open finding of [the review](../../review/2026-10-01-rewrite.md) is cited by its number.

| Subsystem | Notes |
|---|---|
| Foundation: names, hashing, the runtime, retry, breaker, stop | [01-core.md](01-core.md) |
| Remote data model | [02-remote-model.md](02-remote-model.md) |
| Journal & sync | [03-journal-sync.md](03-journal-sync.md) |
| Checkout & cache | [04-checkout-cache.md](04-checkout-cache.md) |
| Config & whole-domain ops | [05-ops-config.md](05-ops-config.md) |
| Backends | [06-backends.md](06-backends.md) |
| Daemon & CLI | [07-daemon-cli.md](07-daemon-cli.md) |
| Frontends (FUSE binding, KIO plugin via shared object) | [08-frontends.md](08-frontends.md) |
| Test harness mechanics and dune traps | [09-tests.md](09-tests.md) |
| Bodies, mapping and memory, with measurements | [memory.md](memory.md) |
| Backend drivers | [local](backends/local.md), [s3 and object-store common](backends/s3.md), [gcs](backends/gcs.md), [http-proxy](backends/http-proxy.md) |
| FUSE (libfuse binding, KIO plugin via shared object) | [frontends/fuse.md](frontends/fuse.md) |
| http-proxy server | [frontends/http-proxy.md](frontends/http-proxy.md) |
| macOS (the File Provider host) | [frontends/file-provider.md](frontends/file-provider.md) |
| Android (cross-compilation, JNI, embedding the runtime) | [frontends/android.md](frontends/android.md) |
| Backend and local data models | [data-model/backend.md](data-model/backend.md), [data-model/local-cache.md](data-model/local-cache.md) |
| Algorithms: how the code maps onto each, and where it departs | [wal-and-journal](algorithms/wal-and-journal.md), [conflict-resolution](algorithms/conflict-resolution.md), [durable-queue](algorithms/durable-queue.md), [failure-model](algorithms/failure-model.md), [replication](algorithms/replication.md), [read-path-and-cache](algorithms/read-path-and-cache.md), [gc](algorithms/gc.md), [uplink-governor](algorithms/uplink-governor.md), [security-model](algorithms/security-model.md) |

## The lessons that matter most

1. **Nothing is atomic between two statements.** Fibers resume on any domain, so every shared
   table, counter and flag is behind a `Mutex` or an `Atomic`; confinement to one thread does not
   exist. A `Lazy.t` forced from two domains raises, so none is reachable from the pool. (A-2.1,
   B-10.1, [01 §C.2](01-core.md))
2. **Bound fan-outs by construction.** `Rt.all` and `Rt.map_concurrently` start a fiber per
   element; a list sized by the data goes through `Rt.map_bounded` or `Rt.each`, whose workers pull.
   Take a semaphore slot before the resource it guards, and never wait for a slot of a semaphore
   already held. (C-1.1, C-2.1, A-2.7)
3. **A system `Mutex` never spans a wait, and nothing is called under it.** A fiber that suspends
   may resume on another system thread, which cannot unlock it. `Mutex.protect` covers a few
   statements; a hold that waits is an `Rt.Fmutex`; callbacks and wake-ups run after the unlock.
   ([01 §C.5](01-core.md))
4. **A C stub that can block releases the runtime lock.** One that blocks holding it stalls every
   domain at the next stop-the-world section. An `` `Immediate `` or `` `Direct `` region runs on a
   pool worker and contains no blocking call at all. (B-3.2, [01 §C.3](01-core.md))
5. **An exception escaping into C kills the host process.** Everything reachable from JNI or a
   shared object must be total: `Android_bridge` wraps each entry it registers. (B-5.4,
   [frontends/android.md](frontends/android.md))
6. **dune can report success having done nothing.** A plain `dune build` compiles no test: the
   root `dune` file builds `bin`, `lib`, `vendor` and the benchmarks, and tests build and run under
   `@runtest`. A cached test action is replayed, not run; `--force` runs it. (B-12.1, B-12.3,
   [09](09-tests.md))
7. **Bound a prefetch by position, not only by concurrency.** A semaphore on fetches in flight lets
   every finished listing wait in memory: a large domain's rebuild peaked near 1.8 GB that way.
   Measure with private memory split into anonymous, file-backed and OCaml heap before guessing.
   (C-1.2, [memory.md](memory.md))
8. **An action owed on every path is a `Fun.protect ~finally`, not a copy per branch.** Closing a
   descriptor, releasing a slot or a hold, unlocking: written once in `finally`, it also runs when
   the body raises, which a copy at the end of each branch does not, and a later branch cannot
   forget it. Keep in the body only what runs on success (handing a record to its queue). A
   resource handed to the caller on success but owed back on failure (a descriptor opened then
   locked, a slot passed to a response) is a `match … with exception e -> release; raise e` around
   every step after its acquisition, not a release on one failure branch; `Fs.or_close` is that
   shape for a descriptor.
9. **A cancelled wait cleans up after itself.** It withdraws what it registered, a race waits for
   the losers it cancelled before its caller closes anything they use, and a hand-off skips a
   waiter that left. (`Rt.suspend`, `Rt.first`; [01 §C.5](01-core.md))
10. **Self-registration needs `-linkall`.** Drivers, frontends and TLS implementations register in
    a top-level `let ()`; a library without the flag links, and its name is unknown at run time.
    (B-11.1)
11. **Fork before the first domain, or not at all.** A process with a second domain cannot fork, so
    `Rt` starts its pool at first use, never at module initialisation. (B-4.4)
