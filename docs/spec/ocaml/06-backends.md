# 06 — Backends — OCaml implementation notes

Companion to the language-neutral spec [../06-backends.md](../06-backends.md). See [README.md](README.md) for how these notes are organised. Driver notes: [local](backends/local.md), [s3 and the object-store shell](backends/s3.md), [gcs](backends/gcs.md), [http-proxy](backends/http-proxy.md). Composite and copies: [algorithms/replication.md](algorithms/replication.md). Uplink: [algorithms/uplink-governor.md](algorithms/uplink-governor.md).

## B.0 Where the spec lives in the code

| Spec | Code |
|---|---|
| Store contract | `Backend_intf.S` (`lib/backends/api/backend_intf.ml`); every driver and the composite are `(module Store)` values |
| Keys | `Stored_key.t` (`lib/core/stored_key.ml`), abstract, built by a namer (`in_space ~prefix path`) or taken from a listing (`listed`); `is_dir_key` for names ending in `/` |
| Entry, caps | `Backend.file_entry`, `Backend.caps`, `no_caps`, `merge_caps` |
| Watch token | `Watch_token.of_body` (trimmed body), `to_wire`/`of_wire`, `equal` |
| Failure classification | `Backend.classify` (`Not_writable`, `Backend_error` → Permanent; else `Retry.classify`); `Retry.Failed {kind; op; detail}`; `Http_client.failed` |
| Range check | `Backend.checked_range` (`Backend_error "…asked for N bytes, got M"`) |
| Absent codes in bulk answers | `Backend.absent_code` (`NoSuchKey`, `NotFound`) |
| Batched reads | `Batched.get_many` (`max_batch_keys = 256`, `max_batch_bytes = 8 MiB`, default pool of 32 named "batch reads"); `max_batch_folders = 64` shared with the http-proxy wire |
| Drain hooks | `Backend.on_drain` / `drain` |
| Registry | `Backend.register ~spec name factory`, `spec_for`, `types`, `make ?traffic ?admission ~backend_type ~get_field ()`; `Failure "unknown backend type: …"` |
| Admission and traffic | `Backend.counted` wraps every store whose `local_path = None`: `put`/`put_if_absent` through the admission (`acquire` before, `completed`/`abandoned` after), bytes added to `Metrics` and the store's `traffic` pair |
| Member record | `Backend.member` (`name; role; readable; backend_type; config; backend; pending/in_flight/degraded; traffic; local_path; link`), `Backend.main`, `Backend.deferred`, `named_exn` |
| Uplink config | `Conf_parsing.uplink_of_json`, `link_settings`; `Uplink.configure` (first writer wins) |

## B.0.1 Where the current code differs from the spec

- **Invalid keys are not refused at the store.** `Stored_key.listed` is the identity, and the local driver joins keys onto its root without normalising `..` (findings S3, reproduced through the http-proxy). The spec's grammar check at every store operation, and the local driver's confinement, are the fix.
- **Directory markers.** The local driver creates a directory for a `put` of a key ending in `/`, lists empty directories as `…/` keys, and `delete` of such a key runs `rm -rf`. Mirror copies listed `…/` keys to other stores as zero-byte objects. The spec makes these names invalid: omitted from listings, never written.
- **Claims return the buffer itself** on a win, and the counting wrapper tells winner from loser by physical inequality (`held != data`). A lost-reply retry answered 412 returns an equal but distinct buffer, which is counted as a loss. The spec's explicit `Won | Held` result, with byte-identical holders reported as `Won`, replaces it.
- **`get_range` at or past the end** fails 416 → Permanent on S3 and GCS; only the local driver returns empty.
- **`delete_multi` per-key refusals** are raised as `Transient` whatever the code; the spec maps them per code (LOAD or REFUSED), never as link evidence.
- **`list_prefix ~max_keys`** is a stop signal: the result may exceed `max_keys` by up to one page, and is in service order (local sorts). The spec returns exactly the first `n` in key order.
- **Admission is per call, not per attempt.** `counted` wraps `put` and `put_if_absent` only, around the whole ladder: retries are not re-admitted, `elapsed` includes backoff sleeps, and the `get`+`put` inside the object-store `copy`, verify and discard job PUTs go through the driver directly, neither counted nor gated.
- **`try_admit` then `acquire`** is two calls, atomic only because nothing yields between them under Lwt (the deferred forward spawns a task that runs synchronously up to `acquire`). The spec's `try_acquire` takes in one step.
- **Checksums and conditional replace.** Entries carry no `checksum`; GCS reports its `etag` rather than its `generation`; no store has `put_if_unchanged`, `compute_checksum` or `locality`, the local driver reports no etag, and the http-proxy wire has no `/checksum`, `if_match` or `if_none_match`.
- **Capabilities.** `verified = true` and `discard = Queued` are literals in the object-store shell; nothing checks the bucket function is deployed.
- **Local health** is `Health.always_up`; the spec gives local stores a cell fed by link-kind errnos and stalls.
- **Unrecognised exceptions are Transient** in `Retry.classify`, and count against health; the spec splits LOAD from LINK and keeps UNEXPLAINED out of the breaker.
- **`Uplink.capped` and `Uplink.compose`** (per-store budgets) survive only for `tests/unit/backend_capped`; production uses one link per ceiling.

## B.0.2 How each host builds stores today

| Host | `resume` | Deferred queues | Uplink role |
|---|---|---|---|
| Daemon parent (`tsync start`, launcher) | true | built stopped; `Deferred.start_resumed ()` after the frontends are forked; the IPC `rescan` action rescans when a child records | owner: `own()` before engines start; answers `{"action":"uplink"}` |
| Forked frontend children (FUSE, http-proxy server) | true, inherited, stopped | never run; `accept` records and calls `set_on_recorded` → IPC `rescan` to the parent | leased from the parent's sync socket |
| One-shot CLI commands | false | started at once; run only their own records (`Durable_queue.claim`); `drain ()` settles before exit | leased if a daemon answers, else local, retrying every 30 s |
| Android app (`android_jni.ml`) | false | started at once; never recovers a previous run's log (findings G7) | local |

The spec's single owner per domain (P1) replaces the record-only children and the per-log claim.

## B.0.3 Resource choices (not normative, P6)

- Default batch-read pool: one process-wide semaphore of 32 ("batch reads"); callers should pass their own. A run takes its slot once; the composite forwards native batches directly to its member rather than through `Batched`, since taking a second slot of the caller's pool deadlocks.
- Object-store `verify_all`: 4096 PUTs with 32 in flight (spawned all at once today; a worker-pull loop over the shard list bounds live tasks too).
- Shared HTTP client: ≤ 32 sockets per endpoint, idle 60 s; s3's library pool keeps ≤ 32 idle, reaped after 20 s (`AWS_S3_POOL_MAX_IDLE_S`).

## B.1 Runtime-independent OCaml learnings

- **Abstract key type with no `of_string`** (`Stored_key.t`) and an abstract `Watch_token.t`: the type system stops a raw string, an entry key or an etag from being passed where a stored key or token is expected (a watch comparing the wrong spelling once held requests it should have answered). Keep them abstract; add the grammar check in the constructors.
- **First-class modules as the store value** (`(module Store)`): the composite and every driver are values of one module type, so the composite is itself a store and members sit in lists. A record of closures would do equally well; what matters is one interface type for leaf and composite.
- **Optional capabilities as `option` fields of functions** (`get_many`, `list_many`): the absence is in the type, and the generic fallback is written once.
- **Admission as a record of closures**, not a functor argument: a store built once takes whichever gate the configuration names.
- **Bigstring bodies, never strings**: chunk bodies stay off the OCaml heap end to end (s3 `put_bigstring`/`get_bigstring`, the proxy's `` `Passthrough `` bodies, `digest_bigstring` for SHA-256). A body handed to a request must stay valid until it is answered, retries included.
- **Mapped bodies fault, they do not fail**: local reads use `Bigstring.map_file` (mmap), which the spec recommends (P6: store files are never modified in place). The cost is that `EIO` on a failing disk or `ESTALE` on NFS arrives as SIGBUS at page touch — inside hashing or a socket write — not as an exception. Positioned reads into a `Bigstringaf` buffer are the allowed alternative where that matters (a network mount).
- **mmap past EOF is SIGBUS, not a short read**: `get_range` clamps `len` to `size − offset` before mapping.
- **`Printexc.register_printer`** is needed for exceptions that reach users: the default printer spells the wrapped-library module path (`Tsync_backend_api.Backend.Not_writable`).
- **32-bit overflow in frame decoding**: lengths are compared against the bytes remaining (`n > len - pos`) rather than `pos + n > len`.
- **Dune layout**: the API library (`tsync_backend_api`) sees only core/io/uplink; drivers are separate libraries opened with `-open`; the s3 driver is `(optional)` and selected with `(select s3_link.ml from (tsync_s3_backend_lwt -> s3_link.enabled.ml) (-> s3_link.disabled.ml))`. Drivers register from their initialiser and are kept in the link by `(library_flags (-linkall))`: without it an unused driver module is dropped and its registration never runs, silently. Test the registry's `types ()`.
- **Crypto without an RNG**: GCS JWT signing uses `Mirage_crypto_pk.Rsa.PKCS1.sign ~mask:`No`.
- **Local walk memory**: a promise per directory entry kept the whole tree alive (≈100 MB of closures for 500k manifests); a fixed number of workers pulling from a shared list fixed it. Under direct style the same applies to fibers.
- **The uplink modules are pure OCaml with a `now` argument**, testable without any scheduler; the stall timeout is a global `ref` (`Uplink_budget.stall_timeout`) read by the GCS driver so window and deadline cannot drift.

## B.2 Lwt / functor-specific learnings

- **Functor-over-concurrency-signature pattern**: every module is `Over (Io : Io.S) (Bounded) (Clock) (Lock) (Durable_queue) (Http_client) …`, applied once in `lib/lwt/backends` (`Backend.Make (Io_lwt.Core) (Io_lwt.Bounded)`, `Domain_store.Over (…)`, each driver's `*_lwt.ml`). It kept Lwt out of every library below the app and let tests use fakes; it cost a mirror tree `lib/lwt/...`, application boilerplate and sharing constraints (`with type 'a io := 'a Io.t`; `S3io : Aws_s3.Types.Io with type 'a Deferred.t = 'a Io.t`). Under OCaml 5 direct style the functors collapse to plain modules; keep the clock and filesystem seams for tests.
- **Process-global registries force a single application**: `Backend.Make` holds the registry, drain hooks and batch pool; applying it twice would create two registries. Same for `Domain_store`'s `hooked` flag and `Deferred`'s `resumed_starts`. With domains they need `Atomic`/`Mutex`.
- **Cooperative atomicity is load-bearing** (spec §8). Code between binds is atomic; `Lwt.async f` runs `f` synchronously until its first bind. With several domains every item of spec §8 is a data race until given a lock or an atomic try-take.
- **`let*` marks every yield point**; the absence of a bind documents "no interleaving here". Direct style loses that marker: encapsulate those critical sections.
- **Pool nesting deadlock**: a caller holding a slot of pool P must not take a second slot of P (the composite forwards native batches directly; the local walk holds its slot around the `stat` only).
- **Bounded fan-out**: `Bounded.map_with slots f list` rather than `Lwt_list.map_p`; `Io.iter_p` only where the width is fixed by code.
- **Cancellation**: `Clock.pick`/`with_timeout` cancel the losing branch (`Health_wait.until_held`); the retry loop must not retry a cancellation, and a probe cancelled by its deadline tells the health cell nothing, hence `Health.probe_lost`.
- **`Lwt.async` exceptions**: frontends set `Lwt.async_exception_hook` to log; chunk forwards and watch loops catch everything themselves.
- **Wake order**: gates use `Io.wakeup_later` so a woken waiter does not run inside `pump` while the queue is iterated.
- **Fork discipline**: stores and resumable queues are built before the daemon forks its frontends; queues start in the parent afterwards. Under OCaml 5, `Unix.fork` is refused once a second domain exists — fork before spawning domains, or run frontends inside the owner as the spec's P1 asks.
