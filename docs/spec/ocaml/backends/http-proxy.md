# Backend driver `http-proxy` — OCaml implementation notes

Companion to [../../backends/http-proxy.md](../../backends/http-proxy.md). Generic backend notes: [../06-backends.md](../06-backends.md). Security gaps of this code against the spec: [../algorithms/security-model.md](../algorithms/security-model.md).

Layout: `lib/backends/api/http_proxy.ml` (wire module, in the backend API library so client and server link the same code), `lib/backends/drivers/http_proxy/http_proxy_backend.ml` (the functor `Over (Io) (Hc) (Clock)`), `lib/lwt/backends/drivers/http_proxy/http_proxy_backend_lwt.ml` (instantiation + registration). Server: `lib/app/frontends/http_proxy/http_proxy_frontend.ml`.

## Runtime-independent

- **One wire module for both ends.** `Http_proxy.{Auth, Watch, Wire}` holds the header names, the canonical string, the long-poll parameter names and the 30 s cap, the key encoding and both framings. Client and server never spell these themselves. Keep it transport-free: plain functions over strings and bigstrings.
- **The canonical target is `Uri.path_and_query`, on both ends.** The client signs `Uri.path_and_query uri` of the URI it sends; the server recomputes `Uri.path_and_query (Cohttp.Request.uri req)`, which re-encodes the parsed query with ocaml-uri's `Query_key`/`Query_value` safe sets and upper-case hex. That is the byte-exact rule of spec §3.2. ocaml-uri also splits a value on literal `,` and rejoins it with `,`, which is why a raw `,` happens to verify too. `Uri.add_query_param'` **prepends**, so the watch URI is `?last_seen=…&wait=30`.
- **`Uri.with_path base_uri "/…"` replaces the whole path**: the code drops a base path in `url` (spec §1 requires keeping it and signing the API path only).
- **Body hash over the bigstring** (`Digestif.SHA256.digest_bigstring`): a chunk body is never materialised as a string to be signed.
- **Timestamp** is `Printf.sprintf "%.0f" (Unix.time ())`, which rounds; the JS and Kotlin signers floor. The verifier parses with `float_of_string_opt`, so it accepts forms (`1.7e9`) the spec now refuses.
- **`Wire.decode_key`** is base64 with `~pad:false` and the URI-safe alphabet; the result is taken with `Stored_key.listed`, which validates nothing at the snapshot.
- **Frame decoders raise `Failure`** on a malformed answer and bound each length by the bytes remaining. `Failure` is not `Retry.Failed`, so `Backend.classify` calls it transient, where the spec says CORRUPT.
- **Bulk answers are built in pieces** (`body_parts`, `folder_parts`); concatenations of them are exactly `bodies_to_string` / `children_to_string`. The server streams the pieces; the client decodes one string.
- **Client decode copies three times** (bigstring → string → per-body `String.sub` + `Bigstring.of_string`), ~24 MiB transient for an 8 MiB answer. Decoding off the bigstring with `Bigstring.sub` views removes two copies.
- **Watch tokens are abstract** (`Backend.Watch_token.t`, trimmed body): `to_wire` / `of_wire` / `equal`.
- **`put_if_absent` returns a fresh buffer**, so the counting wrapper's physical-equality test (`held != data`) always sees a loss. The naming layer judges the claim by parsing the marker.
- **Capability parsing**: `ask` maps 404 and any JSON exception to the default; `positive` accepts only `` `Int n `` with `n > 0`.
- **Registration** is a side effect of linking `tsync_http_proxy_backend_lwt`, kept by `(library_flags (-linkall))`.
- **Test seams**: the HTTP client is a functor argument (`Hc : Http_client.S`), used by `tests/backends/proxy_watch_client`; `tests/backends/proxy_permanent` uses a raw socket to count requests.

## Gaps at the spec snapshot

- `delete_multi` is not paged; empty bulk lists are sent (400); `get_many` has no fallback on 404; `list_many`'s sticky 404 flag does not distinguish an unserved domain.
- No first-use binding or claim probe: an unserved domain reads as an empty store on `get_opt`, `get_range`, `head_opt`, `delete`; `put_if_absent` against a server older than `if_absent` overwrites the winner and reads its empty answer as a win.
- 403 surfaces as a generic permanent `HTTP 403`, not `Backend.Not_writable`.
- HEAD carries no etag; 409 carries no kind header.
- Watch goes through the full retry ladder before its failure is swallowed, and swallows cancellation too.
- The capability memo is not keyed by prefix.

## Lwt / functor-specific

- **`( and* )` is built on `Io.join`** with two `ref` cells, so the four capability requests start together. Under OCaml 5: `Eio.Fiber.all`.
- **Capability memo** (`caps_cache : Backend.caps Io.t option`): the promise is stored before anything awaits, so concurrent callers share it; `Io.catch` clears the slot on failure. This relies on no preemption between the match and the assignment; with domains it needs a mutex or a resettable once-cell.
- **`no_list_many`** is a plain mutable bool; under domains an `Atomic.t` suffices.
- **Stall timeout** is `Clock.with_stall_timeout` inside `Http_client.call`, pinged per received piece by the pool. It does not cover the upload. Under Eio: a timeout restarted per chunk, or a watchdog fiber reading a last-progress timestamp.
- **Retry ladder** is `Retry.Make(Io)(Clock).with_retry`; its sleep is `Shutdown.Sleep`, so a stop interrupts a backoff.
- **Watch floor** is `Clock.sleep Backend.default_watch_interval` (2 s).
- **Request bodies** go to cohttp as `Body.of_bigstring (`Passthrough body)`: the buffer must stay valid until the request, retries included, is answered.
- **TLS library** is conduit's global `tls_library` ref, set once by `Tls_conf`; no per-instance TLS config, hence no `ca_certificate` yet. OpenSSL preferred; ocaml-tls selectable.

## Resource strategy (not normative)

- One connection pool per driver instance, at most 32 parallel connections per endpoint, idle connections kept 60 s; a pooled connection found dead before the request left is redialled once, on a fresh pool shared by every request that raced into the dead one.
- Request bodies are sent from the caller's buffer without a copy; an answer is held whole before it is interpreted.
- `get_many` callers pack runs to ≤ 256 keys and ≤ 8 MiB of listed sizes before the driver sees them.

## When each capability appeared in this code base

Core (2026-07-24); `/chunk-size` 07-27; `/max-concurrency` and 503 `busy` 08-01; `if_absent` 08-07; `/domains` 08-09; `/verified` 08-14; `/get-multi`, bulk confinement, listing `etag` 08-21; watch parameters 08-26; range parameters 08-29; `/children-multi` 09-03; 204 on DELETE 09-06; 409 for permanent failures 09-17. The claim probe of spec §8.1 relies on `/verified` postdating `if_absent`.
