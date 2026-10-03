# The http-proxy frontend (store server, share server, status page)

The generic seam (descriptor, domain wiring, launcher, stop protocol, error codes) is **[the frontend contract](../08-frontends.md)**. The wire (signing, canonical target, key encoding, endpoint grammar, framing, long-poll parameters, status codes) is owned by **[the http-proxy wire](../backends/http-proxy.md)**. Every security mechanism the server applies (authentication, confinement, share capabilities, limits, output escaping, status authorisation) is owned by **[the security model](../algorithms/security-model.md)**. This file specifies what the server does behind each endpoint.

OCaml notes: [ocaml/frontends/http-proxy.md](../ocaml/frontends/http-proxy.md).

---

## A1. Problem

One tsync host holds a domain's stores (a local disk, a NAS, a bucket it has credentials for). Other tsync clients want those stores as *their* backend without holding the credentials or reaching the storage directly. Recipients of public share links need to fetch a shared file or folder over HTTPS with no tsync installed.

The http-proxy frontend is an HTTP(S) server that does both:

- **Store server.** An authenticated, admission-bounded re-export of each served domain's *composite store*. Bytes in, bytes out. It does not present the checkout, the mirror or item references; a remote client runs its own core against it as an ordinary `http-proxy` backend.
- **Share server.** `/s/<token>…`, unauthenticated, token as credential: file download with ranges, folder browse page, folder listing JSON, per-child bytes, streamed ZIP of a folder.
- **Status page.** `/` serves a static login page that signs `/stats` requests in the browser.

It is not a presenter of files: it installs no request-handler hooks, answers no item references and keeps no view that change notices refresh.

---

## A2. Mapping onto the frontend contract

| descriptor field | value |
|---|---|
| name / CLI group | `http-proxy` / `http-proxy` |
| availability | the contract's generic chunk-store availability rule |
| serving | a daemon listening on the proxy control socket |
| tree | replicated |
| commands | none |
| option spec | §A3 |

Domain wiring used ([contract](../08-frontends.md)): each served domain's composite store, stats and diagnostics, and `peers` (the other frontends serving the same domain on this host, for the whole-domain status). File operations and the shared request handler are not used.

**Process.** One store server per host serves every domain configured with an `http-proxy` binding. It is the **store server** role of [07 §2.1](../07-daemon-cli.md#21-roles): it owns no domain's local state (no mirror, chunk cache, staged tree, WAL or journal state). Share content streams from the stores (§A9.4). Deferred work its writes owe (replica and backfill jobs the composite records) is submitted to the domain owner's inbox ([durable-queue §4.2](../algorithms/durable-queue.md#42-ownership)), and the owner is poked to take it. The server applies no journal and converges nothing; a client writing journal entries through it writes objects, which the owner's poller discovers like any peer's.

---

## A3. Configuration

Options live per domain in the domain's `frontends` array, e.g. `{"type":"http-proxy","port":8443,"secret":"…","shares":true}`. All bindings are considered together because they share one listener.

| option | type | default | scope | rule |
|---|---|---|---|---|
| `port` | int 1–65535 | 443 with TLS, else 80 | listener | at most one distinct value across bindings |
| `bind` | comma-separated addresses | all addresses with TLS, loopback without | listener | same uniqueness; plaintext on a non-loopback address only when named here ([security §9](../algorithms/security-model.md#9-tls)) |
| `max_concurrent` | int > 0 | derived (§A5) | listener | same uniqueness |
| `ssl_certificate`, `ssl_certificate_key` | paths | blank = plaintext | listener | same uniqueness; both or neither |
| limit options of [security §11](../algorithms/security-model.md#11-request-size-and-time-limits-listener) | sizes, durations, counts | as listed there | listener | same uniqueness; positive |
| `secret` | string, secret | — | per domain | required, at least `min_secret_length` characters. A binding without one inherits the value iff every binding that sets one agrees on it. |
| `shares` | bool | false | per domain | never inherited; serve `/s/` for this domain |
| `readOnly` | bool | false | per domain | never inherited |

- An empty string equals unset.
- Only `secret` inherits: a domain that sets none is either covered by the one value every other binding agrees on or refused. `shares` and `readOnly` change what the listener exposes or accepts for a domain, so they are taken from that domain's own binding alone; enabling share links for one domain never enables them for another.
- Every listener option is validated before the listener starts; a violation fails startup with a message naming the option.
- TLS is terminated in-process from PEM files, or by a reverse proxy meeting [the wire's transport rules](../backends/http-proxy.md#2-transport).
- Secrets are masked wherever options are reported ([security §10.3](../algorithms/security-model.md#103-masking)).

---

## A4. The store server

### A4.1 Routes

At start the server builds one route per served domain:

| field | source |
|---|---|
| `roots` | the domain's four roots `tsync/<d>/`, `tsync/corrupted/<d>/`, `tsync/verify-jobs/<d>/`, `tsync/gc-jobs/<d>/` ([02-remote-model](../02-remote-model.md) key layout) |
| `cursor` | the domain's cursor key |
| `secret`, `read_only` | §A3; `read_only` = the domain's own read-only flag or the `readOnly` option |
| `chunk_size` | the domain's configured chunk size, if any |
| `store` | the domain's composite store |
| `shares` | whether the route serves `/s/` |
| `peers`, `traffic` | peer sockets; per-domain byte counters |

### A4.2 Request pipeline

The order is the wire's ([§6.1](../backends/http-proxy.md#61-processing-order)). Server-side detail:

1. Share and status-page paths are dispatched first, without authentication.
2. Request line and headers are read under the header limits and timeout.
3. The operation is parsed from method, path, query and declared body length. Every key and prefix is checked against the grammar here.
4. The route is selected (§A4.3), the timestamp checked, and, for data operations, an admission slot taken (§A5) **before** the body is read.
5. The body is read within its size limit and the listener-wide body-memory reservation, then the signature is verified and every named key confined to the route.
6. The operation executes against the route's composite store (§A4.4).

A request refused at any step releases its slot and its reservation.

### A4.3 Route selection

Given the operation's first key or prefix `k`:

1. If `k` is under one route's `roots`: that route (roots are disjoint because domain names are validated).
2. If `k` is under the share space `tsync/shares/`: among the routes whose secret verifies the request, the one whose domain the share manifest names (the request body for a PUT, the stored manifest for a GET or DELETE). A cache artifact or a listing of the share space goes to the first route whose secret verifies. Share-space rules: [security §6.4](../algorithms/security-model.md#64-the-share-space-on-a-listener).
3. Else no route: answered as a failed signature.

### A4.4 Behaviour per endpoint

`B` is the route's composite store. Bytes sent and received are counted into the process totals and the route's traffic (down = sent to the client).

| op | admission | behaviour |
|---|---|---|
| get | data | `B.get_opt`; 200 with the bytes; absent → 404 |
| ranged get | data | `B.get_range`; 200 / 404 |
| watch | none | §A7 |
| head | none | `B.head_opt`; 200 with size, time, etag and checksum headers; 404 |
| put | data | writable check (§A4.5); `B.put` → 200 |
| claim | none | writable check; `held = B.put_if_absent` → 200 with `held` |
| conditional put | data | writable check; `B.put_if_unchanged` → 200 `Written` / 412 `Changed` |
| checksum | data | `B.compute_checksum`; 200 with `<algo>:<value>`; 404. It reads the whole body on this host, hence a data operation |
| delete | none | writable check; `B.delete` → 200 removed / 204 nothing there |
| get-multi | data | every key read; frames in request order |
| children-multi | data | §A8 |
| delete-multi | none | writable check (no share exemption); `B.delete_multi` → 200 |
| copy | none | writable check on `dst`; `B.copy` server-side → 200 |
| list | none | `B.list_prefix`; listing JSON with etags and checksums. On the share space, manifest keys are filtered out ([security §6.4](../algorithms/security-model.md#64-the-share-space-on-a-listener)) |
| chunk-size | none | the route's configured chunk size, else 404. Not chained through `B` |
| max-concurrency | none | the listener's bound (§A5), else 404 |
| share-url | none | route serves shares → `{"self":true}`; else `B.capabilities(prefix).share_url` → `{"url":u}`; else 404 |
| verified | none | `{"verified": B.capabilities(prefix).verified}` |

**Garbage collection.** Every manifest or version write (put, conditional put, claim, copy into those areas) passes the store driver's reference gate ([gc.md §5.4](../algorithms/gc.md#54-the-collection-interlock)): during a run it promotes the named chunks, and it refuses a write naming a chunk the main lacks with 409 `missing_chunks` listing them ([wire §6.2](../backends/http-proxy.md#62-failure-kind-header)). During a run, chunk reads (get, range, head, checksum, get-multi) are answered from either space ([gc.md §5.8](../algorithms/gc.md#58-chunk-access-is-scoped-by-the-driver)).

### A4.5 Read-only

`writable(k)` holds iff the route is not read-only, or `k` is a share manifest key (publishing or revoking a link changes no domain content). A write that fails it is 403 `read-only domain`. Reads are unaffected.

---

## A5. Admission

- One listener-wide bound of `max_concurrent` data operations (get, ranged get, get-multi, children-multi, put, conditional put, checksum) in flight, body read included. Past it, requests wait in a bounded queue; a request that finds the queue full is answered 503 `busy` at once.
- Other operations are not held behind data operations: metadata must never wait behind transfers, and a watch holds for up to 30 s by design. They are bounded by `max_connections`.
- **Bound**, derived once at start and logged with its origin: `max_concurrent` from config; else the minimum of the routes' stores' `max_concurrency` capabilities, ignoring stores with no opinion or whose query fails; else `default_max_concurrent` (16). It is published at `/max-concurrency` so clients hold their own excess.
- Share responses have their own bound (`max_share_responses`, [security §11](../algorithms/security-model.md#11-request-size-and-time-limits-listener)).

Rationale: a client opening one large file can ask for many ranges at once; unbounded reads on a USB-backed store exhausted the block layer with no throughput gain. Refusal past the queue is backpressure a client backs off from.

---

## A6. Error mapping

| situation | status | body | `x-tsync-kind` | log |
|---|---|---|---|---|
| store failure of a permanent kind | 409 | the failure's reason (for `missing_chunks`, the key list of the wire) | the kind | info |
| store failure of kind load (the backend throttles) | 503 | reason | — | info |
| store failure of another transient kind, or unexplained | 500 | reason | — | error |
| gate full, body memory exhausted | 503 | `busy` | — | — |
| read-only violation | 403 | `read-only domain` | — | — |
| bad signature, stale timestamp, unserved domain, key outside route | 401, with `Date` | `unauthorized` | — | — |
| absent object on get, range, head | 404 | empty | — | — |
| malformed call | 400 | `bad request` | — | — |
| body too large | 413 | `too large` | — | — |
| path not in the API | 404 | `not found` | — | — |

The reason text is the classifier's reason, never a generic message. Kinds are mapped per [failure-model §7.4](../algorithms/failure-model.md#74-peer-server).

---

## A7. Watch coalescing

Purpose: many clients waiting on the same cursor cost the store one watch, not one each.

**Token.** A key's watch token is its current body, trimmed of surrounding whitespace; absent object = no token. `differs(current, last_seen)`: `last_seen` absent → true iff current present; present → true iff current absent or not equal.

**Gate table.** A map from **(route, key)** to `{token?, waiters, watching, woken}`, where `woken` is a broadcast signal. Watches are only accepted on a route's cursor key, so the table holds at most one gate per served domain.

**Request** (`wait` already validated and clamped):

1. Get or create the gate.
2. Read the key's current token from the store now and store it in the gate: the gate's token may predate the client's, and holding a request through a change that already happened is the one thing a watch must not do.
3. `deadline = now + wait`, on the monotonic clock.
4. Increment `waiters`; if the gate is not `watching`, mark it and start its loop. Increment-and-start and the loop's check-and-remove MUST be mutually exclusive.
5. Repeat: if `differs(gate.token, last_seen)` → 200; else if the deadline passed → 204; else wait for `woken` or the remaining time. Both answers carry `x-tsync-watched: 1` and an empty body.
6. Always, on exit: decrement `waiters`.

**Gate loop**, one per gate, runs only while someone waits:

- If `waiters = 0`: remove the gate, clear `watching`, exit, atomically with respect to step 4.
- Else: `B.watch(key, last_seen = gate.token)` (returns when the key may have changed or after its own bounded interval), re-read the token, store it, broadcast `woken`, repeat.
- On failure: log, sleep `watch_retry` (30 s), repeat.

A gate's token is written by arriving requests and by the loop; each write is a fresh store read, so last writer wins safely, but the write MUST be atomic.

---

## A8. Bulk answers

- **children-multi**, for each prefix in request order:
  1. `B.list_prefix(prefix)`; the child objects (not the namespace key, not internal leaves) are the entries whose bodies are sent; the whole listing is sent as the folder's listing.
  2. `size` = sum of the child objects' listed sizes.
  3. `size > bulk_answer_budget` → skip this folder. Else if a folder is already taken and the running total plus `size` exceeds the budget → stop. Else take it: read the bodies and append.
  The decision is made from listed sizes before any body is read.
- **get-multi**: sizes are unknown before reading; the answer is bounded by `bulk_keys_max` and the client's packing.

---

## A9. Share server

Capability rules (token, expiry, revocation, domain confinement, manifest validation) are [security §6](../algorithms/security-model.md#6-share-capabilities). The manifest format is [02-remote-model](../02-remote-model.md).

### A9.1 Dispatch

`GET` or `HEAD` `/s/<token>[/<sub>]` (other methods → 405). `token` is the first segment after `/s/`, `sub` the rest. With one share-serving route, it handles the request. With several, each is asked in config order whether the token's manifest loads from its store **and** names its domain; the first that claims it handles the request; if none does, the first share-serving route handles it, so its refusal (bad token, not found, expired) is the answer.

### A9.2 Loading the token

1. The token MUST satisfy the token grammar ([security §6.1](../algorithms/security-model.md#61-token)), else 400 `bad token`.
2. Read `tsync/shares/<token>` from the route's store, never the mirror. Absent → 404.
3. Parse and validate per [security §6.3](../algorithms/security-model.md#63-a-share-never-leaves-its-domain): unparseable or invalid → 502 `corrupt share manifest`; another domain → 404.
4. Expiry: missing, non-numeric or past → 410 `link expired` ([security §6.2](../algorithms/security-model.md#62-lifetime)).
5. `type` = `file` (target: the manifest key) or `dir` (target: the folder id); else 502 `unknown share type`.

Refusals are `text/plain` bodies `<message>\n`. Any other failure is 500 `internal error`, logged.

### A9.3 Routes

| target | sub | answer |
|---|---|---|
| file | `""` or `download` | the file's bytes as an attachment; a symlink manifest → 400 `cannot serve a symlink directly`; no manifest → 404 |
| dir | `""` | the browse page (§A9.6) |
| dir | `download` | streamed ZIP of the folder (§A9.7) |
| dir | `list?path=` | resolve `path` inside the shared folder; a folder → `{"dirs":[names],"files":[{"name","size"}]}`, each sorted by lowercase name; anything else → 404 |
| dir | `f?path=[&dl=1][&json=1]` | resolve `path` (non-empty, else 400) to a file, else 404. `json` → `{"url":"/s/<token>/f?path=<pct-encoded>","name","contentType"(mime or null),"size"}`; otherwise the bytes, `inline` unless `dl` |
| any other | | 404 |

**Path resolution.** `path` is split on `/`, empty parts dropped; a part equal to `.` or `..` → 400 `bad path`. Parts are resolved by name from the shared folder's id through the domain's folder namespaces on the store, applying the anchor rule ([security §6.3](../algorithms/security-model.md#63-a-share-never-leaves-its-domain)), never through the local mirror (share keys live in inode space; mirroring them would plant phantom entries). Unusable entries in a namespace are skipped.

### A9.4 Reading bytes

- Content streams from the domain's composite store: a range fetches only the chunks it covers, read from the store (from either space during a collection), each checked against its chunk key. Nothing is assembled whole, and nothing is written to any local domain state.
- At most `max_share_responses` responses are open at once; beyond it a new share request is answered 503 before any header. Once headers are sent, a response is never refused mid-stream.
- A chunk that is missing or fails its key aborts the response: the connection closes without the
  chunked terminator, so the client sees an incomplete transfer, never a complete file that is
  shorter than its manifest (or than its `Content-Range`).

### A9.5 Headers and ranges

- `content-type` from the shared mime table by lowercase extension, else `application/octet-stream`. Browser-facing headers per [security §13](../algorithms/security-model.md#13-html-and-browser-facing-output), `content-disposition` included.
- `accept-ranges: bytes` on 200 and 206.
- `Range` (single range only): must start with `bytes=` and split on `-` into exactly two parts. `a-b` with `a ≤ b` → `(a, min(b, size−1))`; `a-` → `(a, size−1)`; `-n` with `n > 0` → `(max(0, size−n), size−1)`. Numbers are decimal digits only. Parsed and `a < size` → 206 with `content-range: bytes a-b/size`; parsed and `a ≥ size` → 416 with `content-range: bytes */size`; absent or unparseable → 200 whole.

### A9.6 Browse page

The browse template (shared with the cloud share function) is filled in **one pass**, with the escaping of [security §13](../algorithms/security-model.md#13-html-and-browser-facing-output):

| placeholder | value | escaping |
|---|---|---|
| `__PREVIEW_KINDS__` | JSON: extension → `image`/`audio`/`video`/`pdf`/`html`/`text` | JSON-in-HTML |
| `__PLAYER_JS__` | the embedded player script | none (constant) |
| `__OG_TITLE__` | manifest `filename` without extension | HTML text/attribute |
| `__OG_DESC__` | `Shared folder · tsync` | HTML text/attribute |
| `__SHARE_DATA__` | JSON `{"base":"/s/<token>","title":<title>}` | JSON-in-HTML |

`content-type: text/html; charset=utf-8`.

### A9.7 ZIP of a folder

- Members are computed before the response starts, up to `max_zip_members`: a depth-first walk from the shared folder, children sorted bytewise by name, directories emitted as entries, paths rooted at `filename` without its extension. Member names are the validated leaf names ([01-core](../01-core.md)); none contains `..` or a leading `/`.
- 200, `application/zip`, attachment, no content length. The archive format is [01 §13](../01-core.md#13-streaming-zip64-archives); directory entries carry mtime 0, files their manifest's mtime.
- A member whose manifest vanished since the walk is skipped and logged; a chunk that is missing or fails its key aborts the archive as above, rather than ending its member early. A failure after headers truncates the stream and is logged.

---

## A10. Status page, `/domains`, `/stats`

- **`GET /`**: the static status login page. The user types a secret; the page keeps it in memory only, signs `GET /stats[?totals=1|exact][&reload=1]` with Web Crypto, polls every 10 s while visible (a hidden tab does not poll; showing it again polls at once), and on 401 forgets it ("wrong secret, or clock off by more than 5 minutes"). Outside a secure context it refuses the secret ([security §10.4](../algorithms/security-model.md#104-in-a-browser)).
- **`/domains`, `/stats`, `/api/v1/stats`**: authorised and filtered per [security §12](../algorithms/security-model.md#12-status-and-discovery-authorisation). `totals=1` asks for a sampled estimate, `totals=exact` for a full count, `reload=1` (with totals) recounts.
- **Report content**, for the verified domains only:
  - per route, the domain's diagnostics section with this listener as a frontend entry `{"type":"http-proxy","shared":true,"reachable":true,"readOnly","shares","options"(masked),"traffic"}`;
  - for every peer socket of those routes, the peer's own frontend-only `stats` answer, each ask bounded by the status collector's deadline (a silent peer is reported unreachable);
  - a process block: `frontend:"http-proxy"`, `port`, `tls`, `serves` (the verified domains), `requests` (§A12), `bytesRead`, `bytesWritten`, their rates, and the generic process fields.

---

## A11. Control socket

The store-server socket of [07 §4.1](../07-daemon-cli.md#41-sockets), access-controlled per [security §7](../algorithms/security-model.md#7-local-ipc-access-control). Served from start until stop completes, then closed and removed.

| request | reply |
|---|---|
| `{"action":"stats","arg":"…frontend…","domain":D?}` | `{"ok":true, <process block>, "domains":[{"name","frontends":[<this listener's entry>]}]}` for route `D`, or all routes when `D` is absent or unknown. Answers for itself only, asking nobody. |
| `{"action":"stats","arg":"totals,exact,reload"?}` | `{"ok":true, …}` with the full report of §A10 over **all** routes (a same-user socket) |
| `{"action":"status"}` | the same full report as `stats` with totals arguments |
| `{"action":"ping"}` | the liveness answer of [07 §4.1](../07-daemon-cli.md#41-sockets) |
| `{"action":"stop"}` | `{"ok":true}`, then stop is requested; the connection stays open |
| unknown or empty action | `invalid` `unknown action: <a>` |
| unparseable JSON, or JSON that is not an object | `invalid` |

---

## A12. Counters

- `requests`: `inFlight`, `requestsPerSec`, `dataInFlight` (gate slots held), `dataWaiting` (gate queue length), and one integer per tally: `get getRange watch head put putIfAbsent delete getMulti childrenMulti deleteMulti copy list shareUrl chunkSize maxConcurrency verified share page stats domains unauthorized notFound badRequest tooLarge busy error`. Keys sorted.
- Byte counters are the server's own (once per request), distinct from backend link counters.
- Counters are updated atomically.

---

## A13. Lifecycle

1. Validate listener options and build routes; a violation fails startup before any socket exists.
2. Derive the admission bound (§A5).
3. Open each served domain's composite store.
4. Start the control socket; bind the listener (a bind or TLS file failure is fatal); signal ready.
5. Serve until stop is requested (signal or control `stop`; idempotent).
6. Stop accepting connections; let in-flight requests finish within the stop grace; close what remains (clients retry an unanswered request).
7. Submit any deferred work still held in memory to the owners' inboxes ([durable-queue §4.2](../algorithms/durable-queue.md#42-ownership)), bounded by the grace.
8. Close and remove the control socket.

Background loops (watch gates, share streams) log their failures; none ends the process.

---

## A14. Concurrency

Nothing a client sends chooses how much work the server does beyond the wire's caps; each status leg is deadline-bounded. Shared state that MUST be updated atomically: tallies and byte counters; the gate table (§A7 step 4 against the loop's removal); a gate's token; admission's check-and-enqueue.

---

## A15. Conformance

- Routing: domain keys go to their domain; corrupted, verify-jobs and gc-jobs keys to their owning domain; a bulk operation whose tail names another domain's key is refused whole; share-manifest writes land in the store of the domain the manifest names, and only for a secret that verifies for that domain.
- Ranged get routes, authorises and gates like get; info operations without a prefix are 400.
- children-multi routes by first prefix, confines all, gates as data; the budget rules hold; framing round-trips.
- Read-only route: put, claim, delete, delete-multi, copy → 403; get of an absent key → 404; share-manifest put 200 and delete 204 still allowed.
- Admission: never more data operations in flight than the bound, and the bound is reached; excess waits up to the queue bound; exactly the overflow beyond it is refused 503; metadata is never held; the budget is intact after a flood. The bound is the minimum of store opinions, ignoring none, else the default.
- A body over its limit is refused without being read; a client that stops sending releases its slot after the idle timeout; a stale timestamp is refused before the body is read.
- Watch: only a cursor key is watchable; `wait` is validated and clamped; a client behind is answered 200 with the header after one store read; an up-to-date one gets 204 with the header at the deadline without further reads; N waiters on one key cost N + 1 reads for one change; gates of two routes never share a loop.
- Share server: a whole file answers 200 with `content-disposition: attachment` carrying an RFC 5987 name and `accept-ranges: bytes`; `bytes=6-10` → 206 `bytes 6-10/39`; a suffix range → 206; unsatisfiable → 416 `bytes */size`; folder listing `{dirs, files:[{name,size}]}`, sub-listing, file metadata JSON, nested bytes inline, `dl=1` as attachment; a non-hex, unknown or expired token; another domain's token → 404; `..` → 400; a missing file → 404; a trashed shared folder is no longer served; the browse page renders a hostile folder name as text.
- ZIP: `download` streams an archive with no content length whose members are rooted at the folder's name (`<domain>/` for a whole-domain share), directories included; `unzip -t` accepts it and extraction is byte-exact.
- Nothing the listener does writes local domain state: serving a share, a put or a watch leaves the mirror, chunk cache, staged tree and WAL untouched; deferred work lands in the owner's inbox.
- GC: during a run, a chunk only in the space being collected is readable through the listener, and a manifest written through it naming that chunk promotes it; a manifest naming a chunk the main lacks is refused 409 `missing_chunks` with the key.
- Status: every status endpoint answers 401 unless signed; control-socket `stats` equals `/api/v1/stats` for a secret opening every domain; the text report snapshot; secrets masked; `/stats` refuses unsigned and wrong secrets and counts them; a secret opening one domain sees only that domain; totals states (not asked, counting, estimate, exact, served stale, refreshing, error); `/domains` unsigned 401, wrong 401, signed lists the domain with `readOnly`.
- Control socket: bad JSON, non-object JSON, unknown action, empty action → `invalid`; `stop` answers `{"ok":true}`, requests stop once, and leaves the connection open.

---

## A16. Rationale (do not undo)

1. **Re-export the composite store, not the checkout.** A client runs its own core; the server stays stateless apart from watch gates, and applies replicas, backfills and health transparently.
2. **Route by first key, then confine every key.** Without the all-keys check one domain's secret reaches another's objects on a shared bucket.
3. **Four roots per domain.** A route matching only `tsync/<d>/` answered every corruption listing as unserved.
4. **409 for permanent failures**: a failure waiting will not clear costs one request, not a retry ladder.
5. **One watch per cursor, dropped with its last waiter; read on arrival.**
6. **Gate data, not metadata; 503 past a bounded queue.**
7. **children-multi decided from listed sizes before reading**, so one huge folder cannot swell an answer.
8. **`chunk-size` not chained; `verified` and `max-concurrency` chained**: a chunk size is this domain's config; a claim about verification is what the store behind can back; the bound is set by the slowest participant.
9. **`share-url` answers `{"self":true}`**: behind TLS termination the server cannot know its public URL; the client knows the one it reached.
10. **Shares served from the store, not the mirror or a local cache; one predicate for "who serves shares"** for both manifest writes and `/s/` reads. The store server owns no domain state.
11. **One listener per host**: every http-proxy binding shares one port, so conflicting listener options are a startup error.
