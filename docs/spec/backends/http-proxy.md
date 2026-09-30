# Backend driver: `http-proxy`

A store whose objects live on another tsync machine. The client driver speaks an authenticated HTTP protocol to an `http-proxy` **frontend** on that machine, which re-exports one or more of its domains' composite stores (every role, replica and backfill applied on the far side, invisible here). This file owns the **wire protocol** for both ends, and the **client driver**. The server's internals (admission gate, routing tables, watch coalescing, share serving, status collection) are in [the http-proxy frontend](../frontends/http-proxy.md); this file specifies only what a server must answer on the wire.

Generic contract: [the store contract](../06-backends.md). OCaml notes: [ocaml/backends/http-proxy.md](../ocaml/backends/http-proxy.md).

Sources: `lib/backends/api/http_proxy.ml{,i}` (the shared wire module: `Auth`, `Watch`, `Wire`), `lib/backends/drivers/http_proxy/http_proxy_backend.ml` (client), `lib/lwt/backends/drivers/http_proxy/` (registration), `lib/app/frontends/http_proxy/http_proxy_frontend.ml` (server, for the answers it gives).

---

## 1. Configuration

A backend entry in a domain's `backends` array:

```json
{ "name": "nas", "type": "http-proxy", "role": "main",
  "url": "https://nas.example:8443", "secret": "…", "link": "wan" }
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `url` | string | required | Base URL `http(s)://host[:port]`. **Only scheme, host and port are used**: every request replaces the path (`/o/…`, `/list`, …), so a proxy mounted under a sub-path of a reverse proxy is unreachable. No validation; an unparseable or empty URL fails every request as a transport error (transient). |
| `secret` | string, secret | required | Shared HMAC key. Must equal the `secret` of the server-side binding of the domain being reached. Masked (`***`) in every report. |

`name`, `role`, `link` are generic ([the store contract](../06-backends.md)). Unknown keys are refused by config parsing. A missing field fails construction with `http-proxy backend: missing field: <name>`. Nothing is contacted at construction.

One driver instance serves one domain: its capability answers are memoised without regard to the prefix asked (§8.3).

---

## 2. Transport

- HTTP/1.1 over TCP, or TLS when the URL scheme is `https`. The server certificate is verified against the system trust store with hostname check (conduit defaults for either TLS library). There is no option for a private CA, pinning or skipping verification; a self-signed server needs a trusted CA or a TLS-terminating reverse proxy with a public certificate.
- Pooled keep-alive connections: one pool per driver instance, ≤ 32 parallel connections per endpoint, idle connections kept 60 s. A pooled connection found dead before the request left is redialled once, on a fresh pool shared by every request that raced into the dead one.
- **Stall timeout 300 s**: an answer that goes 300 s without a byte arriving is abandoned (a timeout, transient). It is not a latency budget: a large body arriving slowly never trips it. The request body's upload is not covered.
- Request headers sent: `x-tsync-timestamp`, `x-tsync-signature`, plus what the HTTP library adds (`host`, `content-length`/`transfer-encoding`). No `content-type`; the server ignores it.
- Responses may be `Content-Length` or chunked. The two bulk answers (`/get-multi`, `/children-multi`) are streamed and so usually chunked; a client must accept both.
- A reverse proxy in front of a server must allow ≥ 30 s idle on a response (the watch long-poll) and must pass `x-tsync-*` headers and the request target unaltered (the signature covers it).

---

## 3. Authentication

### 3.1 Signing

Every request except the unsigned ones in §5.5 carries:

```
x-tsync-timestamp: <Unix time in seconds, decimal integer, e.g. 1727600000>
x-tsync-signature: lowercase-hex( HMAC-SHA256( key = secret (raw UTF-8 bytes),
                     msg = METHOD "\n" TARGET "\n" TIMESTAMP "\n" lowercase-hex(SHA256(body)) ) )
```

- `METHOD`: `GET`, `HEAD`, `PUT`, `POST`, `DELETE` (upper case).
- `TARGET`: the request target, path plus `?query` when there is one, in the canonical encoding of §3.2. No scheme, host or fragment.
- `TIMESTAMP`: the exact header string.
- `body`: the exact request body bytes; empty for GET/HEAD/DELETE (hash `e3b0c442…b855`).

The body hash binds a PUT's bytes; the target binds every parameter (range offsets, `if_absent`, `wait`, `last_seen`, prefixes, `src`/`dst`). This is why ranges travel in the query and not in a `Range` header: a tampered offset does not verify.

### 3.2 Canonical request target

The reference server does **not** verify the bytes it received. It parses the target, percent-decodes the query into an ordered list of `(key, [values])`, and re-serialises it; the signature must match that re-serialisation. A client therefore has to emit the canonical form, which is:

- Path: as sent. Every path in this protocol is ASCII from `[A-Za-z0-9_-/]`, which is canonical as is.
- Query: parameters in the order sent, `key=value` joined by `&`. Each byte outside the allowed set is written `%XX` with **upper-case** hex:
  - allowed in a key: `A–Z a–z 0–9 - . _ ~ ! $ ' ( ) * , : @ / ?`
  - allowed in a value: `A–Z a–z 0–9 - . _ ~ ! $ ' ( ) * = : @ / ?` (`,` is encoded as `%2C`, `=` is not)
  - always encoded: space (`%20`, never `+`), `&`, `;`, `+`, `#`, `%`, non-ASCII bytes.
- Always write `key=value`, even for an empty value.

Parameter order is free (the server keeps it), but must be the same in the signed string and on the wire. Signing the exact bytes sent in canonical form satisfies both the reference server and any server that verifies the raw target.

A reimplemented server should verify against the canonical re-encoding (for compatibility with existing clients) and may also accept a match on the raw target.

### 3.3 Verification

A request is authentic for a secret iff both headers are present, `|now − float(timestamp)| ≤ 300 s`, and the recomputed signature equals the header byte for byte (constant-time; upper-case hex does not verify). There is no nonce: an identical request can be replayed within the window. That is harmless only because every operation is idempotent; a non-idempotent operation added later needs a nonce.

Which secret is tried depends on the route the request resolves to (§6). A clock more than 5 minutes off fails every request with 401.

### 3.4 Test vectors

Secret `s3cret`, timestamp `1727600000`:

| Request | Canonical string (`\n` shown as line breaks) | Signature |
|---|---|---|
| `GET /o/dHN5bmMvZG9jcy9jdXJzb3I?last_seen=0000000000100-peer&wait=30` (key `tsync/docs/cursor`) | `GET` / `/o/dHN5bmMvZG9jcy9jdXJzb3I?last_seen=0000000000100-peer&wait=30` / `1727600000` / `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `676f55e451e2c18804ebfe64f0e40e7779bac0027b6f206be68cdf67a88e9799` |
| `PUT /o/dHN5bmMvZG9jcy9tYW5pZmVzdHMvYWIvZi0w?if_absent=1`, body `hello` | `PUT` / `/o/…?if_absent=1` / `1727600000` / `2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824` | `aaad0b84828445ef41805f42d64c59c051d88f21456c8308b72e691dfbc40ad5` |
| `GET /list?mode=all&prefix=tsync/docs/manifests/` | `GET` / `/list?mode=all&prefix=tsync/docs/manifests/` / `1727600000` / `e3b0…b855` | `4dda143e2738745c9629ec63e6e4904e5073531994ffa52d1a4cfed35e080f87` |

---

## 4. Encodings

### 4.1 Keys

- In a path: `/o/<k>`, `k = base64url(key)` (RFC 4648 §5 alphabet, **no padding**), one path segment. The server answers 400 to an undecodable segment.
- Everywhere else (JSON bodies, `src`/`dst`/`prefix` query values, frames): the key as a plain string.

### 4.2 Listing JSON

A JSON array of entries:

```json
[{"key":"tsync/d/manifests/ab/f-0","size":123,"lastModified":1727600000.25,"etag":"\"9b2c…\""}]
```

`key` string; `size` integer bytes; `lastModified` number (Unix seconds, fractional allowed; integers accepted); `etag` string, **omitted** when the serving store names no version (absent ≠ empty). The etag is the far store's own version name, passed through so a client behind a proxy can cache bodies against it. A body that is not a JSON array is a decode failure.

### 4.3 Frames

All lengths are unsigned 32-bit big-endian. `ABSENT = 0xFFFFFFFF` marks a key the store does not hold, distinct from a 0-length body. `field(s) = u32(len s) ‖ s`.

**get-multi answer** (§5.2): for each requested key, **in request order**, either `u32(n) ‖ n bytes` or `u32(ABSENT)`. Keys are not echoed: the order is the contract. A decoder holding the request's keys rejects an answer that ends early, has bytes left over, or has a length running past the end. Omitting keys means an answer that decoded short cannot pass as a run of absences.

**children-multi answer** (§5.2): zero or more folder frames, self-describing because the answer may stop early or skip folders:

```
folder := field(prefix) field(listing JSON, §4.2) u32(count) child{count}
child  := field(key) ( u32(n) n-bytes | u32(ABSENT) )
```

The listing is the folder's whole `list_prefix` answer. `child` entries are only its child objects (not the namespace key itself nor store bookkeeping such as a folder's index key), each with its body or `ABSENT`. An empty answer is valid (no folders). A decoder rejects any truncated field or body.

Decoders must bound every length by the bytes **remaining**, never by `pos + n` (which overflows on 32-bit builds).

---

## 5. Endpoints

### 5.1 Object API

`<k>` is §4.1. "Ro" = refused 403 on a read-only route (§6.3).

| Request | Answer |
|---|---|
| `GET /o/<k>` | 200, body = the object. 404, empty, when absent. |
| `GET /o/<k>?offset=O&length=L` | 200, body = bytes `[O, O+L)` clipped at the object's end (possibly empty when `O ≥ size`). 404 when absent. Requires both, decimal, `O ≥ 0`, `L > 0`; anything else (one missing, negative, zero length, non-numeric) → **400**, never widened to the whole object. |
| `GET /o/<k>?wait=S[&last_seen=T]` | Long-poll watch, §7. Presence of `wait` (parseable as a number) makes it a watch; `offset`/`length` are then ignored. |
| `HEAD /o/<k>` | 200 with `x-tsync-size: <int>` and `x-tsync-last-modified: <float, 6 decimals>`, empty body. 404 when absent. No etag header. |
| `PUT /o/<k>` (Ro) | Body = the object. Last writer wins. 200, empty body. |
| `PUT /o/<k>?if_absent=1` (Ro) | Atomic claim arbitrated by the server's store: write only if nothing is at `<k>`. 200, body = **whatever is at the key afterwards**: the request body if this call won, the earlier writer's body if not. `if_absent` accepts `1`/`true`/`yes`/`on` (case-insensitive) as true; anything else is a plain PUT. |
| `DELETE /o/<k>` (Ro) | **200** when an object was removed, **204** when nothing was there. Empty body. |

### 5.2 Bulk

Request body: a JSON array of strings. Non-string elements are dropped by the reference server (a client must not send them: a dropped key shifts every get-multi frame after it). An empty array, a non-array, invalid JSON or too many elements → **400**. The bulk op is routed by its **first** element and every element must be within the same domain (§6).

| Request | Limit | Answer |
|---|---|---|
| `POST /get-multi`, keys | ≤ 1024 keys | 200, get-multi frames (§4.3), one per key in order. A per-key read failure fails the whole request (409/500); it is never reported as `ABSENT`. |
| `POST /children-multi`, folder prefixes | ≤ 64 prefixes | 200, children-multi frames (§4.3). Folders are answered in request order, each whole or not at all. Budget: 8 MiB of child-object bytes by listed size. A folder whose children alone exceed 8 MiB is **skipped** (later ones still considered); one that would take the running total past 8 MiB **ends** the answer (unless it is the first one taken). The client asks for whatever is missing by other means. |
| `POST /delete-multi` (Ro), keys | ≤ 1024 keys | 200, empty. Absent keys are success. |
| `POST /copy?src=<key>&dst=<key>` (Ro) | — | 200, empty. Server-side copy on the far store. Both keys in the query, plain (canonically encoded). Missing either → 400. |
| `GET /list?mode=all&prefix=P[&max_keys=N]` | — | 200, listing JSON (§4.2): every entry under `P`, recursive, flat. `mode` must be `all` and `prefix` present, else 400. A `max_keys` that does not parse is ignored (full listing); a negative one lists nothing. |

### 5.3 Capabilities

Each takes `?prefix=P` (the client's domain prefix, e.g. `tsync/docs/manifests/`; it routes and authorises the request). Missing `prefix` → 400. Answer JSON, 200; **404 means "no opinion"** and is also what a server too old for the endpoint answers.

| Request | 200 answer | 404 when |
|---|---|---|
| `GET /share-url?prefix=P` | `{"self":true}` when this listener serves share links itself; else `{"url":"<absolute URL>"}` when the domain's far store has one of its own (e.g. an S3 share endpoint) | neither |
| `GET /chunk-size?prefix=P` | `{"chunkSize":n}`, `n > 0`: the serving domain's configured chunk size | not configured there. Not chained through a proxy-backed store. |
| `GET /max-concurrency?prefix=P` | `{"maxConcurrency":n}`, `n > 0`: how many object reads/writes the listener runs at once | the listener has no bound. Effectively chained: the listener's bound derives from its own stores' `max_concurrency`, including a further proxy's. |
| `GET /verified?prefix=P` | `{"verified":bool}`: the domain's composite store's `verified` capability, chained, so a proxy in front of an unchecked store never claims a clean domain | — (always answers) |

A value that is not a positive integer, or a body that does not parse, reads as no opinion (§8.3).

### 5.4 Listener endpoints (signed, no key)

No key to route on, so the secret selects.

| Request | Auth | Answer |
|---|---|---|
| `GET /domains` | Any route's secret | 200 `{"domains":[{"name":"docs","readOnly":false}, …]}`: only the domains whose secret verified this signature. 401 when none did. Used by setup UIs (the Android app) to validate URL + secret and list what the secret opens, before any config exists. A 404 means a server older than the endpoint. |
| `GET /stats` | Any route's secret | 200 `text/plain` status report. `?totals=1` (estimate chunk totals) or `?totals=exact`, plus `&reload=1` to recount. 401 otherwise. |
| `GET /api/v1/stats` | same | Same report as JSON. Schema: [status report](../07-daemon-cli.md). |

Only `GET` matches these; another method falls through to 404.

### 5.5 Unsigned endpoints

| Request | Answer |
|---|---|
| `GET /`, `GET /index.html` | 200 HTML login page that signs `/stats` requests in the browser (WebCrypto HMAC, or a built-in JS HMAC self-checked against a known vector before use). The secret stays in the browser's session storage. |
| `* /s/<token>[/<sub>]` | Public share links, only when some route on the listener serves shares (else the path falls through to 404). The token is the only credential. `sub` ∈ `""` (file bytes, or the folder's browse page), `download`, `list?path=`, `f?path=[&dl=1][&json=1]`; a `Range` header is honoured for file bytes (206/416). 404 unknown token or path, 410 expired. Content and semantics: [the http-proxy frontend](../frontends/http-proxy.md). |

The share **URL** a client hands out is `<scheme>://<host>[:port]/s/<token>` built from its own configured `url` when the server answered `{"self":true}` (the server behind TLS termination cannot know its public URL; the client knows the one it uses), or `<url>/<token>` from the server's `{"url":…}`.

Share **manifests** are written through the object API like any object, at keys under the shares prefix `tsync/shares/…` (outside every domain root, §6.2).

---

## 6. Routing, confinement and status codes

### 6.1 Processing order

A server answers in this order; the first rule that applies decides the status.

1. `/s/…` with shares served → share handler (§5.5). No signature.
2. Fixed `GET` routes of §5.4/§5.5.
3. Parse the operation. A path outside the API → **404** `not found`. An API path with malformed arguments (undecodable key, missing/invalid parameter, bad bulk body, over a bulk limit) → **400** `bad request`. Both are answered **before** authentication.
4. Resolve the route from the operation's first key or prefix (§6.2). None (including a shares key no route's secret verifies) → **404** `unknown domain`.
5. Signature against that route's secret fails → **401** `unauthorized`.
6. Any key or prefix the operation names outside that route (§6.2) → **401** `keys outside the domain this request is for`. Refused whole, never narrowed.
7. Object reads and writes (`GET /o/` including ranges, `/get-multi`, `/children-multi`, plain `PUT`) wait for an admission slot; when the wait queue is full → **503** `busy`. Watches, HEAD, deletes, claims, copy, list and capabilities are not admitted this way.
8. Execute. Writes on a read-only route → **403** `read-only domain` (§6.3). Absent object where the op says so → 404 / `ABSENT` / 204. A store failure → **409** with the reason text if the store calls it permanent (a considered answer: object not there or not as recorded, unwritable), **500** with the reason text if transient.

Error bodies are short `text/plain` sentences for humans; clients act on the status alone.

### 6.2 Domain confinement

- A domain's **roots** are `tsync/<d>/`, `tsync/corrupted/<d>/`, `tsync/verify-jobs/<d>/`, `tsync/gc-jobs/<d>/`. A route owns a name iff the name starts with one of its roots, or with the shares prefix `tsync/shares/`.
- The first key/prefix selects the route whose roots contain it. A name under `tsync/shares/` belongs to no domain: it goes to the first share-serving route whose secret verifies, or when no route on the listener serves shares, to the first route whose secret verifies. (So a manifest lands in a store that will be read for it.)
- Every other key the operation names (bulk lists, `copy`'s `dst`, children prefixes) must be owned by the same route. Without this check a bulk op headed by the caller's own key could reach another domain sharing the same bucket.

### 6.3 Read-only

A route is read-only when the served domain is, or the binding sets `readOnly`. It refuses `PUT` (both forms), `DELETE`, `/delete-multi`, `/copy` with 403, except single-object `PUT`/`DELETE` of share-manifest keys (publishing or revoking a link changes no domain content). Reads are unaffected. A client cannot opt out.

---

## 7. Watch (long-poll)

Wire parameters (`Http_proxy.Watch`): `wait` (seconds, clamped server-side to **30**), `last_seen` (token), answer header `x-tsync-watched`.

Request: `GET /o/<k>?wait=30[&last_seen=T]`, signed like any GET. `T` is the watch token of the last body the client read at `<k>`: that body with leading/trailing whitespace trimmed, sent as is (canonically encoded, §3.2). No `last_seen` means the client has read nothing yet.

Server answer, always with `x-tsync-watched: 1` and an empty body:

- It reads the key's current token itself first (closing the window between the client's read and the server's).
- **200 at once** if it *differs* from `T`: object present and `T` absent, object absent and `T` present, or both present and unequal (compared after trimming).
- Otherwise held until a change is seen (**200**) or `wait` seconds pass (**204**).
- An absent object never makes a watch answer 404; it compares as "no token". (404 still means an unknown domain, §6.1.)
- Not admitted through the data slots (a 30 s hold would starve real work); still routed, authenticated and confined against `<k>`.

The client treats any answer **carrying** `x-tsync-watched` as "may have changed, re-read now", whatever the status. An answer **without** it (a server older than the parameter answered it as a plain GET, at once) or any failure makes the client sleep **2 s** before returning, so a caller whose only pacing is `watch` cannot spin. Watch is therefore never a source of errors: failures are swallowed after the retry ladder (§9) gives up.

---

## 8. Client driver: the store contract, operation by operation

All requests are signed (§3) and go through the shared retry ladder (§9); every operation is idempotent (a claim's retry after a lost answer reads back the winner, possibly itself).

### 8.1 Mapping

| Contract op | Request | Result mapping |
|---|---|---|
| `put key data` | `PUT /o/<k>` | 2xx → ok; else raise. |
| `put_if_absent key data` | `PUT /o/<k>?if_absent=1` | 2xx → response body (the winner). Never the caller's buffer itself, so a caller judges the win by content, not identity. Else raise. |
| `get key` | `GET /o/<k>` | 2xx → body; 404 → raise permanent `HTTP 404`. |
| `get_opt key` | `GET /o/<k>` | 2xx → `Some body`; 404 → `None`. |
| `get_range key off len` | `GET /o/<k>?offset=off&length=len` | 2xx → body, **checked**: more than `len` bytes raises permanent `http-proxy get_range <k>: asked for len bytes, got m` (a server that ignored the range); 404 → `None`. |
| `head_opt key` | `HEAD /o/<k>` | 2xx → entry with `size = x-tsync-size` (missing → 0), `last_modified = x-tsync-last-modified` (missing → 0.0), `etag = None`; 404 → `None`. |
| `delete key` | `DELETE /o/<k>` | 204 or 404 → `false`; other 2xx → `true`. |
| `delete_multi keys` | `POST /delete-multi`, JSON array | 2xx → ok. **Not paged by the driver** (see §12). |
| `copy src dst` | `POST /copy?src=…&dst=…` | 2xx → ok. Bytes do not cross this link. |
| `list_prefix ?max_keys prefix` | `GET /list?mode=all&prefix=P[&max_keys=N]` | 2xx → decoded listing; 404 (unknown domain) raises. |
| `get_many` | **declared** (`Some`): `POST /get-multi` | 2xx → frames decoded against the request keys. The caller-side batching layer has already packed the run to ≤ 256 keys and ≤ 8 MiB of listed sizes. |
| `list_many` | **declared**: `POST /children-multi` | 2xx → folders decoded. **404 sets a sticky "unsupported" flag** for the life of the instance: this call and every later one answer `[]` without a request (the caller then lists each folder singly). |
| `watch key last_seen` | §7 | Returns unit; never raises. |
| `capabilities prefix` | §8.3 | |
| `verify_all` | none | `Unsupported`: the far store's checks are its administrator's decision. |
| `discard` | none | `Unsupported`: queueing work in the peer's store is not the client's call; callers fall back to `delete_multi`, which reaches the far store's own deletion anyway. |
| `fast_read` | — | `false`. |
| `local_path` | — | `None`. |
| `health` | — | A per-instance health cell fed by every request's outcome (§9). |

Keys are rendered with their plain string spelling before encoding; keys read back from listings and frames are taken as listed.

### 8.2 Where it is stronger or weaker than the contract

- **Stronger**: `get_many`/`list_many` are real single round trips (the only driver that declares them). A walk of a tree costs one request per ≤ 64 folders instead of two per folder.
- **Stronger**: `copy` is server-side on the far machine.
- **Weaker**: `head_opt` carries no etag, although `list_prefix` does.
- **Weaker**: `put_if_absent` is only as atomic as the far store's own claim, and only if the server knows `if_absent` (§10.2).
- **Weaker**: `get` of an absent key raises a generic permanent HTTP failure, not the store-error class a local store raises; both classify permanent.
- A server refusing a write as read-only surfaces as a permanent `HTTP 403` failure, not the contract's "not writable" error.

### 8.3 Capabilities

Four requests (§5.3), issued **concurrently** on first ask, each with the prefix passed in:

| Field | From | 404 / unreadable body |
|---|---|---|
| `share_url` | `{"url":u}` → `u`; `{"self":true}` → `<url's scheme://host[:port]>/s` | `None` |
| `chunk_size` | `chunkSize` when a positive integer | `None` |
| `max_concurrency` | `maxConcurrency` when a positive integer | `None` |
| `verified` | `verified == true` | `false` (an old server never checked; a peer that cannot say has not said) |

Any other non-2xx on any of them fails the whole call (4xx permanent, 5xx after retries). The result is memoised for the life of the instance, shared by concurrent callers (one set of four requests), and **forgotten if it failed**, so a peer that was down at the first ask is asked again next time. The server's answers are treated as fixed: changing any of them requires a server restart, which drops these connections anyway.

What the domain does with them is generic: it writes new files at the inherited chunk size, bounds its own concurrency to the server's so excess waits client-side rather than in the server's queue, reports the corruption check as the far store's, and points share links at the returned URL.

---

## 9. Retry and error mapping

| Condition | Class | Driver behaviour |
|---|---|---|
| Transport error (refused, reset, DNS, TLS), stall timeout | transient | Retried by the ladder |
| HTTP 5xx (incl. 500 store-transient, 503 busy), 429 | transient | Retried |
| HTTP 409 (store-permanent), 400, 401, 403 | permanent | Raised at once, `HTTP <code>: <≤200-char body excerpt>` |
| HTTP 404 | — | Interpreted per operation (§8.1); raised permanent where the op has no absent answer |
| Undecodable listing JSON or frames | raised after the request succeeded, outside the ladder | Callers' classification treats an unrecognised failure as transient |

Ladder (shared by every HTTP driver): up to 8 attempts, delay before attempt `n+1` = `min(20, 0.5·2^(n−1))` s × uniform[0.5, 1.5). Stops early on a permanent failure, shutdown or cancellation. Each transient failure is reported to the instance's health cell (which may trip the member to "down" for the composite); an answer of any status, 4xx included, counts as the link being up.

409 exists so a condition that will not clear (a copy whose source is gone) costs the client one request instead of eight.

---

## 10. Versioning and compatibility

There is no version negotiation. Compatibility rests on each addition being either an optional endpoint (404 = unsupported) or a parameter an old peer ignores in a detectable way.

### 10.1 Feature timeline

| Added | Wire change | Newer client ↔ older server |
|---|---|---|
| 2026-07-24 | Object API, `/delete-multi`, `/copy`, `/list`, `/share-url`, HMAC | baseline |
| 2026-07-27 | `/chunk-size` | 404 → no opinion |
| 2026-08-01 | `/max-concurrency`, 503 `busy` | 404 → unbounded |
| 2026-08-07 | `PUT …?if_absent=1` | **undetected**, §10.2 |
| 2026-08-09 | `/domains` | 404 → "update tsync on the server" in setup UIs |
| 2026-08-14 | `/verified` | 404 → `false` |
| 2026-08-21 | `/get-multi`; bulk confinement; `etag` in listings | **no fallback**: `get_many` against an older server gets 404 and raises permanent. Listings without `etag` read as `None`. |
| 2026-08-26 | `?wait=&last_seen=`, `x-tsync-watched` | old server answers the GET at once without the header → client sleeps 2 s per watch |
| 2026-08-29 | `?offset=&length=` | old server returns the whole object → rejected by the range check (permanent), not silently served |
| 2026-09-03 | `/children-multi` | 404 → sticky unsupported, folders listed singly |
| 2026-09-06 | `DELETE` answers 204 for "nothing there" | old server's 200 reads as "removed" (the previous meaning) |
| 2026-09-17 | 409 for permanent store failures | old server's 500 is retried 8 times before failing |

Older client ↔ newer server: every server answer is a superset (new endpoints are simply not called; `etag` is an extra JSON field; 204 on DELETE is a 2xx), except that an older client treats 409 as permanent the same way (all 4xx are permanent) and treats a 204 DELETE as success.

### 10.2 The claim hole

A server older than `if_absent` treats `PUT …?if_absent=1` as a **plain PUT**: it overwrites whatever holds the key and answers 200 with an empty body. The client receives an empty "winner", which does not parse as the other writer's claim, so the caller concludes it won. Two clients creating the same folder concurrently can each believe they own the name, and the earlier marker is clobbered. Nothing on the wire detects this; client and server must be of a version. A server that cannot claim (read-only, permanent failure) answers 403/409, which the naming layer does detect and falls back from with a warning.

---

## 11. Concurrency, memory, consistency

- **Concurrency**: the driver has no pool of its own beyond the ≤ 32 connection limit; callers bound work (domain transfer limits, batch read slots), and the inherited `max_concurrency` makes the domain hold excess on the client. A server over capacity answers 503 and the ladder backs off.
- **Memory**: request bodies are sent from the caller's buffer without a copy. A response body is held whole in memory before it is interpreted, including bulk answers (≤ ~8 MiB of bodies plus framing by the server's budget; get-multi by the client's packing). Decoding a bulk answer copies each body out, so peak is a small multiple of the answer.
- **Consistency relied on**: whatever the far composite store guarantees. Reads through the proxy are read-after-write for that server's own writes (the far store's semantics), `put_if_absent` is the far store's claim arbitrated by its first main, `watch` is as prompt as the far store's own watch (a local directory watch, or a 2 s poll for an object store), coalesced across clients.
- **Clock**: client and server clocks must agree within 5 minutes.

---

## 12. Test-pinned invariants

- Signature: a fresh signature verifies; a wrong secret, tampered target, tampered body, tampered signature or a timestamp 1000 s old fails. A range signed at one offset does not verify at another.
- Keys round-trip through base64url; listing entries round-trip through JSON, `etag` included.
- get-multi frames: keys, order and bodies round-trip; an empty body is not an absent one; a truncated body, fewer or more entries than keys, and a length prefix cut in half are all refused; a 200 000-byte body round-trips.
- children-multi frames round-trip whole folders including an absent body; an empty answer decodes to no folders.
- Budget: a folder exactly at the budget is taken first; one over it is skipped; one that would pass the running budget stops the answer.
- Range parsing: `offset` alone, `length` alone, negative offset or zero length → 400; no range → plain GET.
- Routing: domain keys route to their domain; corruption, verify-jobs and gc-jobs prefixes route to their domain; a key outside every root is 404; share keys route to the share-serving route whose secret signed, and are refused for a secret of a non-sharing route when one route serves shares; a bulk op whose tail reaches another domain is refused.
- Read-only: every mutating op is 403; reads unaffected (404 on absent); share-manifest PUT 200 and DELETE 204 still allowed.
- Admission: never more object reads or writes at once than the limit; metadata is never held behind data; a flooded queue holds exactly its limit and refuses the rest; the listener bound is the lowest store opinion, ignoring stores with none.
- Watch (server): only a request with `wait` is a watch; `wait` is clamped to 30; a client with no token or an out-of-date token is answered 200 at once with the header after one read; an up-to-date one gets 204 with the header at the deadline without further store reads; N waiters on one key cost one read each plus one per change.
- Watch (client): sends `wait=30` and `last_seen` exactly as its token, no `last_seen` when it has none; returns at once on an answer with `x-tsync-watched`; sleeps (≥ 1 s) on one without.
- `list_many`: a 404 answers no folders and the server is not asked again.
- Permanent failures: a 409 costs exactly one request and its text reaches the caller; two 500s then a 409 cost three requests.
- Capabilities: a failed first ask (403) is not remembered; the next ask sends all four requests again.
- `/domains` and `/stats` require a valid signature from some route and list only the domains that secret opens.

---

## 13. Open questions

1. **Claim against an old server** (§10.2) is undetectable. A version header, or requiring the claim answer to carry a marker such as `x-tsync-claimed`, would close it.
2. **No nonce** in the signature (§3.3).
3. **`get_many` has no fallback** against a server older than `/get-multi` (404 raises), unlike `list_many`.
4. **`delete_multi` is not paged by the driver** while the server refuses > 1024 keys with 400 (permanent). GC and retention send ≤ 1000 per call by default, but the GC delete-batch knob, share revocation (every cached object of a share in one call) and the composite's deferred jobs pass their callers' lists unchanged.
5. **Empty bulk lists are 400**: the driver does not guard against `delete_multi []`, `get_many []` or `list_many []`; today's callers avoid them.
6. **`url` with a path** is silently reduced to its origin by the driver (§1), while the Android setup client appends `/domains` to the URL as typed (and signs `/domains`). Behind a path-stripping reverse proxy the setup check passes and the configured driver then misses the server.
7. **Canonical target** (§3.2): the server verifies a re-encoding rather than the received bytes; a client that percent-encodes differently (lower-case hex, `%2F` in a prefix, `+` for space) is refused with 401.
8. **HEAD drops the etag** that listings carry.
9. **Read-only refusals** reach the caller as a permanent HTTP 403, not the contract's "not writable" error, so a frontend cannot map them to EROFS without matching status.
10. **Unknown domain answers 404**, which `get_opt`, `get_range`, `head_opt` and `delete` read as "absent": a client pointed at a server that does not serve its domain sees an empty store on reads (only listings and writes fail).
11. **Watch transient failures climb the full ladder** (up to ~1–2 min of backoff) before being swallowed, rather than failing fast to the 2 s floor.
12. **Capability memo ignores `prefix`**: correct only because one instance serves one domain.
