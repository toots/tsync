# Backend driver: `gcs` (Google Cloud Storage)

How the `gcs` driver realises [the store contract](../06-backends.md). What every bucket answers the same way (capabilities, watch, verification, discard, the transport, the status mapping, the bucket-side function) is in [object-store-common.md](object-store-common.md). This file covers what is Google-specific.

Implementation notes: [../ocaml/backends/gcs.md](../ocaml/backends/gcs.md).

---

## 1. Configuration

The backend object's generic fields are in [05-ops-config.md](../05-ops-config.md). Driver fields, all strings. An empty string and an absent field mean the same thing:

| Field | Secret | Default | Meaning / validation |
|---|---|---|---|
| `bucket` | no | required | Bucket name. It MUST be non-empty and MUST NOT contain `/`. It is percent-encoded as one path segment. |
| `serviceAccountKey` | yes | `""` | The text of a service-account JSON key (not a path). Empty → anonymous requests, accepted only with an `endpoint` on a loopback host (an emulator). |
| `endpoint` | no | `https://storage.googleapis.com` | Scheme, host and optional port. `http://` is accepted only for a loopback host. One trailing `/` is trimmed. It changes the storage base only: tokens are still minted at the key's `token_uri`. |
| `shareUrl` | no | none | Base URL of the share function deployed on this bucket. |

### 1.1 Service-account key

The key is parsed when the store is built. Any failure refuses the configuration with a message naming it:

| Condition | Message |
|---|---|
| not JSON | `gcs: service account key is not valid JSON` |
| `client_email` or `private_key` missing or not a string | `gcs: service account key missing string field: <name>` |
| `private_key` PEM does not parse | `gcs: cannot parse private key: <reason>` |
| not an RSA key | `gcs: service account key is not an RSA key` |

`token_uri` is optional, and defaults to `https://oauth2.googleapis.com/token`. Other fields are ignored.

---

## 2. Authentication: service account → bearer token

This is the RFC 7523 JWT-bearer grant. Every storage request carries `Authorization: Bearer <access_token>`.

**JWT.** A compact JWS, each part base64url without padding:

- header `{"alg":"RS256","typ":"JWT"}`;
- claims `{"iss":<client_email>,"scope":"https://www.googleapis.com/auth/devstorage.full_control","aud":<token_uri>,"iat":<now>,"exp":<now+3600>}`, where `now` is the wall clock in integer epoch seconds (the claims are compared across hosts);
- signature RSASSA-PKCS1-v1_5 with SHA-256. It is deterministic and needs no random source.

**Exchange.** `POST <token_uri>`, form-encoded, `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=<jwt>`. A 2xx answer carries `access_token` (required) and `expires_in` (seconds; absent means 3600).

**Token endpoint answers** are classified by [failure-model §4.2](../algorithms/failure-model.md#42-http-object-stores): a 400, 401 or 403 whose `error` is `invalid_grant`, `invalid_client`, `unauthorized_client` or `access_denied` means the grant is invalid or revoked (REFUSED, with the reason: the key was revoked or disabled, or the local clock is too far off for `iat`); 429 and 503 are LOAD; a network failure, a stall, or a 2xx without `access_token` is TRANSIENT/LINK.

A token failure is the failure of the storage attempt that needed the token. It travels with its own kind: a revoked key is REFUSED, attempted once, and counts for the link, not against it.

**Cache.**

- One cached token per store. It is fresh until `expires_in − TOKEN_MARGIN` (recommended 60 s) after it was received, measured on the monotonic clock, so a wall-clock step never makes an expired token look fresh.
- A caller that finds no fresh token takes the store's minting slot, re-checks the cache, and only then mints: concurrent callers share one exchange.
- A mint that fails is not cached. Each waiter proceeds to its own attempt.

**Where it runs.** The token is obtained inside each storage attempt, under that attempt's stall detector: a hung token endpoint is cut like any silent request. The token request uses its own connection, not the storage pool.

**401 from storage.** A 401 on a storage request means the token was rejected:

1. Drop the cached token if it is still the one used.
2. Mint a fresh one, and repeat the request once within the same attempt.
3. A second 401 is REFUSED.

A key revoked before its token expired is therefore noticed on the next request, not up to an hour later.

**Scope.** `devstorage.full_control`, because the XML API's bulk delete refuses a `read_write` token. A scope is a ceiling on the token, not a grant: what the account may do is its role on the bucket, objects only. The role MUST NOT be widened to compensate for a scope.

---

## 3. Operations

- **Base.** `B` is the endpoint.
- **Key encoding.** `K` is the object key percent-encoded as **one path segment**: every byte outside `A–Z a–z 0–9 - . _ ~` becomes `%XX` in uppercase hex, `/` included. The escaped form MUST reach the wire unchanged: an HTTP stack that normalises `%2F` back to `/` breaks every request.
- **Query values.** Keys in query strings are percent-encoded query values, with at least `+ & # % = ;` and space escaped.
- **APIs.** Every verb except bulk delete uses the JSON API.

| Contract op | Request | Success | Other answers |
|---|---|---|---|
| `put` | `POST B/upload/storage/v1/b/<bucket>/o?uploadType=media&name=<key>`, `Content-Type: application/octet-stream` | 2xx | mapping |
| `put_if_absent` | the same plus `&ifGenerationMatch=0` | 2xx → `Won` | 412 → read the holder, answer `Held`, or `Won` if it is byte-identical; other → mapping |
| `get` / `get_opt` | `GET B/storage/v1/b/<bucket>/o/K?alt=media` | 2xx → body | 404 → ABSENT / `none` |
| `get_range` | the same plus `Range: bytes=<off>-<off+len−1>` | 206, or 200 when the whole object fits in the range → body, checked against `Content-Range` | 404 → `none`; 416 → empty body; an answer longer than `len` → CORRUPT |
| `head_opt` | `GET B/storage/v1/b/<bucket>/o/K` (metadata) | entry (§3.1) | 404 → `none` |
| `delete` | `DELETE B/storage/v1/b/<bucket>/o/K` | 2xx → `true` | 404 → `false` (GCS says whether the object existed: one request) |
| `delete_multi` | XML API, §3.3 | | |
| `copy` | server-side `POST B/storage/v1/b/<bucket>/o/<src>/rewriteTo/b/<bucket>/o/<dst>` (repeated with `rewriteToken` until done), or `get` + `put` | | a missing source → ABSENT |
| `list_prefix` | §3.2 | | |

- **Uploads.** Simple uploads only: one request carries the whole body, which is atomic at the service. Chunks are bounded by the chunk size.
- **Mapping.** "Mapping" is [failure-model §4.2](../algorithms/failure-model.md#42-http-object-stores), plus the 401 rule of §2.

### 3.1 Object metadata → entry

- `key`: the resource's `name`.
- `size`: GCS sends a decimal string, and an integer is also accepted. Anything else makes the answer CORRUPT.
- `last_modified`: `updated` (RFC 3339), with the fraction kept and any offset applied. Unparseable → CORRUPT.
- `etag`: the resource's `etag`. It changes on every rewrite, so it is a valid cache validator.

### 3.2 Listing

- `GET B/storage/v1/b/<bucket>/o?prefix=<prefix>[&pageToken=<t>][&maxResults=<n>]`, with no delimiter.
- A listing SHOULD ask only for the fields it uses: `fields=items(name,size,updated,etag),nextPageToken`. That shrinks large listings several times over. It MUST keep `etag`.
- Follow `nextPageToken` until absent, or until `max_keys` entries are held. An absent `items` is an empty page. A failure on any page fails the listing.

### 3.3 Bulk delete over the XML API

The JSON API has no multi-object delete. The XML API takes up to 1000 keys per request, with the same bearer token.

- Pages of at most 1000 keys, in order, sequentially.
- `POST B/<bucket>?delete` (path-style), with `Content-Type: application/xml` and `Content-MD5: base64(md5(body))`. The MD5 is mandatory: without it GCS answers 400.
- The body is exactly `<Delete><Quiet>true</Quiet><Object><Key>k1</Key></Object>…</Delete>`, with each key XML-escaped (`&amp; &lt; &gt; &quot; &apos;`). A key holding a character XML 1.0 cannot carry is deleted with a single DELETE instead.
- A 2xx answer lists only refusals. Each `<Error>`'s `Code` and `Key` (entity-decoded) are mapped per [failure-model §4.2](../algorithms/failure-model.md#42-http-object-stores).

### 3.4 Shell-supplied members

Capabilities, watch, verification, discard, share URL and the absence of `get_many` and `list_many` are all from [object-store-common.md](object-store-common.md).

---

## 4. Service consistency relied on

- Strong read-after-write, read-after-delete and list-after-write.
- Single-request uploads are atomic, and `ifGenerationMatch=0` is atomic across concurrent writers.
- GCS rate-limits writes to one object name (about one per second). A burst gets 429, which is LOAD and retried.
- The `ARCHIVE` storage class stays online: reads work unchanged, at retrieval cost.
- Objects are stored as `application/octet-stream` with no content encoding, so GCS never transcodes a download.

---

## 5. Server side on GCP

The shared design and the function's required behaviour are in [object-store-common §5](object-store-common.md#5-the-verify-function). GCP specifics:

- **Trigger.** A storage notification (object finalize, JSON payload, prefix `tsync/`) onto a Pub/Sub topic, consumed by the function through a message-published trigger with no retries. The storage service agent needs publish rights on the topic. The trigger's identity needs invoke rights on the function, without which events arrive and are rejected, which looks like an unwired trigger.
- **Event shape.** The object name is the message attribute `objectId`. Both the CloudEvent (`data.message.attributes`) and the background (`attributes`) conventions are accepted.
- **Grants.** Read on the bucket (bucket-wide, since listing cannot be conditioned by prefix). Create and delete conditioned on `tsync/corrupted/`, `tsync/verify-jobs/` and `tsync/gc-jobs/`. Delete-only on `tsync/{domain}/chunks/`, through the one condition shape that spans a domain in the middle.
- **Bulk delete** in the function uses the JSON batch endpoint, 100 sub-requests per call. A batch that fails as a whole is redone key by key to learn which keys refused.

---

## 6. Conformance

Beyond [06 §10](../06-backends.md#10-conformance) and [object-store-common §8](object-store-common.md#8-conformance):

- Key encoding: `tsync/d/.chunks/aabb-ccdd` → `tsync%2Fd%2F.chunks%2Faabb-ccdd`; `a-b_c.d~e` unchanged.
- RFC 3339: `1970-01-01T00:00:00.000Z` → 0; `2001-09-09T01:46:40Z` → 1 000 000 000; an offset is applied; garbage makes the answer CORRUPT.
- A listing page reads a string `size`, returns `nextPageToken`, and treats an absent token as the last page; a projected listing keeps `etag`.
- The bulk-delete body for `["a/x","a/y"]` is exactly as §3.3, with the five XML metacharacters escaped. `<DeleteResult/>` has no refusals, `NoSuchKey` is absent, and `AccessDenied` is REFUSED.
- A token endpoint answering `invalid_grant` makes the storage attempt REFUSED after one attempt, without tripping the member's health. A storage 401 re-mints once and retries once.
- A range starting at or past the end answers an empty body.
- Against a real bucket: 300-key batch reads are answered whole and in order; a chunk-sized holder is returned to a losing claim; a `delete_multi` spanning the page boundary clears every live key; with the function deployed, a discarded chunk is deleted within the probe wait.
