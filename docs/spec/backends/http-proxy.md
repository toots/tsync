# Backend driver: `http-proxy`

A store whose objects live on another tsync machine. The client driver speaks an authenticated HTTP protocol to an `http-proxy` **listener** on that machine, which re-exports one or more of its domains' composite stores (roles, replicas and backfill applied on the far side, invisible here). This file owns the **wire protocol** for both ends and the **client driver**. What the server does behind each endpoint (routing, admission, watch coalescing, share serving, status collection) is in [the http-proxy frontend](../frontends/http-proxy.md). Every security requirement the wire meets is owned by [the security model](../algorithms/security-model.md) and referenced here.

Generic contract: [the store contract](../06-backends.md). Failure kinds: [the failure model](../algorithms/failure-model.md). OCaml notes: [ocaml/backends/http-proxy.md](../ocaml/backends/http-proxy.md).

---

## 1. Configuration

A backend entry in a domain's `backends` array:

```json
{ "name": "nas", "type": "http-proxy", "role": "main",
  "url": "https://nas.example:8443", "secret": "…", "link": "wan" }
```

| Field | Type | Default | Rule |
|---|---|---|---|
| `url` | string | required | `http(s)://host[:port][/base/path]`. No userinfo, query or fragment; a trailing `/` is dropped. `http` is accepted only for a loopback host ([security §9](../algorithms/security-model.md#9-tls)). Anything else is refused by config validation. |
| `secret` | string, secret | required | Shared HMAC key; equals the `secret` of the server's binding for this domain. At least `min_secret_length` characters ([security §10.1](../algorithms/security-model.md#101-generation-and-strength)). Masked in every report. |
| `ca_certificate` | path | blank | PEM bundle replacing the system trust store for this backend ([security §9](../algorithms/security-model.md#9-tls)). |

`name`, `role`, `link` are generic ([the store contract](../06-backends.md)). Nothing is contacted at construction.

**Base path.** Every request is sent to `<base path><API path>` (e.g. `/tsync/o/…`). The **signature covers the API path only** (§3.2): a reverse proxy that strips the base path delivers exactly what was signed, and a server reached without a base path sees the same bytes. The share URL a client composes keeps the base path (§5.5).

One driver instance serves one domain; the domain's prefix is fixed at construction and every memo below is per instance.

---

## 2. Transport

- HTTP/1.1 over TCP, or TLS for `https`, verified per [security §9](../algorithms/security-model.md#9-tls).
- Keep-alive connections MAY be reused. A client MUST close an idle connection before the server's `keepalive_timeout` ([security §11](../algorithms/security-model.md#11-request-size-and-time-limits-listener)), and redials once a reused connection found dead before the request left.
- **Stall timeout** `stall_timeout` (300 s): a request whose body upload or answer goes that long without a byte moving is abandoned as TRANSIENT/LINK. It is not a latency budget; a slow but moving transfer never trips it.
- Request headers: `x-tsync-timestamp`, `x-tsync-signature`, `host`, `content-length`. Clients MUST send `content-length` (never a chunked request body) so a server can refuse an oversized body before reading it.
- Answers may use `content-length` or chunked encoding. A client MUST accept both.
- A reverse proxy in front of a server MUST allow ≥ 35 s without response bytes (watch long-poll), MUST pass `x-tsync-*` headers unaltered, and MUST forward the query unaltered.

---

## 3. Authentication

### 3.1 Signing

Every request except those of §5.5 carries:

```
x-tsync-timestamp: <Unix time in seconds, decimal digits only, e.g. 1727600000>
x-tsync-signature: lowercase-hex( HMAC-SHA256( key = UTF-8 bytes of the secret,
                     msg = METHOD "\n" TARGET "\n" TIMESTAMP "\n" lowercase-hex(SHA-256(body)) ) )
```

- `METHOD`: `GET`, `HEAD`, `PUT`, `POST` or `DELETE`, upper case.
- `TARGET`: the API path plus `?` and the canonical query when there is a query (§3.2). No scheme, host, base path or fragment.
- `TIMESTAMP`: the header value, byte for byte.
- `body`: the exact body bytes; empty for GET, HEAD and DELETE (hash `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`).

Everything that changes behaviour travels in the signed target or body: ranges are query parameters, not a `Range` header.

### 3.2 Canonical target (byte-exact)

**Path.** Every API path is ASCII from `[A-Za-z0-9_/-]` (keys are base64url, §4.1) and is canonical as is.

**Query.** A client MUST emit exactly this form, and sign the same bytes it sends:

1. Parameters in the client's chosen order, each written `key=value` (the `=` always present, even for an empty value), joined by `&`. A parameter name MUST NOT repeat.
2. Each byte of a key or value is written literally if it is in the allowed set, else as `%XX` with **upper-case** hex:
   - allowed in a key: `A–Z a–z 0–9 - . _ ~ ! $ ' ( ) * , : @ / ?`
   - allowed in a value: `A–Z a–z 0–9 - . _ ~ ! $ ' ( ) * = : @ / ?`
   - so these are always encoded: space (`%20`, never `+`), `"`, `#`, `%`, `&`, `+`, `;`, `<`, `>`, `[`, `\`, `]`, `^`, `` ` ``, `{`, `|`, `}`, control bytes, bytes ≥ 0x80; plus `=` in a key and `,` in a value.

**Server.** A server MUST compute the signed string from the **canonical re-encoding** of the received query: split the raw query on `&`, split each part at its first `=`, percent-decode key and value (`+` stays `+`), then re-encode per rule 2 in received order. A query with a malformed `%` escape, a part without `=`, or a repeated name is refused 400. A server MAY additionally accept a signature over the raw received target. Both bind the same decoded parameters, which are the only thing the server acts on.

### 3.3 Verification

A request is authentic for a secret iff both headers are present, the timestamp is 1–15 decimal digits within `max_clock_skew` (300 s) of the server's clock, and the recomputed signature equals the header in constant time (upper-case hex does not verify). Freshness is checked before the body is read. The security properties and the replay stance are in [security §4](../algorithms/security-model.md#4-request-authentication-http-proxy).

Client and server clocks MUST agree within `max_clock_skew`; outside it every request is refused 401. Every 401 carries a `Date` header, so a client can report "clock skew" rather than a bad secret ([failure-model §4.3](../algorithms/failure-model.md#43-a-peer-tsync-store-http-proxy-client)).

### 3.4 Test vectors

Secret `s3cret`, timestamp `1727600000`. Canonical strings shown with each line break as `\n`.

| Request | Canonical string | Signature |
|---|---|---|
| `GET /o/dHN5bmMvZG9jcy9jdXJzb3I?last_seen=0000000000100-peer&wait=30` (key `tsync/docs/cursor`) | `GET\n/o/dHN5bmMvZG9jcy9jdXJzb3I?last_seen=0000000000100-peer&wait=30\n1727600000\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` | `676f55e451e2c18804ebfe64f0e40e7779bac0027b6f206be68cdf67a88e9799` |
| `PUT /o/dHN5bmMvZG9jcy9tYW5pZmVzdHMvYWIvZi0w?if_absent=1`, body `hello` | `PUT\n/o/…?if_absent=1\n1727600000\n2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824` | `aaad0b84828445ef41805f42d64c59c051d88f21456c8308b72e691dfbc40ad5` |
| `GET /list?mode=all&prefix=tsync/docs/manifests/` | `GET\n/list?mode=all&prefix=tsync/docs/manifests/\n1727600000\ne3b0…b855` | `4dda143e2738745c9629ec63e6e4904e5073531994ffa52d1a4cfed35e080f87` |
| `GET /domains` | `GET\n/domains\n1727600000\ne3b0…b855` | `88bfa097567658cbf464de58b53601df613701a09f172016c78f22a9148b3e2d` |

---

## 4. Encodings

### 4.1 Keys

- In a path: `/o/<k>`, `k = base64url(key)` (RFC 4648 §5 alphabet, no padding), one path segment. An undecodable segment is refused 400.
- Elsewhere (JSON bodies, `src`/`dst`/`prefix` values, frames): the key as a plain string.
- Every key and prefix, on either end, MUST satisfy the stored-key grammar of [01-core](../01-core.md) (a prefix may end in `/`); the enforcement points are [security §5.1](../algorithms/security-model.md#51-names).

### 4.2 Listing JSON

A JSON array of entries:

```json
[{"key":"tsync/d/manifests/ab/f-0","size":123,"lastModified":1727600000.25,"etag":"\"9b2c…\""}]
```

`key` string; `size` non-negative integer; `lastModified` number (Unix seconds, integer or fractional); `etag` string, **omitted** when the store names no version (absent ≠ empty). A body that is not an array of such objects is CORRUPT.

### 4.3 Frames

Lengths are unsigned 32-bit big-endian. `ABSENT = 0xFFFFFFFF` marks a key the store does not hold, distinct from a 0-length body. `field(s) = u32(len s) ‖ s`.

**get-multi answer**: for each requested key, **in request order**, `u32(n) ‖ n bytes` or `u32(ABSENT)`. Keys are not echoed; the order is the contract. A decoder holding the request's keys refuses an answer that ends early, has bytes left over, or has a length running past the end.

**children-multi answer**: zero or more folder frames:

```
folder := field(prefix) field(listing JSON, §4.2) u32(count) child{count}
child  := field(key) ( u32(n) n-bytes | u32(ABSENT) )
```

The listing is the folder's whole listing. `child` entries are its child objects only (not the namespace key, not internal leaves such as the folder index), each with its body or `ABSENT`. Every `prefix` MUST be one the request asked for and every child key MUST lie under its folder's prefix; anything else is CORRUPT. An empty answer is valid.

Decoders MUST bound every length by the bytes **remaining**, never by `pos + n` (which overflows on 32-bit builds). Any framing violation is CORRUPT.

---

## 5. Endpoints

`<k>` is §4.1. "Ro" = refused 403 on a read-only route ([frontend §A4.5](../frontends/http-proxy.md)). Numeric parameters are decimal digits only (no sign, no exponent, no leading `+`), at most 15 digits; anything else is 400.

### 5.1 Object API

| Request | Answer |
|---|---|
| `GET /o/<k>` | 200, body = the object. 404, empty body, when absent. |
| `GET /o/<k>?offset=O&length=L` | 200, bytes `[O, O+L)` clipped at the object's end (empty when `O ≥ size`). 404 when absent. Both required, `L ≥ 1`; one without the other → 400, never widened. |
| `GET /o/<k>?wait=S[&last_seen=T]` | Watch, §7. `S` is a decimal number (digits, optional `.` and digits), finite, `≥ 0`; clamped to 30. Anything else → 400. `offset`/`length` with `wait` → 400. |
| `HEAD /o/<k>` | 200 with `x-tsync-size: <int>`, `x-tsync-last-modified: <decimal seconds>`, and `x-tsync-etag: <etag>` when the store names a version; empty body. 404 when absent. |
| `PUT /o/<k>` (Ro) | Body = the object. Last writer wins. 200, empty body. |
| `PUT /o/<k>?if_absent=1` (Ro) | Conditional create arbitrated by the server's store. 200, body = **whatever is at the key afterwards**: the request body if this call created it, the earlier writer's body if not. A client MUST send `if_absent=1`. A server SHOULD accept `true`, `yes`, `on` (case-insensitive) as meaning `1`, and `0`, `false`, `no`, `off` as a plain PUT; any other value → 400. |
| `DELETE /o/<k>` (Ro) | 200 when an object was removed, 204 when nothing was there. Empty body. |

### 5.2 Bulk

Request body: a JSON array of strings, at least one, all within the same route. An element that is not a string, an empty array, a non-array, invalid JSON or too many elements → 400. Limits are wire constants both ends use:

| Constant | Value |
|---|---|
| `bulk_keys_max` | 1024 keys per get-multi or delete-multi |
| `bulk_folders_max` | 64 prefixes per children-multi |
| `bulk_answer_budget` | 8 MiB of child-object bytes per children-multi answer |

| Request | Answer |
|---|---|
| `POST /get-multi`, keys | 200, get-multi frames, one per key in order. A per-key read failure fails the whole request with its status; it is never reported as `ABSENT`. |
| `POST /children-multi`, folder prefixes | 200, children-multi frames. Folders in request order, each whole or not at all. A folder whose children alone exceed the budget is skipped; one that would take the running total past the budget ends the answer, unless it is the first one taken. |
| `POST /delete-multi` (Ro), keys | 200, empty. Absent keys are success. |
| `POST /copy?src=<key>&dst=<key>` (Ro) | 200, empty. Server-side copy on the far store. |
| `GET /list?mode=all&prefix=P[&max_keys=N]` | 200, listing JSON: every entry under `P`, recursive. `mode` must be `all`; `N ≥ 0` (0 lists nothing). |

### 5.3 Capabilities

Each takes `?prefix=P`, a prefix within the client's domain; it routes and authorises the request. Answer JSON, 200. **404 means "no opinion"**, which is also what a server without the endpoint answers.

| Request | 200 answer | 404 when |
|---|---|---|
| `GET /share-url?prefix=P` | `{"self":true}` when the listener serves the domain's share links; else `{"url":"<absolute URL>"}` when the domain's far store has a share endpoint | neither |
| `GET /chunk-size?prefix=P` | `{"chunkSize":n}`, `n > 0`: the serving domain's configured chunk size | not configured there |
| `GET /max-concurrency?prefix=P` | `{"maxConcurrency":n}`, `n > 0`: how many object reads and writes the listener runs at once | no bound |
| `GET /verified?prefix=P` | `{"verified":bool}`: the far composite store's `verified` capability | never (always answers) |

A value that is not a positive integer, or a body that does not parse, is no opinion.

### 5.4 Listener endpoints (signed, no key)

No key routes these; the secret selects. Authorisation per [security §12](../algorithms/security-model.md#12-status-and-discovery-authorisation).

| Request | Answer |
|---|---|
| `GET /domains` | 200 `{"domains":[{"name":"docs","readOnly":false}, …]}` for the domains whose secret verified the request; 401 when none did. Setup tools use it to validate URL and secret before a config exists; 404 means a server without the endpoint. |
| `GET /stats[?totals=1\|exact][&reload=1]` | 200 `text/plain` status report restricted to those domains; 401 otherwise. |
| `GET /api/v1/stats` (same parameters) | Same report as JSON ([status report](../07-daemon-cli.md)). |

Only `GET` matches these paths.

### 5.5 Unsigned endpoints

| Request | Answer |
|---|---|
| `GET /`, `GET /index.html` | 200 HTML status login page ([frontend §A10](../frontends/http-proxy.md)). |
| `GET\|HEAD /s/<token>[/<sub>]` | Public share links when some route on the listener serves shares, else 404. Semantics in [the frontend](../frontends/http-proxy.md); capability rules in [security §6](../algorithms/security-model.md#6-share-capabilities). |

A client composes a share URL as `<its configured url>/s/<token>` when the server answered `{"self":true}` (behind TLS termination the server cannot know its public URL), or `<url>/<token>` from `{"url":…}`.

Share **manifests** are written through the object API at `tsync/shares/<token>`, confined per [security §6.4](../algorithms/security-model.md#64-the-share-space-on-a-listener).

---

## 6. Status codes

### 6.1 Processing order

The first rule that applies decides the answer.

1. `/s/…` with shares served → share server. `/`, `/index.html` → status page.
2. Request line and headers over their limits → 414/431 ([security §11](../algorithms/security-model.md#11-request-size-and-time-limits-listener)).
3. Parse the operation. A path outside the API → **404** `not found`. An API path with malformed arguments (undecodable key, key or prefix failing the grammar, invalid parameter, a body where none belongs) → **400** `bad request`.
4. Declared body length over its limit → **413** `too large`.
5. Resolve the route from the operation's first key or prefix ([frontend §A4.3](../frontends/http-proxy.md)); check the timestamp; read the body; verify the signature; check every key and prefix against the route. Any failure here → **401** `unauthorized`, one status and body for all of them ([security §5.2](../algorithms/security-model.md#52-routes-on-a-listener)).
6. Admission for object reads and writes; queue full → **503** `busy`.
7. Execute. A write on a read-only route → **403** `read-only domain`. Absent object where the operation says so → 404 (empty body) / `ABSENT` / 204. A store failure → **409** if its kind is permanent, **500** if transient, both with the reason text.

Error bodies are short `text/plain` sentences for humans. Clients act on the status and on `x-tsync-kind` (§6.2), never on the body.

### 6.2 Failure kind header

Every 409 carries `x-tsync-kind: <kind>`, the permanent kind of the store failure ([failure-model §3.1](../algorithms/failure-model.md#31-kinds)) in lower case, with the subkind where there is one: `absent` (a source the operation needed is gone), `exists`, `not_empty`, `denied`, `read_only`, `other`, `invalid`, `corrupt`, `unprepared`, or `missing_chunks`. A client reads the kind from the header; a 409 without it, or with a value it does not know, is REFUSED/`other`.

`missing_chunks` is the GC reference gate's refusal of a manifest or version write ([gc.md §5.4](../algorithms/gc.md#54-the-collection-interlock)). Its body is the line `missing chunks` followed by one chunk key per line; the client validates each key and hands the list to the writer, which re-uploads them and retries. This is the one refusal whose body a client parses.

### 6.3 Client mapping

Statuses are read as failure kinds per [failure-model §4.3](../algorithms/failure-model.md#43-a-peer-tsync-store-http-proxy-client). Wire-specific rules:

- A 404 with an empty body on an object operation is ABSENT. A 404 with a non-empty body is never ABSENT: it is an unserved domain (REFUSED/`denied`) or a missing endpoint (§8.1, §8.3 tell them apart).
- A 409 is the kind in `x-tsync-kind` (§6.2).
- 400, 413, 414 and 431 are INVALID.
- An undecodable listing or framed answer after a 2xx is CORRUPT.

---|---|
| 2xx | success, per operation (§8.2) |
| 404 with an empty body on an object operation | ABSENT |
| 404 with a non-empty body, on any operation | REFUSED: the server does not serve this domain or lacks the endpoint; see §8.1 and §8.3 for the two cases the driver tells apart |
| 400, 413, 414, 431 | INVALID |
| 401 | REFUSED (`denied`) |
| 403 | REFUSED (`read_only`): the store contract's "not writable" |
| 409 | the kind in `x-tsync-kind` |
| 429, 503 | TRANSIENT/LOAD |
| other 5xx, transport error, stall, truncated body | TRANSIENT/LINK |
| undecodable listing or frames after a 2xx | CORRUPT |
| any other status | REFUSED |

---

## 7. Watch (long-poll)

Request: `GET /o/<k>?[last_seen=T&]wait=30`, signed like any GET. `<k>` MUST be the domain's cursor key; a watch on any other key is 400. `T` is the watch token of the last body the client read at `<k>`: that body with leading and trailing whitespace trimmed, canonically encoded. No `last_seen` means the client has read nothing.

Server answer, always with `x-tsync-watched: 1` and an empty body:

- The server reads the key's current token first.
- **200 at once** if it differs from `T`: object present and `T` absent, object absent and `T` present, or both present and unequal.
- Otherwise held until a change is seen (**200**) or `wait` seconds pass (**204**).
- An absent object never makes a watch answer 404.

Client: one attempt, outside the retry ladder. An answer **carrying** `x-tsync-watched` returns at once ("may have changed, re-read now"), whatever its status. An answer without it (a server without watch support) or any failure makes the client sleep `watch_floor` (2 s) before returning, so a caller whose only pacing is `watch` cannot spin. A failure is reported to the member's health like any request, and is otherwise swallowed; STOPPING and CANCELLED propagate.

---

## 8. Client driver

Every request is signed (§3) and goes through the retry ladder (§9) except `watch`. Every operation is idempotent; a claim retried after a lost answer reads back the winner, possibly itself.

### 8.1 First use: binding and claim support

Before its first operation, an instance learns two facts, concurrently with its capability requests (§8.4), memoised for the instance's life and forgotten if the asking failed:

- **Served.** `GET /list?mode=all&prefix=tsync/<d>/cursor&max_keys=1`. 200 → served. 401 or 404 → the server does not serve this domain for this secret: every operation fails REFUSED with "domain not served by <url>". `/list` is core, so its 404 can only mean an unserved domain.
- **Claims.** Claim support is proven by `/verified` answering 200: every server that answers `/verified` honours `if_absent`. When `/verified` answers 404, `put_if_absent` fails REFUSED with "server lacks conditional create" **without sending the PUT**: a server without it would perform a plain overwrite and clobber the real winner.

### 8.2 Mapping

| Contract op | Request | Result |
|---|---|---|
| `put key data` | `PUT /o/<k>` | ok |
| `put_if_absent key data` | `PUT /o/<k>?if_absent=1` (only when claims are supported, §8.1) | the answer body, a fresh buffer, never the caller's. `data` MUST be non-empty (INVALID otherwise). An empty answer body to a non-empty claim means the server did not honour the claim: CORRUPT. |
| `get key` | `GET /o/<k>` | body; ABSENT on 404 |
| `get_opt key` | `GET /o/<k>` | `Some body`; `None` on 404 with empty body |
| `get_range key off len` | `GET /o/<k>?offset=off&length=len` | body, **checked**: more than `len` bytes is CORRUPT (a server that ignored the range); `None` on 404. `len = 0` answers empty without a request. |
| `head_opt key` | `HEAD /o/<k>` | entry with `size`, `last_modified`, `etag` from `x-tsync-etag` when present; `None` on 404. A missing or malformed size or time header is CORRUPT. |
| `delete key` | `DELETE /o/<k>` | 204 or 404 → `false`; other 2xx → `true` |
| `delete_multi keys` | `POST /delete-multi` | paged, §8.3 |
| `copy src dst` | `POST /copy?src=…&dst=…` | ok. Bytes do not cross the link. |
| `list_prefix ?max_keys prefix` | `GET /list?…` | decoded listing |
| `get_many keys` | `POST /get-multi` | paged, §8.3; frames decoded against each page's keys |
| `list_many prefixes` | `POST /children-multi` | paged, §8.3; the folders answered. Folders the server skipped or omitted are absent from the result; the caller lists them singly ([store contract](../06-backends.md)). |
| `watch key last_seen` | §7 | unit |
| `capabilities prefix` | §8.4 | |
| `verify_all`, `bucket_functions` | none | `Unsupported` and `false`: queueing work in the peer's store is its administrator's decision; a collection's deletions use the bulk `delete_multi`, one request per batch. |
| `fast_read` / `local_path` | — | `false` / `None` |
| `health` | — | per-instance health fed by every request's outcome (§9) |

Keys read back from listings and frames are validated against the grammar before use ([security §5.1](../algorithms/security-model.md#51-names)).

### 8.3 Bulk operations: paging, empty lists, fallbacks

- **Empty list**: no request. `get_many []` and `list_many []` answer `[]`; `delete_multi []` succeeds.
- **Paging**: `get_many` and `delete_multi` send pages of at most `bulk_keys_max` keys; `list_many` pages of at most `bulk_folders_max` prefixes. Pages are sent one after another; a failed page fails the call (earlier pages' effects stand; every bulk op is idempotent).
- **Fallback for a server without bulk endpoints**: a 404 with a non-empty body from `/get-multi` or `/children-multi`, on an instance whose domain is known to be served (§8.1), means the endpoint does not exist. The instance remembers "unsupported" for its life: `get_many` then reads each key with `get_opt`, `list_many` answers `[]` so the caller lists folders singly.

### 8.4 Capabilities

Four requests (§5.3), issued concurrently on first ask with the domain's prefix:

| Field | From | 404 or unreadable body |
|---|---|---|
| `share_url` | `{"url":u}` → `u`; `{"self":true}` → `<configured url>/s` | `None` |
| `chunk_size` | `chunkSize` when a positive integer | `None` |
| `max_concurrency` | `maxConcurrency` when a positive integer | `None` |
| `verified` | `verified == true` | `false` (a peer that cannot say has not said) |

Any other non-2xx fails the call per §6.3. The result is memoised per prefix for the instance's life, shared by concurrent callers, and forgotten if it failed. The answers are fixed for the life of a server process.

What a domain does with them is generic: new files use the inherited chunk size, its own concurrency is bounded by the server's, the corruption check is reported as the far store's, share links point at the returned URL.

---

## 9. Retry

The shared retry ladder of [01-core](../01-core.md) applies: TRANSIENT kinds are retried with backoff, every other kind is raised at once with `HTTP <code>: <≤200-character body excerpt>`. A permanent failure costs one request. Link evidence for the member's health follows [the failure model](../algorithms/failure-model.md): TRANSIENT/LINK counts against the link, TRANSIENT/LOAD and any answered status count as the link being up.

---

## 10. Peer capabilities

There is no version negotiation. The **core** every server answers is: the object API without parameters, `/delete-multi`, `/copy`, `/list`, `/share-url` and the authentication of §3. Everything else is a capability a server may lack, and a client MUST work with a server lacking any of them:

| Capability | How a client knows it is missing | What the client does |
|---|---|---|
| `/chunk-size`, `/max-concurrency`, `/verified`, `/share-url` answers | 404 | no opinion (§8.4); `verified` reads `false` |
| Conditional create (`if_absent`) | `/verified` answers 404: a server that answers `/verified` honours `if_absent` | refuses `put_if_absent` locally, never sends it (§8.1) |
| `/domains` | 404 | setup tools report that the server needs updating |
| `/get-multi`, `/children-multi` | 404 with a non-empty body on a served domain | single reads; folders listed singly (§8.3) |
| Watch parameters | the answer lacks `x-tsync-watched` | sleeps `watch_floor` (§7) |
| Range parameters | the answer is longer than asked | CORRUPT, never served as the range |
| `etag` in listings, `x-tsync-etag` on HEAD | field or header absent | etag unknown (`None`) |
| `x-tsync-kind` on 409 | header absent | REFUSED/`other` |
| 204 on DELETE of nothing | a 200 | reads as "removed" |
| 409 for permanent failures | a 500 | retried by the ladder before failing |
| 401 for an unserved domain | a 404 with a non-empty body | REFUSED (§6.3, §8.1). A HEAD, which has no body, relies on the binding memo, refreshed whenever the capability memo is. |

A server MUST answer every client that uses only the core correctly: new endpoints are simply not called, extra headers and JSON fields are ignored, and every parameter a core client sends (`wait=30`, `if_absent=1`, decimal ranges and `max_keys`) satisfies the grammar of §5. The server-side GC gate applies to every client, and its `missing_chunks` refusal reaches a client that does not know the kind as a permanent 409, surfaced rather than published over.

---

## 11. Concurrency and consistency

- **Concurrency**: the inherited `max_concurrency` makes the domain hold excess client-side; a 503 is backed off by the ladder.
- **Consistency relied on**: whatever the far composite store guarantees. Reads are read-after-write for that server's own writes; `put_if_absent` is the far store's conditional create arbitrated by its first main; `watch` is as prompt as the far store's own watch, coalesced across clients.
- **Garbage collection**: every manifest or version write through a listener passes the server's reference gate ([gc.md §5.4](../algorithms/gc.md#54-the-collection-interlock)), and during a run chunk reads are answered from either space ([gc.md §5.8](../algorithms/gc.md#58-chunk-access-is-scoped-by-the-driver)). A client therefore deduplicates safely against what the server reports present, and re-uploads what a `missing_chunks` refusal names.

---

## 12. Conformance

- Signature: a fresh signature verifies; a wrong secret, tampered target, tampered body, tampered signature, upper-case hex, a non-decimal timestamp, or a timestamp outside the window fails. A range signed at one offset does not verify at another. The four test vectors of §3.4 reproduce. A client behind a base path signs the API path.
- Canonical query: a value containing `,`, space, `+`, `&` and non-ASCII bytes signs and verifies; a repeated parameter, a part without `=` or a malformed escape is 400.
- Keys round-trip through base64url; listing entries round-trip through JSON, `etag` included; HEAD carries the etag when the store names one.
- get-multi frames: keys, order and bodies round-trip; an empty body is not an absent one; a truncated body, fewer or more entries than keys, and a length prefix cut in half are CORRUPT; a 200 000-byte body round-trips.
- children-multi frames round-trip whole folders including an absent body; an empty answer decodes to no folders; a folder or child outside what was asked is CORRUPT.
- Budget: a folder exactly at the budget is taken first; one over it is skipped; one that would pass the running total ends the answer.
- Parameters: `offset` alone, `length` alone, a signed or non-decimal number, zero length, `wait=nan`, `wait=-1`, `wait=inf`, an unknown `if_absent` value, and a watch on a non-cursor key are all 400.
- Bulk: empty lists send nothing; 2 500 keys to `delete_multi` or `get_many` go as three pages; 130 prefixes to `list_many` go as three pages.
- Fallbacks: against a server without `/get-multi`, `get_many` answers correctly through single reads and does not ask the bulk endpoint again; without `/children-multi`, `list_many` answers no folders and does not ask again.
- Claims: against a server without `/verified`, `put_if_absent` fails REFUSED and no PUT reaches the server; an empty claim answer to a non-empty body is CORRUPT.
- Unserved domain: every operation, HEAD and `get_opt` included, fails REFUSED rather than reading as absent.
- Read-only: a 403 surfaces as the contract's not-writable failure.
- Permanent failures: a 409 costs exactly one request and its text and kind reach the caller; two 500s then a 409 cost three requests; a `missing_chunks` 409 delivers the named keys to the writer.
- A 401 carries `Date`; a client whose clock is off by more than the window reports clock skew.
- Capabilities: a failed first ask is not remembered; the next ask sends all four again.
- Watch: sends `wait=30` and `last_seen` exactly as its token, none when it has none; returns at once on an answer with `x-tsync-watched`; sleeps the floor on one without or on a failure, which costs one request.
- `/domains` and `/stats` require a valid signature from some route and list only the domains that secret opens.
