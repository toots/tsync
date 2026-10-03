# 06 — Backends — OCaml implementation notes

Companion to the language-neutral spec [../06-backends.md](../06-backends.md). See [README.md](README.md) for how these notes are organised. Driver notes: [local](backends/local.md), [s3 and the object-store shell](backends/s3.md), [gcs](backends/gcs.md), [http-proxy](backends/http-proxy.md). Composite and copies: [algorithms/replication.md](algorithms/replication.md). Uplink: [algorithms/uplink-governor.md](algorithms/uplink-governor.md). Bodies and mappings: [memory.md](memory.md).

## Map

| Spec | Code |
|---|---|
| Store contract (§3) | `Store.t` in `lib/store/store.ml`: a record of closures, one per operation, plus `name`, `health` and `traffic`. Every driver and `Composite.store` produce one. |
| Keys and prefixes (§2.1) | `Tsync_core.Key.t` and `Key.prefix`, valid by construction (`Key.of_string`); a listed name enters through `Store.listed`, which skips an invalid one with a warning logged once. |
| Entry, caps (§2.2, §2.3) | `Store.entry`, `Store.caps`, `Store.no_caps` |
| Watch token (§2.4) | `Store.token` (the trimmed body, a `string option`); `Store.watch_interval` |
| Checksums (§2.5, §3.12) | `Checksum.t` (private record), `Checksum.of_body`, `md5_of_hex`, `md5_of_base64`, `comparable`; `Store.locality` |
| Outcomes and kinds (§3.1) | `Tsync_core.Fail.kind`, carried by `Fail.E`; `Fail.classify` for any other exception; `Fail.retryable` |
| Claim, conditional replace (§3.3, §3.11) | `Store.claim` (`Won \| Held of Bigstring.t`), `Store.replaced` (`Written \| Changed`) |
| Checks every driver shares | `Store.checked`: INVALID for a bad range or an unknown checksum algorithm, REFUSED for a conditional replace against an entry without an etag, no request for an empty bulk list |
| `get` (ABSENT on a miss) | `Store.get` over `get_opt` |
| Optional operations (§3.8) | `get_many` and `list_many` are `option` fields; `bucket_functions` a `bool` |
| Composite and member list (§4) | `Composite.t`, `Composite.store`, `Composite.member`, `Composite.members`, `in_read_order`, `copy_stats`; the member's config record is `Config.backend`, paired in `Domain.t.members` |
| Batched reads (§5) | `Store.read_many`; `Store.max_batch_keys` (256), `max_batch_bytes` (8 MiB), `max_batch_folders` (64) |
| Driver registry (§5) | `Driver.register`, `Driver.find`, `Driver.names` over `Tsync_core.Registry`; a driver is `{ fields; linkless; create }` |
| Settling background work (§5) | `Composite.settle` |
| Retry ladder and breaker | `Retry.ladder ~health ~op`, `Retry.until_held`; `Tsync_core.Health` |
| Admission seam (§6) | `Uplink.t`, handed to `Driver.create` as `~admission`; `Uplink.admitted t mode bytes f` wraps one attempt; `Uplink.none` for a linkless store |
| Write modes (§6) | `Store.mode` (`Wait \| Best_effort`), the optional argument of `put` |
| Traffic counters (§6) | `Store.traffic` (two `int Atomic.t`), `Store.count_up`, `count_down` |
| Uplink configuration (§7) | `Config.link`, `Config.link_settings`, `Config.uplink_settings`; `Uplink.link name settings` (first settings named win); `Uplink.attach` registers the store's probe and health |
| Governor roles | `Uplink.own` (the supervisor), `Uplink.lease` (every other process), `Uplink.renewal`; `Uplink_law` and `Uplink_lease` are pure |
| Bucket function confirmation (§3.8) | `Bucket_function` (the saved confirmation and the single probe in flight), `Composite.probe`, `Composite.function_confirmed`, `Composite.queue_verification`; `Discards` is a copy's log of pending discard requests |
| Presence memo of a copy | `Copy_memo` |

## Departures

- **Admission wraps the attempt in each driver, not in one wrapper.** `Object_store.make` and `Http_proxy_client.request` call `Uplink.admitted` inside `Retry.ladder`, so a retry is admitted again. The http-proxy driver sends a zero-length body without admission.
- **`verified` of an object store is decided in the composite.** The shell answers `verified = false`; `Composite.store`'s `capabilities` adds `confirmed`, the owner's saved probe outcome. A caller that asks a leaf store directly sees `false`.
- **A driver absent from the build is refused when the config is parsed**, not when it is used: see [05](05-ops-config.md).

## Learnings

- **A record of closures as the store.** The composite is a store, members sit in lists, and a derived store is a record update (`Store.checked`, `Domain.reading_from`). The cost: `{ s with … }` compiles when a field is added to `Store.t`, so a wrapper that must cover every read or every write has to be re-read by hand on each addition.
- **Keys valid by construction remove the per-operation check.** `Store.checked` validates ranges and algorithms only; the grammar check of §2.1 is `Key.of_string` at every boundary where a string becomes a key (`Store.listed`, `Proxy_wire.decode_key`, the config).
- **Registration is a side effect of linking** (pitfall B-11.1). Each driver library has `(library_flags (-linkall))` and a top-level `Driver.register`; `tsync_catalog` names the libraries so every binary links them. `tsync build-info` prints `Driver.names ()`, and the config test's snapshot lists them.
- **`Registry` has no lock**: it is filled at module initialisation, before any fiber runs, and only read afterwards. Registering later is a data race across domains.
- **Fibers run on several domains.** Per-store state is `Atomic` (`Store.traffic`, the proxy driver's memos, the S3 claim checks) or under a `Mutex` (`Bucket_function`, the local driver's watchers and key locks). A `lazy` value forced from two domains raises; none is left on these paths.
- **The single probe is a promise, not a lock held across the request.** `Bucket_function.probe` takes its mutex only to install or find the `Rt.Promise`; the check runs outside it, and a failure to save the confirmation still clears `probing` and resolves the waiters.
- **The uplink law and the lease split take `now` as an argument** (`Uplink_law`, `Uplink_lease`, `Uplink.Budget`), so `tests/unit/uplink_law_test`, `uplink_test` and `uplink_modes_test` run without a scheduler or a clock.
- **A stall is data on the failure.** `Client.request` raises LINK with `stalled = true`; `Retry.ladder` tallies it on the member's `Health` (`Health.timed_out`), which is what the governor cuts its rate on.
- **Tests.** `tests/store/contract.ml` is the contract, run by `local_test`, `s3_test`, `gcs_test`, `proxy_test`, `composite_test` and `spaces_test` against their stores; `copy_memo_test`, `watch_test` and `proxy_wire_test` cover the rest of `lib/store`. The S3 and GCS suites reach a real bucket only when their `TSYNC_CI_*` variables are set, which `tests/store/dune` declares as `(env_var …)` dependencies so a run against the fake is never replayed as a real one. The S3 signature check in `s3_test` verifies with the driver's own canonicaliser (finding 159).
