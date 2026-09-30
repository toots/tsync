# Backend driver `http-proxy` — OCaml implementation notes

Companion to [../../backends/http-proxy.md](../../backends/http-proxy.md). Generic backend notes: [../06-backends.md](../06-backends.md).

Layout: `lib/backends/api/http_proxy.ml` (wire module, in the backend API library so client and server link the same code), `lib/backends/drivers/http_proxy/http_proxy_backend.ml` (the functor `Over (Io) (Hc) (Clock)`), `lib/lwt/backends/drivers/http_proxy/http_proxy_backend_lwt.ml` (instantiation + registration).

## Runtime-independent

- **One wire module for both ends.** `Http_proxy.{Auth, Watch, Wire}` holds the header names, the canonical string, the long-poll parameter names and the 30 s cap, the key encoding and both framings. Client and server never spell any of these themselves, which is what keeps them from drifting. Keep it transport-free (no cohttp): it is plain functions over strings and bigstrings.
- **The canonical target is `Uri.path_and_query`, on both ends.** The client signs `Uri.path_and_query uri` of the URI it sends; the server recomputes `Uri.path_and_query (Cohttp.Request.uri req)`, which re-encodes the parsed query with ocaml-uri's `Query_key`/`Query_value` safe sets and upper-case hex. The two agree because both are ocaml-uri. A client in another language must reproduce that encoder (spec §3.2); a server in another language must re-encode the same way to accept OCaml clients. `Uri.add_query_param'` **prepends**, so the watch URI is `?last_seen=…&wait=30`, not the order the code reads in.
- **`Uri.with_path base_uri "/…"` replaces the whole path**, which is why a configured URL with a path component loses it (spec §13.6).
- **Body hash over the bigstring** (`Digestif.SHA256.digest_bigstring`): a chunk body is never materialised as a string to be signed. The server reads the request body with `Cohttp_lwt.Body.to_bigstring` before routing, so it hashes the same bytes.
- **Timestamp** is `Printf.sprintf "%.0f" (Unix.time ())`, which rounds rather than truncates; the JS and Kotlin signers floor. Irrelevant inside a 300 s window. The verifier parses with `float_of_string_opt`, so it accepts forms (`1.7e9`, hex floats) no client sends; `nan`/`inf` fail the skew check.
- **Constant-time compare** with `Eqaf.equal` after a length check.
- **`Wire.decode_key`** is base64 with `~pad:false` and the URI-safe alphabet; the result is taken with `Stored_key.listed`, the one constructor for a key a peer reported.
- **Frame decoders raise `Failure`** on any malformed answer, and bound each length by the bytes remaining (32-bit overflow otherwise, generic notes). `Failure` is not `Retry.Failed`, so `Backend.classify` calls it transient: a server sending garbage is retried by queue callers, not refused.
- **Bulk answers are built in pieces** (`body_parts`, `folder_parts`) and concatenations of them are exactly `bodies_to_string` / `children_to_string`. The server streams the pieces so bodies are held once; the client decodes the whole answer from one string.
- **Client decode copies three times**: the pool collects the response as a bigstring, `Bigstring.to_string` copies it to the heap, then each body is `String.sub` + `Bigstring.of_string`. For an 8 MiB bulk answer that is ~24 MiB transiently. Decoding straight off the bigstring with `Bigstring.sub` views would remove two copies.
- **Watch tokens are abstract** (`Backend.Watch_token.t`, trimmed body). The driver sends `to_wire`; the server rebuilds with `of_wire` and compares with `equal`, never as strings, so an entry key or etag cannot be passed where a token is expected.
- **`put_if_absent` returns a fresh buffer**, so the counting wrapper's physical-equality test (`held != data`) always sees a loss and counts the answer as downloaded. The naming layer judges the claim by parsing the marker, so correctness does not depend on identity through this driver.
- **Capability parsing is lenient by design**: `ask` maps 404 and any JSON parse exception to the default, and `positive` accepts only `` `Int n `` with `n > 0` (a float `4.0` is no opinion).
- **Registration** is a side effect of linking `tsync_http_proxy_backend_lwt`, kept by `(library_flags (-linkall))`. Required fields are read with `req`, raising `Failure "http-proxy backend: missing field: <f>"`.
- **Test double seam**: the HTTP client is a functor argument (`Hc : Http_client.S`), which is how `tests/backends/proxy_watch_client` asserts the exact query the driver builds without a socket. `tests/backends/proxy_permanent` instead uses a raw socket to count requests.

## Lwt / functor-specific

- **`( and* )` is built on `Io.join`** with two `ref` cells, so the four capability requests start together and neither result is read before both land. Under OCaml 5 this is `Eio.Fiber.pair` (or `Fiber.all` over four).
- **Capability memo** (`caps_cache : Backend.caps Io.t option`): the promise is stored *before* anything awaits, so concurrent callers share it; `Io.catch` clears the slot on failure. This relies on no preemption between the `match t.caps_cache` and the assignment. With domains or preemptive fibers it needs a `Mutex` around check-and-set, or an `Eio.Lazy`/once cell that is reset on failure. One subtlety preserved from Lwt: if the promise has already failed when stored, the handler runs immediately and clears it, which is the desired outcome.
- **`no_list_many`** is a plain mutable bool, set on the first 404. A race only costs an extra 404, so under domains an `Atomic.t` suffices.
- **Stall timeout** is `Clock.with_stall_timeout` inside `Http_client.call`, with `alive` pinged per received piece by the pool (`Http_client_lwt.Pool`). Under Eio: `Eio.Time.with_timeout` restarted per chunk read, or a watchdog fiber reading a last-progress timestamp.
- **Retry ladder** is `Retry.Make(Io)(Clock).with_retry` (in `Http_client.call_retry`); its backoff sleep is `Shutdown.Sleep`, so a stop interrupts a backoff with `Shutdown.Stopping`. Direct-style port: same loop, sleep through a cancellable clock.
- **Watch** swallows every exception with `Io.catch (fun _ -> Io.return None)`, including cancellation. Under Eio, catching `Eio.Cancel.Cancelled` must re-raise; a direct-style port must not swallow it.
- **Watch floor** is `Clock.sleep Backend.default_watch_interval` (2 s); the functor's `Clock` makes it testable with a real clock only (the test asserts ≥ 1 s).
- **Request bodies** go to cohttp as `Body.of_bigstring (`Passthrough body)`: the buffer must stay valid and unmodified until the request, retries included, is answered.
- **TLS library** is conduit's global `tls_library` ref, set once by `Tls_conf` at startup; the driver has no per-instance TLS config. OpenSSL is preferred; ocaml-tls stays selectable. Both verify against system CAs.
- **Server side, for the wire only**: the frontend is Lwt-only (`Cohttp_lwt_unix.Server`, `Lwt_condition` + `Lwt.pick` for the long poll, `Lwt_stream` for streamed bulk answers). Its race-free gate removal relies on cooperative scheduling; see [../frontends](../08-frontends.md) and the frontend spec.
