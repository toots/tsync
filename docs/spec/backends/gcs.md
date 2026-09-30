# gcs — Google Cloud Storage driver

Scope: `lib/backends/drivers/gcs/{gcs_backend,gcs_auth}.ml`, `lib/lwt/backends/drivers/gcs/gcs_backend_lwt.ml`, `tests/backends/gcs`, the GCS half of `tests/conformance`, `lambda/store_gcs.py` and the GCP entry points of `lambda/{verify,handler}.py`, `terraform/modules/store-gcs`.

This file says how the gcs driver realises [the store contract](../06-backends.md) (§3.1). Everything an object store answers the same way whoever runs it — the string-keyed verb set, `watch`, `capabilities`, `verify_all`/`discard` as bucket-queued jobs, the pooled HTTP client, the retry ladder, health, the status→class mapping — is specified once in [the object-store shell](object-store-common.md) and only referenced here. What follows is what is Google-specific.

OCaml notes: [ocaml/backends/gcs.md](../ocaml/backends/gcs.md).

---

## 1. Configuration

Registered under backend type `"gcs"`. All four fields are strings in the backend's JSON object; an empty string and an absent field mean the same thing (except `bucket`).

| JSON field | Secret | Default | Meaning / validation |
|---|---|---|---|
| `bucket` | no | — (required) | Bucket name, used verbatim in URLs (not validated, not escaped). Missing → construction fails `gcs backend: missing field: bucket`. |
| `serviceAccountKey` | yes | `""` | The **text** of a GCP service-account JSON key file (not a path). Empty → anonymous requests, meant only for an emulator on a custom `endpoint`. |
| `endpoint` | no | `""` → `https://storage.googleapis.com` | Scheme + host (+ optional port), e.g. `http://localhost:4443`. One trailing `/` is trimmed. Changes the storage base only; token minting still goes to the key's `token_uri`. |
| `shareUrl` | no | `""` → none | Base URL of the share function deployed on this bucket, no trailing slash. Reported as `caps.share_url`; share links are `<shareUrl>/<token>`. |

`tsync config --edit` → "Sync from Terraform" fills them from `terraform output`: `gcs_stores.<store>.{bucket, share_url}` and the sensitive map `gcs_service_account_keys.<store>` (§8).

### 1.1 Service-account key parsing (at construction)

The JSON object is parsed eagerly; any failure aborts building the store (config error, not a request error):

| Condition | Error text |
|---|---|
| not JSON | `gcs: service account key is not valid JSON` |
| `client_email` or `private_key` missing / not a string | `gcs: service account key missing string field: <name>` |
| `private_key` PEM does not parse | `gcs: cannot parse private key: <msg>` |
| PEM parses to a non-RSA key | `gcs: service account key is not an RSA key` |

`token_uri` is optional, default `https://oauth2.googleapis.com/token`. Every other field (`type`, `project_id`, `private_key_id`, …) is ignored; in particular no `kid` is put in the JWT header.

---

## 2. Authentication: service account → OAuth bearer token (`gcs_auth`)

RFC 7523 JWT-bearer grant. No per-request signing: every storage request carries `Authorization: Bearer <access_token>`.

**JWT** (compact JWS, each part base64url **without padding**, JSON serialised compactly):
- header `{"alg":"RS256","typ":"JWT"}`
- claims `{"iss":<client_email>,"scope":"https://www.googleapis.com/auth/devstorage.full_control","aud":<token_uri>,"iat":<now>,"exp":<now+3600>}` — `now` = integer wall-clock epoch seconds.
- signature = RSASSA-PKCS1-v1_5 / SHA-256 over `b64(header) "." b64(claims)`. No RSA blinding: PKCS#1 v1.5 is deterministic, and signing needs no RNG (it happens before any TLS connection could seed one).

**Exchange**: `POST <token_uri>`, `Content-Type: application/x-www-form-urlencoded`, body `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=<jwt>` (form-encoded). 2xx → parse JSON: `access_token` (required string), `expires_in` (int or float; absent → 3600). Expiry = local wall clock at the answer + `expires_in`. Non-2xx → failure `gcs oauth: HTTP <code>: <body>`.

**Cache and refresh**: one cached `(token, expiry)` per store. A token is fresh while `now < expiry − 60 s` (margin for skew). A caller finding no fresh token takes a per-store mutex, re-checks, and only then POSTs — concurrent callers on a cold or stale cache share one exchange. There is no proactive refresh and no invalidation: a token is replaced only when it ages out.

**Where it runs**: the token is fetched *inside* each storage request's attempt, under that request's stall deadline (the header set is computed lazily per attempt). So a hung token endpoint is cut by the same 60 s stall timeout, a token failure is that request's failure (retried by the ladder, recorded on the store's health), and a retry re-reads the cache. The token POST itself uses its own one-off connection, not the store's pool.

**Scope `devstorage.full_control`**, not `read_write`: the XML API's bulk delete (§3.7) refuses a `read_write` token ("Provided scope(s) are not authorized") where the JSON single delete accepts it. A scope is a ceiling on the token, not a grant: what the account may do is its IAM role, `roles/storage.objectUser` on the bucket (objects only; no bucket or IAM administration). Never widen the role to `storage.admin` to compensate.

**Anonymous** (`serviceAccountKey` empty): no `Authorization` header at all. Against real GCS this yields 401/403 → Permanent on every verb.

---

## 3. Operations

Base `B` = endpoint (default `https://storage.googleapis.com`). `K` = the object key percent-encoded as **one path segment**: every byte outside `A–Z a–z 0–9 - . _ ~` becomes `%XX` (uppercase hex), `/` included (`tsync/d/.chunks/aabb-ccdd` → `tsync%2Fd%2F.chunks%2Faabb-ccdd`). The escaped form must reach the wire unchanged (an HTTP stack that normalises `%2F` back to `/` breaks every request). In query strings the key is sent as an ordinary percent-encoded query value; `+`, `&`, `#`, `%`, `=` and space must be escaped, `/` may be raw (the server decodes either way).

All verbs except bulk delete use the **JSON API**: it is what takes a bearer token uniformly, answers object metadata as JSON, and offers the `ifGenerationMatch` precondition. No request sets `userProject`, `x-goog-*` headers or `Accept-Encoding`.

| Contract op | Request | Success | Other answers |
|---|---|---|---|
| `put` | `POST B/upload/storage/v1/b/<bucket>/o?uploadType=media&name=<key>`, `Content-Type: application/octet-stream`, body = object bytes | 2xx (object resource JSON, ignored) | status mapping |
| `put_if_absent` | same + `&ifGenerationMatch=0` | 2xx → return the caller's own buffer (won) | **412** → lost: `get` the key and return the holder's body; other → status mapping |
| `get` | `GET B/storage/v1/b/<bucket>/o/K?alt=media` | 2xx → body | 404 → **Permanent** failure `get: HTTP 404: …`; other → status mapping |
| `get_opt` | same | 2xx → `Some body` | 404 → `None` |
| `get_range` | same + `Range: bytes=<offset>-<offset+length−1>` | 206 or 200 → body, then the contract's over-length check (a 200 whole-object answer to a range is caught there) | 404 → `None` |
| `head_opt` | `GET B/storage/v1/b/<bucket>/o/K` (metadata, not an HTTP HEAD) | 2xx → entry from JSON (§3.1) | 404 → `None` |
| `delete` | `DELETE B/storage/v1/b/<bucket>/o/K` | 2xx (204) → `true` | 404 → `false` (one request: GCS, unlike S3, says whether the object existed) |
| `delete_multi` | XML API, §3.7 | | |
| `copy` | `get src` then `put dst` (no server-side rewrite/copyTo) | | |
| `list_prefix` | §3.2 | | |

"Status mapping" = the shell's: 429 and 5xx Transient (retried inside the ladder), every other non-2xx Permanent `"<op>: HTTP <code>: <excerpt>"`. See [object-store-common.md](object-store-common.md).

Simple (`uploadType=media`) upload only: one request carries the whole body; no resumable or multipart upload exists in the driver (chunks are bounded by the chunk size, 8 MiB default). A single request is atomic at the service: readers see the old object or the new, never a partial one. The upload's JSON answer is not read.

### 3.1 Object metadata → `file_entry`

From an object resource (metadata GET and each listing item):
- `key` = the resource's `name` for listing items; for `head_opt` the requested key.
- `size` = `size`, which GCS sends as a **decimal string**; an integer is also accepted; anything else or unparsable → 0.
- `last_modified` = `updated` (RFC 3339, always UTC `…Z` on GCS) → epoch seconds via the proleptic-Gregorian days-from-civil formula; fractional seconds dropped; an offset suffix is ignored (not applied); unparsable → 0.
- `etag` = `etag` string (a base64 generation/metageneration token such as `CAE=`, not an MD5); empty/absent → none. It changes on every rewrite and on metadata updates, so it is a valid cache validator.

### 3.2 Listing

`GET B/storage/v1/b/<bucket>/o?prefix=<prefix>[&pageToken=<t>][&maxResults=<max_keys>]`. `prefix` is always sent (possibly empty). No `delimiter`: the listing is flat and recursive, as the contract wants; GCS returns names in lexicographic byte order. No `fields` projection (see §9.7).

Pagination: follow `nextPageToken` until absent. When `max_keys = n` is given, every page asks `maxResults=n` and paging stops as soon as ≥ n entries have been collected; the result is not truncated client-side (in practice ≤ n because the first page is capped at n). An absent `items` member is an empty page. Pages are accumulated in order; the result preserves the service's order.

A listing failure (any non-2xx after the ladder) fails the whole `list_prefix`; partial pages are discarded.

### 3.3 Ranges

`Range: bytes=a-b` with `b = offset + length − 1` (`length > 0` is the caller's precondition). GCS answers 206 with the slice, or with fewer bytes where the object ends. Both 200 and 206 are accepted; the length check is what separates a store that ignored the range. Known deviation: an `offset ≥ size` on a non-empty object is answered **416** by GCS, which maps to a Permanent failure rather than the contract's empty answer (§9.3).

### 3.4 Conditional write (`put_if_absent`)

`ifGenerationMatch=0` is GCS's "only if no live object has this name" precondition, evaluated atomically by the service: exactly one of N racing claimants gets 2xx, the others 412 (`conditionNotMet`). This is a real server-side precondition as the contract requires. The loser's `get` can itself fail: if the holder is deleted between the 412 and the GET, the GET's 404 surfaces as a Permanent `get` failure (the claim neither won nor learnt the winner).

A retry subtlety: if the claim's 2xx is lost (connection drop after commit) the ladder resends it, receives 412, and returns the body it reads back — byte-identical to its own, but a *different buffer*. Callers that tell winner from loser by buffer identity (the traffic counter) count it as a loss; the returned content is correct.

### 3.5 Deletes

Single `delete` needs no HEAD: GCS answers 404 for an absent object, which is the `false` answer.

### 3.6 Copy

Emulated (`get` + `put`): the bytes cross the client's link twice. Used for manifests and folder markers, not chunks. The JSON API's server-side `rewrite` is not used (§9.6).

### 3.7 Bulk delete over the XML API

The JSON API has no multi-object delete (only per-request batch envelopes); the XML API takes up to 1000 keys per request, against 1000 requests one at a time. Same bearer token.

- Keys are sent in request order, in batches of **1000**, batches strictly sequential.
- Request: `POST B/<bucket>?delete` (path-style, the XML API's own shape, so a custom endpoint keeps working), headers `Content-Type: application/xml`, `Authorization: Bearer …`, **`Content-MD5: base64(md5(body))`** (raw 16-byte digest, standard base64 with padding). The MD5 is mandatory: without it GCS answers 400 naming it — this is the one request whose body the service checks, since a truncated key list is worse than none.
- Body, exactly (no XML declaration, no namespace, no whitespace):
  `<Delete><Quiet>true</Quiet><Object><Key>k1</Key></Object>…<Object><Key>kn</Key></Object></Delete>`
  with each key XML-escaped: `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`, `"`→`&quot;`, `'`→`&apos;`; all other bytes raw (UTF-8 passes through). `Quiet` makes a clean batch answer an empty `<DeleteResult/>` rather than 1000 `<Deleted>` elements.
- Non-2xx → status mapping (e.g. 403 when the token lacks `full_control`, 400 on a missing MD5 → Permanent).
- 2xx → scan the body for every `<Error>` element and, after each, its first `<Code>…</Code>` and `<Key>…</Key>` texts (textual scan, no entity decoding). Errors with code `NoSuchKey` or `NotFound` are success (the contract's absent-codes). Any other → raise **Transient** `delete_multi: <k> of <n> object(s) not deleted; first was <key>: <code>`, `n` = this batch's size. Transient because the codes are per key while the status was 200, a retried batch only repeats idempotent deletes, and misclassifying as Permanent would strand objects on a copy nothing walks again.
- A failing batch stops the sequence: later batches are not sent; the caller's retry resends the whole list (idempotent).

### 3.8 Capabilities, watch, verify, discard, share URLs

All from the shell ([object-store-common.md](object-store-common.md)): `capabilities = {share_url = shareUrl; verified = true; chunk_size = max_concurrency = none}`, `fast_read = false`, `local_path = none`, `get_many = list_many = none`, `watch` = fixed 2 s sleep (GCS has no long-poll; Pub/Sub notifications are not consumed by the client), `verify_all` = 4096 request objects under `tsync/verify-jobs/<domain>/`, `discard` = one request object under `tsync/gc-jobs/<domain>/<run>/<name>`. `verified = true` and `discard = Queued` are true only if §8's verify function is deployed on the bucket.

---

## 4. Errors, retries, timeouts

| Cause | Class | Where handled |
|---|---|---|
| 2xx | success | — |
| 404 on `get_opt`/`get_range`/`head_opt`/`delete` | considered answer (`None`/`false`) | verb |
| 404 on `get` | Permanent | verb |
| 412 on `put_if_absent` | claim lost → read holder | verb |
| 429, 5xx (any verb, incl. XML delete) | Transient, retried by the ladder | shell/client |
| other 4xx (400, 401 expired/invalid token, 403 scope/IAM, 412 elsewhere, 416) | Permanent | verb |
| connection failure, redial, 60 s stall | Transient; stalls counted as timeouts on the store's health | client |
| token endpoint non-2xx, token JSON without `access_token`, network failure while minting | **Transient** (unrecognised failure), retried by the ladder | §9.1 |
| unparsable JSON in a metadata/listing answer | Transient (raised after the ladder, by the verb) | caller |
| bulk-delete per-key error (non-absent) | Transient | verb |
| `get_range` answer longer than asked | Permanent (`Backend_error`) | contract check |

**Stall timeout = 60 s** (the uplink budget's stall timeout, read once when the store is built): the time an answer may go without a byte arriving, not a total latency budget. Measured rationale (55ca68f8): over a 61 956-object mirror every stalled request was answered on its *first* retry — the connection was already dead when the request was sent — so a 300 s bound only idled the caller; stalls came in clusters killing the whole in-flight set at once. Tying it to the uplink budget keeps "window of bytes in flight" and "deadline" one setting.

---

## 5. Concurrency, memory, connections

- One pooled HTTP client per store: keep-alive, ≤ 32 sockets to the endpoint, idle sockets kept 60 s (shell). The token POST is outside the pool (≈ one new TLS connection per token lifetime, ~hourly).
- The driver itself has no concurrency limit; callers' pools bound work (batch reads 32, verifier 32, uplink governor for writes).
- Token refresh: single-flight per store (mutex + re-check), safe under preemption.
- Object bodies travel as off-heap byte buffers both ways; the request body is sent from the caller's buffer without a copy and must stay valid until answered (retries resend it). Responses are buffered whole in memory, so peak memory per request ≈ object size; metadata, listing pages and XML answers are read as text (small; a 1000-item listing page is a few hundred KB).
- Bulk delete builds one ≤ 1000-key body at a time.

---

## 6. Consistency assumptions from GCS

- Strong read-after-write and read-after-delete for objects, and strongly consistent object listing (GCS guarantees both). The contract's "an empty listing is a real answer" relies on it.
- Single-request uploads are atomic; `ifGenerationMatch=0` is atomic across concurrent writers.
- GCS rate-limits writes to one object name (≈ 1/s); the contract's 2 s watch interval and bodyless-job convergence assume it. A burst of writes to one name gets 429 → retried.
- Soft delete (bucket soft-delete policy) keeps deleted objects billable for the retention window; invisible to the driver.
- Storage class `ARCHIVE` (set by terraform's `archive_domains` lifecycle rule) stays online: reads work unchanged, at retrieval cost; no restore step exists or is needed (unlike S3 Glacier).
- Objects are stored with `Content-Type: application/octet-stream` and no `Content-Encoding`, so GCS never transcodes a download.

---

## 7. Test-pinned invariants

`tests/backends/gcs` (pure helpers, no network):
- key encoding: `tsync/d/.chunks/aabb-ccdd` → `tsync%2Fd%2F.chunks%2Faabb-ccdd`; `a-b_c.d~e` unchanged.
- RFC 3339: `1970-01-01T00:00:00.000Z` → 0; `2001-09-09T01:46:40Z` → 1 000 000 000; garbage → 0.
- listing page: string `size` read as int; `nextPageToken` returned; absent token → last page.
- bulk-delete body exactly as §3.7 for `["a/x";"a/y"]`; the five XML metacharacters escaped.
- bulk-delete answer: `<DeleteResult/>` → no errors; `(Code, Key)` pairs read for every `<Error>`; `NoSuchKey` is absent, `AccessDenied` is not.

`tests/conformance` against a real CI bucket (`TSYNC_CI_GCS_BUCKET`, `TSYNC_CI_GCS_SERVICE_ACCOUNT_KEY`; all under `tsync/ci-<run>/`, swept after): put/get/get_opt/head size/absent → None; copy; list sees both, `max_keys = 1` caps; 300-key batch reads answered whole in order; chunk-sized body round-trips and claim against it returns the holder; ranges at start/middle/last byte/past end, absent → None; 5 racing claims → one stored body and every claimant told it, later claim refused, free name returns own body; delete true then false; `verified = true`; awkward key names round-trip (`& < > " ' + %2F # ? space`, Unicode); a `delete_multi` of 1000+200+ mostly-absent keys spanning the batch boundary clears every live one; verify_all queues 4096 shard-named objects; discard request reads back with exactly its keys; with `TSYNC_CI_GCS_VERIFY_FUNCTION` set, the deployed function deletes a discarded chunk within 180 s. The suite exits non-zero when no store was configured.

`lambda/test_store_gcs.py`, `test_verify_gcs.py` (fake-gcs-server in CI): compose of 1, ≤ 32, and tiered > 32 sources with temp cleanup; missing source → 502 ShareError; signed URL passes SA email + access token (IAM SignBlob path); marker lifecycle; both Pub/Sub calling conventions decoded; delete jobs drop chunks and markers, refuse other domains; absent keys in `delete_many` are not refusals.

---

## 8. Server side on GCP (what differs from AWS)

The shared design — bucket-as-queue, per-chunk verification, gc-job consumption, share handler — is in [object-store-common.md](object-store-common.md) and [the store contract](../06-backends.md) §4.6 / appendix. GCP specifics (`terraform/modules/store-gcs`, `lambda/store_gcs.py`):

**Bucket** (when `create_bucket`): uniform bucket-level access, public access prevention enforced; lifecycle rules (only on a bucket terraform creates, since GCS lifecycle is a bucket property): `AbortIncompleteMultipartUpload` at age 1 day; per archived domain one `SetStorageClass` rule (`ARCHIVE` default) with `matches_prefix = ["tsync/<domain>/chunks/"]` and that domain's age. A pre-existing bucket is read, never modified.

**Client identity**: service account `tsync-client-<name>`, `roles/storage.objectUser` on the bucket, one JSON key; output `service_account_key` is the base64-decoded key JSON (what `serviceAccountKey` takes).

**Verify function** (Cloud Functions gen2, python313, entry `gcp_verify` in `verify.py`):
- Trigger: a **storage notification → Pub/Sub topic** (`OBJECT_FINALIZE`, `payload_format = JSON_API_V1`, `object_name_prefix = "tsync/"`), consumed via an Eventarc Pub/Sub trigger. Not an Eventarc storage trigger, which has no prefix filter and would fire on every manifest and journal write. The GCS project service agent must be granted `pubsub.publisher` on the topic first.
- The object name is the Pub/Sub message attribute `objectId`; both CloudEvent (`event.data.message.attributes`) and background (`event.attributes`) conventions are accepted.
- `retry_policy = DO_NOT_RETRY` (a function that cannot read would otherwise retry every chunk forever; a dropped event costs one missed marker), `max_instance_count = 32` (a whole-store sweep makes 4096 requests deliverable at once), 512 MB, 120 s.
- IAM: `objectViewer` bucket-wide (list cannot be prefix-scoped by a condition); `objectUser` conditioned on `resource.name.startsWith(".../objects/tsync/corrupted/" | "tsync/verify-jobs/" | "tsync/gc-jobs/")`; a custom role `tsyncChunkDeleter_<name>` = `storage.objects.delete` only, conditioned by `resource.name.extract(".../objects/tsync/{domain}/chunks/") != ""` (the only condition shape that spans a domain in the middle; fails closed); `eventarc.eventReceiver` on the project; `run.invoker` on its own Cloud Run service for the trigger's account (without it events arrive and are rejected, which looks like an unwired trigger).
- Its own marker writes re-trigger it and terminate (a marker has no marker key).
- Reads a chunk whole (`download_as_bytes`), not in slices as on AWS.
- Server-side bulk delete uses the JSON **batch** endpoint, 100 sub-requests per call; a batch that fails as a whole is redone key by key (parallel) to learn which keys refused; `NotFound` is not a refusal.

**Share function** (gen2, entry `gcp_handler` in `handler.py`, `allUsers` `run.invoker`): adapts the Flask request (`path`, `args`) to the AWS-shaped event. Own SA with `objectViewer` bucket-wide and `objectUser` conditioned on `tsync/shares/`. Assembles files with GCS **compose** (≤ 32 sources per call; more are composed in tiers through temporary objects under the shares cache prefix, each tier's groups concurrently, temps deleted afterwards). Download links are **V4 signed URLs** (TTL `presign_ttl`, 600 s) signed through the IAM SignBlob API with the runtime's SA email and access token — the SA has `iam.serviceAccountTokenCreator` on itself, since the runtime has no private key. `/tmp` is RAM on gen2, so folder zips are bounded by `memory_mb` (2048). Output `share_url` = function URL without trailing `/`, or `https://<custom_domain>`; null when `deploy_share = false`.

---

## 9. Open questions / known weaknesses

1. **OAuth failures are Transient.** A revoked key or `invalid_grant` (e.g. clock skew) is retried through the full ladder and marks the link lost, where a 400/401 from the token endpoint is a considered answer.
2. **No token invalidation on 401.** A token revoked before expiry keeps being sent until it ages out (≤ 1 h); each request fails Permanent meanwhile.
3. **Range past the end** (`offset ≥ size`): GCS 416 → Permanent failure, not the contract's empty answer. Not covered by conformance (which asks for a range *reaching* past the end, not starting there).
4. **Bulk-delete XML**: keys containing bytes illegal in XML 1.0 (most C0 controls) cannot be expressed and fail the batch (400 → Permanent); the answer's `<Key>` is not entity-decoded (used only in the message).
5. **First failed bulk batch aborts the rest** rather than reporting all; resend is idempotent, so only cost.
6. **Copy is get + put**, not `rewrite`; cheap for manifests, would be costly if ever used for chunks.
7. **Listing asks for the full object resource.** An unmerged change (branch `json-listing`, a02b9a4d) adds `fields=items(name,size,updated),nextPageToken`: half a million objects shrink from 483 MB of JSON to ~70 MB. As written it drops `etag`, which would silently turn every listed etag into none; any adoption must include `etag`.
8. **JWT `iat` and token expiry use the wall clock**: a local clock far off Google's makes minting fail (`invalid_grant`); a wall-clock jump can make a cached token look fresh after it expired (then 401s until the margin passes).
9. **No emulator roundtrip in the unit suite**: HTTP behaviour (encoding on the wire, the XML delete, preconditions) is proven only by the credentialed conformance run.
10. Verify function's read grant is bucket-wide (terraform comment: narrow once confirmed against a real bucket).
