# The http-proxy frontend (store server, share server, status page)

Scope: `lib/app/frontends/http_proxy/` (`http_proxy_frontend.ml`, `share_server.ml`, `stats.html`), its registration stub `lib/app/frontends/frontend_http_proxy.ml`, and the server half of `lib/backends/api/http_proxy.ml{,i}` (`Auth`, `Watch`, `Wire`).

The generic seam (descriptor, domain wiring, launcher, stop protocol, error codes) is **[the frontend contract](../08-frontends.md)** and is only referenced here. The wire protocol — HMAC canonical string, replay window, key encoding, endpoint grammar, framing, long-poll parameters, status codes as a client reads them — is owned by **[the http-proxy wire](../backends/http-proxy.md)**. This file specifies what the *server* must do behind each endpoint. The share manifest format is owned by the share subsystem (summary in [the frontend contract](../08-frontends.md) §A2.9).

---

## A1. Problem

One tsync host holds a domain's stores (a local disk, a NAS, a bucket it has credentials for). Other tsync clients want those stores as *their* backend without holding the credentials or reaching the storage directly. Separately, recipients of public share links need to fetch a shared file or folder over plain HTTP(S) with no tsync installed.

The http-proxy frontend is an HTTP(S) server that does both:

- **Store server.** A thin, authenticated, admission-bounded re-export of each served domain's *composite store* (the domain's members merged into one `Store`, which resolves read order, replicas, deferred backfill/archive targets and health internally). Bytes in, bytes out. It does not present the checkout, the mirror or item references; a remote client runs its own full core against this server as an ordinary `http-proxy` backend.
- **Share server.** `/s/<token>…`, unauthenticated, token-as-credential: file download with ranges, folder browse page, folder listing JSON, per-child bytes, and a streamed ZIP of a folder.
- **Status page.** `/` serves a static login page that signs `/stats` requests in the browser with the shared secret.

It is **not** a presenter of files in the contract's sense: it installs no request-handler hooks, answers no item references, and keeps no view that change notices could refresh.

## A2. How it maps onto the frontend contract

| descriptor field | value |
|---|---|
| name / CLI group | `http-proxy` / `http-proxy` |
| availability | chunk-store availability (the contract's generic rule): a proxy host may be the process keeping that domain's chunk cache warm, so `tsync ls` asks the same question as anywhere else |
| serving | `Daemon { topology = One_process, listens = ProxySocket, start }` |
| tree | `Replicated` |
| commands | none |
| option spec | §A3 |

What it uses of the **domain wiring** ([contract](../08-frontends.md) §A3.1):

| wiring piece | used? | for |
|---|---|---|
| file operations | **no** | the store server speaks keys, not paths; the share server reads the store directly (§A9) |
| shared request handler / hooks | **no** | its control socket has its own tiny handler (§A11) |
| `start()` | yes | start each domain's upload and metadata queues (idle here, but the domain is "started" for diagnostics and drain) |
| `drain()` | yes | at stop: drain backends, so deferred writes (backfill/replica targets) the composite owes on behalf of proxy clients are not dropped |
| stats/diagnostics | yes | per-domain section of the status report |
| `peers` | yes | the other frontends serving the same domain on this host, for a whole-domain status (§A10) |

**No journal, no convergence of its own.** The server applies nothing: journal replay, reconcile and maintenance run once per host in the launcher parent. A client writing journal entries through the proxy writes objects; the parent's poller on *this* host sees them like any foreign entry. The only store-level state the server keeps is its watch gates (§A7) and counters.

**Process shape.** The launcher forks one child for the whole `http-proxy` group: **one process, one listener, all http-proxy-configured domains of the host**. Like every forked frontend child it inherits the stores built before the fork (stopped, `resume = true`), leases uplink bandwidth from the parent, and routes "replica job recorded" to the parent as a `rescan`. Its store-side identity is that of a *lessee*.

## A3. Configuration

Options live per domain in `config.json` under the domain's `frontends` array, e.g. `{"type":"http-proxy","port":8443,"secret":"…","shares":true}`. Non-string values are stringified by the config parser. All bindings of the group are considered together, because they share one listener.

| option (JSON) | type | default | scope | rule |
|---|---|---|---|---|
| `port` | int | 443 with TLS, else 80 | listener | at most one distinct non-empty value across all bindings, else startup fails `http-proxy: conflicting port across domains sharing a port` |
| `max_concurrent` | int > 0 | derived (§A5) | listener | same uniqueness; non-positive or non-integer → `http-proxy: max_concurrent must be a positive integer` |
| `ssl_certificate` | path | blank = plain HTTP | listener | same uniqueness |
| `ssl_certificate_key` | path | blank | listener | same uniqueness; exactly one of cert/key set → `http-proxy: ssl_certificate and ssl_certificate_key must both be set` |
| `secret` | string (secret) | — | per domain | required; a binding without one inherits the value iff all bindings that set it agree on a single value, else startup fails `http-proxy: missing secret for domain <d>` |
| `shares` | bool | false | per domain | same inheritance rule; serve `/s/` for this domain |
| `readOnly` | bool | false | per domain | same inheritance rule; serve-side write ban (§A4.4) |

- **Empty string equals unset** everywhere (so a form that writes `""` for "default" is correct).
- **Listener-scoped values are validated before the event loop starts**, so a bad config fails the child at once.
- **TLS** is terminated in-process from PEM files (no password), or delegated to a reverse proxy by leaving both blank. The server never learns its public URL (see `share-url`, §A4.3).
- **One port per host** follows from the rules above: two domains cannot be served on two ports by one tsync install.
- Secrets are masked `***` wherever options are reported (status JSON/text, `tsync config`), using the option spec's secret flag.

## A4. The store server

### A4.1 Routes

At start the server builds one **route** per served domain:

| field | source |
|---|---|
| `roots` | the domain's four key roots from the layout: `tsync/<d>/`, `tsync/corrupted/<d>/`, `tsync/verify-jobs/<d>/`, `tsync/gc-jobs/<d>/` ([backends](../06-backends.md) chunk layout) |
| `shares_prefix` | `tsync/shares/` (domain-independent) |
| `secret`, `read_only` | §A3; `read_only` = domain's own read-only flag **or** the `readOnly` option |
| `chunk_size` | the domain config's chunk size, if configured |
| `store` | the domain's composite store |
| `share_server` | present iff `shares` |
| `peers` | from the launcher |
| `traffic` | per-domain up/down counters, client's point of view |

### A4.2 Request pipeline

For every request, in order:

1. **Share path.** Path starts with `/s/` **and** at least one route has shares → share server (§A9). No HMAC, no admission gate. Otherwise `/s/…` continues as an ordinary (unknown → 404) path.
2. **Read the whole request body** into memory (needed for the body hash in the signature).
3. **Fixed paths** (`GET` only): `/` and `/index.html` → status page (§A10); `/domains`, `/stats`, `/api/v1/stats` → §A10. Any other method on these paths falls through to 4 and ends as 404.
4. **Parse the op** from method + path + query + body (grammar owned by [the wire](../backends/http-proxy.md)). Outcomes: a well-formed op, `Bad` (ours but malformed: undecodable key, missing parameter, bulk body not a JSON array or over its cap, range present but invalid), or `Unknown` (not part of the API).
5. **Route key** = the op's **first** named key or prefix. `Unknown` → **404** `not found`; `Bad` (no key) → **400** `bad request`.
6. **Pick the route** (§A4.3). None → **404** `unknown domain`.
7. **Authenticate** against the chosen route's secret ([wire](../backends/http-proxy.md) HMAC rule: signature over method, path+query, timestamp, body hash; ±300 s). Missing header or mismatch → **401** `unauthorized`.
8. **Confine**: every key/prefix the op names must be `within` the route — starts with one of its `roots` or with `shares_prefix`. Any outside → **401** `keys outside the domain this request is for`. Refused whole, never narrowed.
9. **Admission** (§A5) for data ops; overflow → **503** `busy`.
10. **Execute** against the route's composite store (§A4.4); exceptions mapped per §A6.

The per-outcome tallies (§A12) are bumped at steps 5, 7, 8, 9, 10; `unknown domain` is not tallied.

### A4.3 Route selection

Given the route key `k` and the predicate `authed(route)`:

1. The first route (config order) one of whose `roots` prefixes `k`.
2. Else, if `k` starts with some route's `shares_prefix` (a share manifest key, which names no domain):
   - if any route serves shares: the first **share-serving** route whose secret authenticates the request. A holder of only a non-sharing domain's secret gets no route (404), because a manifest written anywhere else would never be read back by `/s/`.
   - otherwise: the first route whose secret authenticates. Nothing on this listener reads the manifest back; the store's own share URL does.
3. Else none.

The same "which routes serve shares" predicate governs both where manifests are *written* (here) and where `/s/` *reads* them (§A9.1).

### A4.4 What the server does behind each endpoint

`B` is the route's composite store. "Sent"/"received" bump both the process byte counters and the route's traffic (down = sent to client, up = received from client).

| op | data kind | server behaviour |
|---|---|---|
| **get** `GET /o/<k>` | Get | `B.get_opt k`; present → 200 with the bytes streamed from the store's buffer without a copy; absent → 404 empty |
| **ranged get** `GET /o/<k>?offset&length` | Get | only when both parse as integers with `offset ≥ 0` and `length > 0`; `B.get_range`; 200 bytes / 404. Either parameter present but invalid → 400, never widened to a whole get |
| **watch** `GET /o/<k>?wait=…` | Meta | §A7. `wait` present and parseable as float selects watch over get (a range with `wait` is a watch) |
| **head** `HEAD /o/<k>` | Meta | `B.head_opt`; 200 with `x-tsync-size` (decimal) and `x-tsync-last-modified` (`%f` seconds); 404 absent. The etag is not carried |
| **put** `PUT /o/<k>` | Put | if not writable(k) → 403 `read-only domain`; else `B.put k body` → 200 empty |
| **claim** `PUT /o/<k>?if_absent=true` | **Meta** | if not writable(k) → 403; else `held = B.put_if_absent k body` → 200 with `held` (the body that won, the caller's or the earlier one). Bool parsing of `if_absent` accepts the config bool spellings |
| **delete** `DELETE /o/<k>` | Meta | if not writable(k) → 403; `B.delete` → 200 if something was removed, **204** if nothing was there |
| **get-multi** `POST /get-multi` | Get | body: JSON array of ≤ 1024 strings (non-strings silently dropped); read all through the batch layer with the shared *batch reads* pool (§A5); answer bodies framed per the wire, in request order, streamed item by item |
| **children-multi** `POST /children-multi` | Get | body: JSON array of ≤ `max_batch_folders` (64) prefixes; §A8 |
| **delete-multi** `POST /delete-multi` | Meta | ≤ 1024 keys; route read-only → 403 (no share-prefix exemption); `B.delete_multi` → 200 |
| **copy** `POST /copy?src&dst` | Meta | route read-only → 403; `B.copy` server-side → 200. Both keys are confined |
| **list** `GET /list?mode=all&prefix[&max_keys]` | Meta | `B.list_prefix`; listing JSON (etag passed through when the store names one). `mode` other than `all` → 400 |
| **chunk-size** `GET /chunk-size?prefix` | Meta | the route's configured chunk size → `{"chunkSize":n}`; unconfigured → 404. **Not** chained through `B` |
| **max-concurrency** `GET /max-concurrency?prefix` | Meta | the listener's effective bound (§A5) → `{"maxConcurrency":n}`; 404 if not yet set. Chained in effect: the bound was derived from `B`'s own capability, so a proxy fronting a proxy inherits the furthest-down limit |
| **share-url** `GET /share-url?prefix` | Meta | this route serves shares → `{"self":true}` (client composes `<its base URL>/s`); else `B.capabilities(prefix).share_url` → `{"url":u}`; else 404 |
| **verified** `GET /verified?prefix` | Meta | `{"verified": B.capabilities(prefix).verified}`, chained through the store so a proxy fronting an unchecked bucket cannot claim a clean domain |

`writable(k)` = `not route.read_only` **or** `k` is under `shares_prefix`: publishing or revoking a share link changes no domain content, so a read-only domain can still share. Every endpoint that takes `prefix` confines it like a key (step 8), so an info query for another domain's prefix is 401.

## A5. Admission (bounded concurrency, 503)

- **Gate.** One listener-wide pool of `max_concurrent` slots with a waiter queue of at most `16 × max_concurrent`. Data kinds `Get` (get, ranged get, get-multi, children-multi) and `Put` (put) take a slot for the whole execution. A request that finds the queue full is answered **503 `busy`** at once and consumes no slot. Everything else (head, watch, claim, delete, delete-multi, copy, list, info) bypasses the gate.
- **Batch reads pool.** A second pool of the same size, shared by all requests, no waiter limit, through which get-multi and children-multi issue their object reads. Separate from the gate because a request already holding a gate slot must not wait for another slot from the same pool (deadlock).
- **Bound derivation**, once at start, logged with its origin:
  1. `max_concurrent` from config;
  2. else the merged capabilities of all routes' stores, asked **sequentially** with `prefix = ""`: the **minimum** of the stores' `max_concurrency`, stores with no opinion (or whose capability query fails) ignored;
  3. else **16**.
- **Why:** one client opening one large file can ask for many ranges at once; on a USB-backed store unbounded reads exhausted block-layer queue tags with ~96 threads waiting and no throughput gain. Refusal past the queue is backpressure a client retries with backoff; an unbounded queue is a growing list of promises whose callers time out silently. Metadata must never wait behind transfers, and a watch holds for up to 30 s by design.
- **Published**: the bound is served at `max-concurrency` so a client holds its own excess rather than parking it in this server's queue.
- Share traffic has its own separate bound (§A9.4) and is **not** gated here.

## A6. Error mapping

| situation | status | body | log |
|---|---|---|---|
| exception classified **permanent** by the backend failure classifier (e.g. source of a copy/rename gone, not-writable) | **409** | the failure's reason text | info |
| any other exception | **500** | reason text | error |
| gate overflow | 503 | `busy` | — |
| read-only violation | 403 | `read-only domain` | — |
| bad signature / keys outside route | 401 | `unauthorized` / `keys outside the domain this request is for` | — |
| no route | 404 | `unknown domain` | — |
| absent object on get/range/head | 404 | empty | — |
| malformed call to the API | 400 | `bad request` | — |
| path not in the API | 404 | `not found` | — |

Rationale: a 5xx is what the client's retry ladder climbs; a failure that waiting will not clear (a rename whose source the store no longer holds) cost 8 round trips and 8 error lines per occurrence before 409 existed. The client settles a 409 in one pass and surfaces the reason. The reason text is the only channel for the cause and must be the classifier's reason string, not a generic message.

## A7. Watch coalescing (long poll)

Purpose: many clients waiting on the same key (typically a domain's published cursor object) cost the store **one** watch, not one each. Without it a proxy costs its store exactly what the clients would.

**Token.** A key's watch token is its current body, trimmed of surrounding whitespace; absent object = no token. `differs(current, last_seen)`: `last_seen` absent → true iff current present; present → true iff current absent or not equal.

**Gate table.** Process-wide map from key string to `{token?, waiters: int, watching: bool, woken: broadcast signal}`. Created on first request for a key.

**Request** (`wait` already clamped to `≤ 30 s`, [wire](../backends/http-proxy.md) `Watch.max_seconds`):
1. Get or create the gate.
2. **Read the key's current token from the store now** and store it into the gate. The gate's token may predate the client's; holding a request through a change that already happened is the one thing a watch must not do.
3. `deadline = now + wait`.
4. `waiters += 1`; if the gate is not `watching`, mark it and spawn its loop. Steps 4's increment and spawn must be atomic with respect to the loop's removal check (below).
5. Loop: if `differs(gate.token, last_seen)` → **200**, empty body, header `x-tsync-watched: 1`. Else if `deadline` passed → **204** with the same header. Else wait for `woken` or the remaining time, then repeat.
6. Always (finally): `waiters -= 1`.

**Gate loop** (one per gate, runs only while someone waits):
- If `waiters = 0`: remove the gate from the table, clear `watching`, exit. Removal happens with no suspension between the check and the removal; this is what keeps a concurrent arrival from attaching to a dying gate.
- Else: `B.watch(key, last_seen = gate.token)` (the store returns when the key may have changed, or after its own bounded interval; waking early is allowed), re-read the token, store it, broadcast `woken`, repeat.
- On exception: log error, sleep 30 s, repeat. The store's own pacing plus this sleep keeps a dead backend from spinning the loop.

**Properties** (test-pinned): a hold takes no admission slot; the watch is still authenticated and confined to its key; a client behind is answered at once with the header after exactly one store read; an up-to-date client is held to the deadline and the store is not re-read while held beyond the loop's watch; N waiters on one key cost N + 1 reads (one per arrival, one per change). Gates are dropped with their last waiter, so the table's size is bounded by concurrently waited keys, not by every key ever asked.

**Old-client/old-server interplay** is the wire's: an old server ignores `wait` and answers without the header, which the client uses to pace itself.

## A8. Bulk answers and streaming

- **Budget.** `max_batch_bytes` = 8 MiB of bodies per bulk answer.
- **children-multi**: for each prefix in request order:
  1. `B.list_prefix(prefix)`; keep only child objects (not directory keys, not internal markers) — those are the entries whose bodies are sent; the full listing is still sent as the folder's listing JSON.
  2. `size` = sum of the kept entries' listed sizes.
  3. `size > budget` → **skip** this folder, continue with the next (the client fetches it by the key-packed route). Else if at least one folder is already taken and `bytes + size > budget` → **stop** (the rest are omitted). Else **take**: read the bodies through the batch reads pool and append.
  The decision is made from listed sizes, **before** any body is read. The answer is self-describing (it carries each folder's prefix), since it may cover a subset.
- **get-multi**: the bodies are read with sizes unknown (entries carry size 0), so its size is bounded by the 1024-key cap; clients pack to their own byte budget.
- **Streaming**: both bulk answers go out as a stream of frame pieces, one body or one folder at a time; the bodies are held once, in the store's buffers, and never concatenated into a second full copy. Byte counters are bumped per piece as it is produced. Single-object gets are handed to the HTTP layer without a copy.
- A 90 MB folder answered whole, framed through a growing buffer plus a final copy, killed a 400 MB host; hence skip-before-read and piecewise output.

## A9. Share server

### A9.1 Dispatch and domain selection

`/s/<token>[/<sub>]`: `token` is the first path segment after `/s/`, `sub` everything after the next `/` (may contain further `/`, which then matches no route → 404). Query parameters come from the URL; `Range` from the header.

A token names no domain; its manifest does. With exactly one share-serving route, that route handles it. With several, each is asked in config order whether the token's manifest loads **and** names its domain (any load failure counts as "no"); the first that claims it handles the request; if none claims it, the first share-serving route handles it (its refusal — bad token, not found, expired — is the right answer).

### A9.2 Loading the token (per route)

1. Token must be non-empty lowercase hex `[0-9a-f]+`, else **400** `bad token`.
2. Read `<shares_prefix><token>` from the route's store (the backend, never the mirror). Absent → **404**.
3. Parse JSON; failure → **502** `corrupt share manifest`.
4. `expires` (int or float epoch seconds; missing = 0): `now > expires` → **410** `link expired`.
5. `domain` empty → **502**; `type` = `file` (target: manifest key `key`) or `dir` (target: `folderId`), else **502** `unknown share type`.
6. `domain ≠` this route's domain → **404** (its keys and folder ids would resolve in the wrong namespace).

Refusals are `text/plain` bodies `<message>\n` with the status above. Any other exception → 500 `internal error`, logged.

### A9.3 Routes

| target | sub | answer |
|---|---|---|
| file | `""` or `download` | the file's bytes as an attachment (§A9.5), name and size from its manifest; a symlink manifest → 400 `cannot serve a symlink directly`; no manifest → 404 |
| dir | `""` | the embedded browse page (§A9.6) |
| dir | `download` | streamed ZIP of the folder (§A9.7), named by the manifest's `filename` |
| dir | `list?path=` | resolve `path` inside the shared folder; a folder → `{"dirs":[names],"files":[{"name","size"}]}`, each sorted by lowercase name, sizes as JSON integers; anything else → 404 |
| dir | `f?path=[&dl=1][&json=1]` | resolve `path` (must be non-empty, else 400 `not a file`) to a file, else 404. `json` → `{"url":"/s/<token>/f?path=<pct-encoded>","name","contentType"(mime or null),"size"}`; otherwise bytes, `inline` unless `dl` |
| any other | | 404 |

**File target confinement.** The manifest's `key` is fetched only if it starts with the route's domain manifest prefix (`tsync/<d>/manifests/`); anything else is treated as absent (404). A share can therefore never expose another domain's file even if a signed client wrote a crafted manifest.

**Path resolution.** `path` is split on `/`, empty parts dropped; any part equal to `.` or `..` → **400** `bad path`. The parts are resolved by name from the shared folder's id through the store's folder namespaces (inode tree: each folder id's namespace holds its children's manifests and folder markers), never through the local mirror. Share keys live in inode space; mirroring them would plant phantom entries in the domain's listings. Unusable entries in a namespace are skipped.

### A9.4 Reading bytes

- Content is read through the domain's chunk-cache data path: a byte range fetches only the chunks it covers (fetch-on-miss into the chunk cache); nothing is assembled into a whole file and nothing is written to the manifest mirror.
- Blocks of **256 KiB**. Each block first takes one of **16 process-wide share read slots** (shared across domains, separate from the store gate so a burst of downloads cannot starve replica writes), **then** allocates its buffer. This ordering is what bounds memory.
- The slot queue has **no waiter limit**: headers (status, content-length) are already sent when a block is pulled, so a refusal would read as a corrupt file, not backpressure.
- A short read (0 bytes) ends the stream early.
- File manifests are memoised per key; the memo is cleared entirely when it reaches 256 entries (a 30k-chunk file's manifest is ~2.5 MB, not worth re-reading per range request).
- Bytes served are counted into a share counter included in the listener's `bytesRead`.

### A9.5 Headers and ranges

- `content-type`: shared mime table by lowercase extension (after the last `.`), else `application/octet-stream`.
- `content-disposition: <inline|attachment>; filename="<ascii>"; filename*=UTF-8''<percent-encoded>` where `<ascii>` replaces bytes < 32, > 126 and `"` with `_`.
- `accept-ranges: bytes` on 200/206.
- `Range` parsing (single range only):
  - Must start with `bytes=`; the rest must split on `-` into exactly two parts (so multi-range `a-b,c-d` does not parse).
  - `a-b` with `a ≤ b` → `(a, min(b, size−1))`; `a-` → `(a, size−1)`; `-n` with `n > 0` → `(max(0, size−n), size−1)`. Anything else does not parse.
  - Parsed and `a < size` → **206**, `content-length = b−a+1`, `content-range: bytes a-b/size`.
  - Parsed and `a ≥ size` (including any range on an empty file) → **416**, `content-range: bytes */size`, empty body.
  - Not present or unparseable → **200** whole, `content-length = size`.

### A9.6 Browse page

The embedded `browse.html` (the same file the cloud share function serves) with placeholders replaced textually:

| placeholder | value |
|---|---|
| `__PREVIEW_KINDS__` | JSON object extension → `image`/`audio`/`video`/`pdf`/`html`/`text`, derived from the mime table's base type |
| `__PLAYER_JS__` | embedded `player.js` |
| `__OG_TITLE__` | manifest `filename` without extension, HTML-escaped (`& < > "`) |
| `__OG_DESC__` | `Shared folder · tsync`, escaped |
| `__SHARE_DATA__` | JSON `{"base":"/s/<token>","title":<title>}` |

`content-type: text/html; charset=utf-8`.

### A9.7 ZIP of a folder

- Members are computed **before** the response starts: a depth-first walk from the shared folder, children sorted by name (bytewise), directories emitted as entries (so empty ones survive), paths rooted at `filename` without its extension.
- Response: 200, `content-type: application/zip`, attachment disposition with `filename`, chunked (length unknown).
- The archive is ZIP64, STORED (no compression), every member followed by a data descriptor (CRC and sizes are known only after the bytes), one 256 KiB block in memory at a time; directory entries carry mtime 0, file entries the manifest's mtime.
- A member whose manifest has vanished since the walk is skipped (logged); a short read closes the member early.
- Any failure after headers only truncates the stream; it is logged with the member or file id.

## A10. Status page, `/domains`, `/stats`

- **`GET /` / `/index.html`**: unauthenticated static page. The user types the shared secret; it is kept in the browser's session storage and never sent. The page signs `GET /stats[?totals=1|exact][&reload=1]` with the wire's HMAC (Web Crypto when available, else a built-in SHA-256/HMAC that must first reproduce RFC 4231 test case 2 or refuse to sign, because plain-HTTP LAN origins have no Web Crypto), polls every 5 s, and on 401 forgets the secret ("wrong secret, or clock off by more than 5 minutes").
- **`GET /domains`**: the secret selects: `{"domains":[{"name","readOnly"}]}` for exactly the routes whose secret verifies the request; none → 401. Used by setup forms before a client has a config.
- **`GET /stats`** (text) and **`GET /api/v1/stats`** (JSON): listener-wide, authorised by **any** route's secret. Query: `totals=1` (sampled estimate) or `totals=exact` (full count), `reload=1` (only with totals) re-counts. Both render the **same** collected report.
- **Report content**:
  - per route: the domain's diagnostics section, with this listener as a frontend entry `{"type":"http-proxy","shared":true,"reachable":true,"readOnly","shares","options"(masked),"traffic"}`;
  - plus, for every `peer` socket of every route, that frontend's own answer to `stats` with the `frontend` flag, merged by the status-report collector (each ask bounded by the collector's cold deadline; a silent peer is reported unreachable, not waited on);
  - a process block: `frontend:"http-proxy"`, `port`, `tls`, `serves` (domain names), `requests` (§A12), `bytesRead` (store + share bytes), `bytesWritten`, and their per-second rates, plus the generic process fields.
- A domain served only by this listener has an empty peer list and costs no round trip.

## A11. Control socket

Unix socket at `<data_dir>/tsync-http-proxy.sock` (same name on Linux and macOS), newline-delimited JSON as in [the contract](../08-frontends.md) §A2.6. Served from after the domains have started until the drain completes, then closed and removed.

| request | reply |
|---|---|
| `{"action":"stats","arg":"…frontend…","domain":D?}` (arg is a comma set containing `frontend`) | `{"ok":true, <process block>, "domains":[{"name","frontends":[<this listener's entry with traffic>]}]}` for the routes named `D`; unknown or absent `D` → all routes. Answers for itself only, asking nobody, so a collector fanning out over every frontend costs frontends, not frontends² |
| `{"action":"stats","arg":"totals,exact,reload"?}` | `{"ok":true, …}` + the full report of §A10 (same collection as `/api/v1/stats`) |
| `{"action":"changed",…}` | `{"ok":true}`, ignored: a proxy client re-asks the store on every request, there is no view to refresh. Answering keeps the parent's change fan-out frontend-agnostic |
| `{"action":"stop"}` | `{"ok":true}` first, then request stop. The connection is not closed by the reply |
| other action / empty action | `{"ok":false,"code":"invalid","error":"unknown action: <a>"}` |
| unparseable JSON | `invalid` `invalid JSON` |
| valid JSON that is not an object | `internal` `expected JSON object` |

Error replies use the contract's code vocabulary.

## A12. Counters

- `requests` object: `inFlight` (non-share store requests executing), `requestsPerSec`, `dataInFlight` (gate slots held), `dataWaiting` (gate queue length), and one integer per tally name: op names `get getRange watch head put putIfAbsent delete getMulti childrenMulti deleteMulti copy list shareUrl chunkSize maxConcurrency verified`, plus `share`, `page`, `stats`, `domains`, `unauthorized`, `notFound`, `badRequest`, `busy`, `error`. Keys sorted. `dataWaiting > 0` means storage is the limit; `busy` climbing means the queue overflows.
- Byte counters are the server's own (once per request), distinct from backend link counters (once per link a write reaches).

## A13. Lifecycle

1. Install an async-exception logger (background loops log, never kill the process).
2. Validate listener options; build routes (fails on missing secret).
3. Enter the domain engine's loop:
   1. SIGTERM / SIGINT / control `stop` → request stop (idempotent): set the process shutdown flag, resolve the stop promise.
   2. Derive and install the admission bound (§A5).
   3. Start each domain's queues, sequentially.
   4. Start the control socket.
   5. Signal ready.
   6. Serve HTTP(S) until stop resolves (stops accepting).
   7. `drain_for_stop` all domains (contract §A3.4: parallel, raced against the grace; what remains resumes at next start).
   8. Close and remove the control socket.

A listener bind failure or TLS file error is fatal to the child (the loop dies, the launcher's reaper sees the exit).

## A14. Concurrency

Single cooperative scheduler per process; blocking I/O on the thread pool. Places relying on no preemption between suspension points (a threaded rewrite must lock each):

- tallies, `inFlight`, byte counters: plain integers;
- gate table: the loop's "waiters = 0 → remove" and a request's "waiters += 1 → spawn loop if not watching" must each be atomic, and the two must be mutually exclusive;
- a gate's `token` is written by both request paths (step 2) and the loop, unguarded; last writer wins, which is safe because both write a fresh store read;
- share manifest memo: unguarded, clear-when-full;
- admission pools: the pool primitive itself serialises acquire/release.

Nothing a client sends chooses a width: bulk ops are capped (1024 keys / 64 folders) and their reads go through the batch pool; the status fan-out is as wide as config (domains × peers), each leg deadline-bounded.

## A15. Invariants the tests pin down

- **http_proxy** (`tests/frontends/http_proxy`):
  - HMAC: fresh signature verifies; wrong secret, tampered path, tampered body, bad signature, a tampered range offset (range is in the signed query) and a timestamp outside ±300 s fail. Key encoding and listing JSON round-trip.
  - Routing: domain keys go to their domain; corrupted/verify-jobs/gc-jobs prefixes route to the owning domain and `within` rejects another domain's; a bulk op whose tail names another domain's key is refused (get-multi and delete-multi).
  - Share-manifest writes: with no sharing route, the authenticating route; with sharing routes, only an authenticating *sharing* route (a non-sharing secret gets none); two sharing domains each get their own. `/s/` token claiming: each domain's token served by it; unclaimed → first.
  - Ranged get routes, authorises and gates like get; `offset` or `length` alone, negative offset, zero length → Bad; no range → plain get. Info ops with no prefix → Bad.
  - children-multi routes by first prefix, confines all, gates as Get; `fits`: exactly a budget is taken first; over budget alone skipped; over the running total stops; framing round-trips including an absent body and the empty answer.
  - Read-only route: put, claim, delete, delete-multi, copy → 403; get of absent key → 404; writable route put → 200; share-prefix put 200 and delete 204 on a read-only route.
  - Option spec contains `shares` and `readOnly`; backend spec has `url`, `secret`, not `shares`.
  - Status: control-socket `stats` equals `/api/v1/stats`; the text report snapshot; secrets masked `***` in both; `/stats` and `/api/v1/stats` refuse unsigned/wrong secret and count `stats` and `unauthorized`; totals states (not asked, counting, estimate, exact, served stale, refreshing, error); `/domains` unsigned 401, wrong 401, signed lists the domain with `readOnly`.
  - Control socket: bad JSON, unknown action, empty action → `invalid`; `stop` answers `{"ok":true}`, requests stop once, and leaves the connection open.
- **proxy_bound**: at most `limit` data ops in flight and the limit is reached; excess held not refused up to `16×limit`; exactly `flood − limit − 16×limit` refused; nothing dropped; Put bounded too; Meta never held; budget intact after floods and a quiet period refuses nobody; bound = min of opinions, no-opinion ignored, none → default; no gate → unbounded.
- **proxy_watch**: plain GET unchanged; `wait` and `last_seen` parsed, `wait` clamped; watch is Meta but confined to its key; tokenless client answered 200; behind client → 200 + header, one read; up-to-date client → 204 + header at deadline, no re-read while held; 8 waiters, one change → 9 reads, all answered.
- **proxy_permanent** / **proxy_watch_client** (backend side, against this server's semantics): one 409 costs one request and its reason reaches the caller.
- **share_server**: whole file 200 with exact headers; `bytes=6-10` → 206 `bytes 6-10/39`; suffix range; unsatisfiable → 416; dir listing, sub-listing, file JSON metadata, nested bytes inline, forced download; bad/unknown/expired token; another domain's token → 404; `..` → 400; missing file → 404; ZIP accepted by a real unzip with exactly the shared tree; the 16-read bound holds (reads queue on it); nothing written to the manifest mirror.

## A16. Design choices (do not undo)

1. **Re-export the composite store, not the checkout.** A client runs its own core; the server stays stateless apart from watch gates, and applies replicas/backfills/health transparently. A client never sees roles.
2. **Route by first key, then confine every key.** Bulk ops name many keys; without the all-keys check one domain's secret reaches another's objects on a shared bucket.
3. **Four roots per domain**, from the layout, not spelled here: a route matching only `tsync/<d>/` answered every corruption listing 404.
4. **409 for permanent failures** (48e797b4).
5. **One watch per key, dropped with its last waiter; read on arrival** (cf3684d8).
6. **Gate data, not metadata; 503 past a 16× queue; bulk reads through a shared pool of the same size** (4060b0b1): a gate of 4 was serving 128 reads through the batch layer's default width.
7. **Bulk answers decided from listed sizes and streamed in pieces** (34183bb1).
8. **`chunk-size` not chained, `verified` and `max-concurrency` chained**: a chunk size is this domain's config; what a client may claim about markers is what the store behind claims; the bound is set by the slowest participant.
9. **`share-url` answers `{"self":true}`**: behind TLS termination the server cannot know its public URL; the client knows the URL it reached.
10. **Shares served from the store, not the mirror; one predicate for "who serves shares"** for both manifest writes and `/s/` reads (ca6ed151).
11. **Share slot before buffer, no share waiter limit**: memory bound without mid-stream refusals.
12. **Status authorised by any secret, `/domains` selected by the secret**: status has no key to route on; setup needs only its own domains.

## A17. Open questions / inconsistencies

1. **Request bodies are read whole, unbounded, before authentication and admission.** An unauthenticated client can make the server buffer an arbitrarily large body; N concurrent authenticated PUTs are all in memory before the gate can refuse any. A reimplementation should cap body size (a chunk plus slack; 1024 keys of JSON) and reject before reading.
2. **Share responses are not admission-bounded**; only their block reads are. Open responses, the manifest memo and a ZIP's member list are what run out first under public load.
3. **XSS in the browse page**: `__SHARE_DATA__` is JSON inserted into a `<script>` without escaping `<`/`/`, so a folder `filename` containing `</script>` breaks out. Escape `<` as `<` in that JSON.
4. **Gate table keyed by key string, not (domain, key).** Domain roots are disjoint so this only matters for share-prefix keys, where a loop started on one route's store serves waiters from another route.
5. **Watch token is the whole object body**, held in the gate and read on every arrival. Fine for cursor-sized objects; a watch on a chunk key reads and holds the chunk.
6. **`wait=nan`** passes the float parse and the clamp (min with NaN is NaN), leaving the deadline undefined; a negative `wait` gives an immediate 204. Reject non-finite and negative `wait`.
7. **HEAD drops the etag** while `/list` passes it through.
8. **Claims, deletes, copies and delete-multi bypass the gate** though they write the store.
9. **Control socket**: a JSON non-object answers `internal` rather than `invalid`.
10. **Any domain's secret sees every domain's status** on a shared listener (settings, backends, traffic; secrets masked).
11. **No request/idle timeouts** on inbound connections; slow clients hold connections (and, for data ops, gate slots) indefinitely.
12. **In-flight requests at stop** are not awaited explicitly: stop ends the accept loop and the drain begins; a proxied PUT still running races the drain.
13. **`max_keys_per_request` (1024) and the client's packing (256)** are separate constants that agree by coincidence.
14. **A domain named `shares`** would have a root `tsync/shares/` equal to the shares prefix.
15. **One listener per host**: conflicting ports across domains are a startup error rather than two listeners.
