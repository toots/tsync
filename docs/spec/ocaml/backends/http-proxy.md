# Backend driver `http-proxy` — OCaml implementation notes

Companion to [../../backends/http-proxy.md](../../backends/http-proxy.md). Generic backend notes: [../06-backends.md](../06-backends.md). The server behind the endpoints: [../frontends/http-proxy.md](../frontends/http-proxy.md).

Code: `lib/store/http_proxy/proxy_wire.ml` (the wire, linked by both ends), `lib/store/http_proxy/http_proxy_client.ml` (the client driver), over `Tsync_http.Client`. The server is `lib/frontends/http_proxy/store_server.ml`.

## Map

| Spec | Code |
|---|---|
| Fields (§1) | `fields` in `http_proxy_client.ml`: `url` (`Field_spec.http_url`), `secret` (`Field_spec.secret_length`), `ca_certificate` (`Field_spec.absolute_path`) |
| Base path (§1) | `Client.endpoint` keeps the URL's path and prefixes every target with it; `request` signs the API target it builds, before that prefix |
| Stall timeout (§2) | `stall_timeout` (300 s), passed as `~stall` to `Client.request` |
| Signing (§3.1) | `Proxy_wire.signature`, `Proxy_wire.sign` (timestamp from the wall clock, floored) |
| Canonical query (§3.2) | `Proxy_wire.canonical_query` (client), `Proxy_wire.parse_query` (server) |
| Verification (§3.3) | `Proxy_wire.fresh`, `Proxy_wire.verify` (`Eqaf.equal`); `Proxy_wire.max_clock_skew` |
| Key encoding (§4.1) | `Proxy_wire.encode_key`, `decode_key` (through `Key.of_string`) |
| Listing JSON (§4.2) | `Proxy_wire.listing_to_json`, `listing_of_json` |
| Frames (§4.3) | `Proxy_wire.encode_bodies`, `decode_bodies ~count`, `encode_folders`, `decode_folders ~asked` |
| Bulk limits (§5.2) | `Proxy_wire.bulk_keys_max`, `bulk_folders_max`, `bulk_answer_budget` |
| Client status mapping (§6.3) | `failure`, with `Fail.of_wire_kind` for `x-tsync-kind` and the `missing_chunks` body parsed into `Fail.Missing_chunks`; `skewed` |
| Watch (§7) | `watch`; `watch_floor`; `Proxy_wire.watch_max` |
| Binding (§8.1) | `ensure_served`, memo `served` |
| Claim support (§8.1) | `claims_supported`, memo `claims`, set when `capabilities` hears `/verified` |
| Checksum and conditional-replace support (§8.1) | `checksums_supported`, memo `checksums` |
| Operations (§8.2) | the record built in `create`; `call` (bind, ladder, transient statuses raised), `expect` |
| Paging and fallbacks (§8.3) | `pages`, `get_many`, `list_many`, `delete_multi`; memos `no_get_many`, `no_list_many` |
| Capabilities (§8.4) | `capabilities`: `Rt.map_concurrently` over the four paths inside one ladder, kept per prefix in `caps` |
| Retry and health (§9) | `ladder` (`Retry.ladder ~health`) |
| Registration | the top-level `Driver.register "http-proxy"` |

## Departures

- **A 401 on the binding request is not memoised.** Only a 404 with a body sets `served = Some false`; a 401 raises `Denied` and the next operation asks again, since it may be this clock's skew (finding 27, listed there as a spec gap in §8.1).
- **Binding is sequential and lazy.** `ensure_served` runs before each operation until it has an answer; claim support is learned from the first `capabilities`, not concurrently with the binding.
- **The capability memo is not shared by concurrent first callers.** Each sends its four requests and adds its answer to `caps`; later callers read the first entry for the prefix.
- **`get_range` with a length of 0 fails INVALID** in `Store.checked`, as 06 §3.2 has it, where §8.2 answers empty.
- **A zero-length body is sent without admission** (`request`).

## Learnings

- **One wire module for both ends.** Header names, the canonical string, the limits and both framings live in `Proxy_wire`, a library of plain functions over strings and bigstrings; `store_server.ml` and the driver spell none of it themselves, and `tests/store/proxy_wire_test` reproduces the §3.4 vectors against it.
- **The query is escaped by hand** (`escape` with the two allowed sets), so the bytes signed are the bytes sent. No URI library re-serialises the query (pitfall B-2.15).
- **The body hash reads the bigstring** (`Digestif.SHA256.digest_bigstring`): a chunk is never copied to the heap to be signed.
- **Frames decode into views.** `decode_bodies` and `decode_folders` return `Bigstring.sub` slices of the answer, and every length is compared with the bytes remaining, never with `pos + n`.
- **A considered answer never climbs the ladder.** `call` raises inside the ladder only for 429 and 5xx; every other status is returned and judged by the verb, so a 409 costs one request.
- **Memos are `Atomic`, set only by an answer.** A failed ask raises before the `Atomic.set`, so nothing is remembered from a failure (pitfall A-4.2). A 2xx capability answer that is not JSON fails CORRUPT and is not kept: a captive portal's page is not "no claim support".
- **`skewed` reads the 401's `Date`.** A 401 off by more than the window is raised as LINK with a clock-skew reason, after the ladder returned it: the caller's own retry redoes the operation, and nothing is remembered as an unserved domain.
- **An empty 404 is ABSENT, a 404 with a body is not.** `empty_404` is the test on every object read; HEAD has no body, so `head_opt` relies on `ensure_served` having run.
- **A claim's answer is judged by bytes**: `Won` when the answer equals the body sent, `Held` otherwise, CORRUPT when it is empty.
- **Watch feeds health itself.** It runs outside the ladder, so it calls `Health.answered` on a watched answer and `Health.lost` on a LINK failure; every failure but a stop or a cancellation ends in `Stop.sleep watch_floor`.
- **TLS implementation and trust.** `ca_certificate` goes to `Client.endpoint ?ca_file`; the implementation is the process-wide `Transport.tls_impl`.
- **Tests.** `tests/store/proxy_test` runs the contract through a real `store_server` and covers the skewed 401, a server without `/checksum`, a captive portal and watch; its watch case passes at the polling floor, so broken long-polling stays green (finding 103).
