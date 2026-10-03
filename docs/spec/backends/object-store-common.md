# Object stores: the shared shell, transport and bucket-side functions

What the `s3` and `gcs` drivers share:

- the shell that turns a handful of bucket verbs into the full [store contract](../06-backends.md);
- the transport rules and the probe that confirms a bucket's function;
- the bucket-side functions deployed beside a bucket: the verify function, triggered by the bucket's own object-created notifications, which checks chunks and executes whole-store verification and collection delete requests ("the bucket is the queue"); and the share function, which serves share links.

The request objects and the function's handling of them are backend formats: existing deployments keep working, and this file specifies what every deployment MUST do. Byte formats of request and marker objects are [02 §2.13](../02-remote-model.md#213-corruption-marker-verify-job-discard-job).

Per-driver wire details: [s3.md](s3.md), [gcs.md](gcs.md). Implementation notes: [../ocaml/backends/s3.md](../ocaml/backends/s3.md).

---

## 1. Layering

```
contract operations (keys)          ← composite, domain logic
        │  shell: everything bucket-generic
        ▼
bucket verbs                        ← s3 / gcs driver: wire, authentication, status interpretation
        │
        ▼
HTTP (01 §10)                       ← pooled connections, stall detector; admission per attempt (06 §6)
```

A driver supplies only the verbs of §2.1, its share URL and its breaker cell. The shell answers everything else identically for every bucket.

## 2. The shell

### 2.1 Verbs a driver supplies

| Verb | Obligation beyond the contract operation it backs |
|---|---|
| `put(key, data)` | One request; atomic at the service. |
| `put_if_absent(key, data)` | One request with the service's "no live object" precondition. Precondition failed → read the holder and answer `Held`, or `Won` when the holder is byte-identical ([06 §3.3](../06-backends.md#33-put_if_absent)). |
| `put_if_unchanged(key, data, expected)` | One request with the service's precondition on the expected version, or on no live object for `none`. Precondition failed → `Changed` ([06 §3.11](../06-backends.md#311-put_if_unchanged)). |
| `get`, `get_opt` | 404 → ABSENT or `none`. |
| `get_range(key, offset, length)` | The service's range read (`Range: bytes=offset-(offset+length−1)`). 416 (range not satisfiable) on an existing object → an empty body. The answer is checked against the requested range and the service's reported `Content-Range`. |
| `head_opt` | `{key, size, last_modified, etag, checksum}`, the checksum the service keeps where the driver's file says it keeps one. |
| `delete` | Honest existence result. |
| `delete_multi` | Pages of at most 1000 keys, sent in order, stopping at the first failed page; per-key codes mapped per [failure-model §4.2](../algorithms/failure-model.md#42-http-object-stores). |
| `copy(src, dst)` | Either a server-side copy, or `get` then `put`. Either way every body sent upstream is admitted. |
| `list(prefix, max_keys?)` | Entries as `head_opt`'s. Flat and recursive; follows pagination to the end, or until `max_keys` entries are held; the shell sorts by key, truncates to `max_keys`, and omits names that are not valid keys. |
| `share_url()` | From configuration. |

### 2.2 What the shell answers itself

| Contract member | Shell behaviour | Why |
|---|---|---|
| `fast_read` | `false` | A range costs the same round trip as a whole object. |
| `local_path` | none | No filesystem access. |
| `get_many`, `list_many` | not declared | No native multi-read. The generic batcher fans out `get_opt`. |
| `compute_checksum(key, algo)` | `head_opt`; the entry's checksum when it is of `algo`, else `get` and hash the body | The service's checksum costs one metadata request, never a retrieval; the body moves only when the service keeps none. |
| `locality` | `Remote` | Every byte is behind the service. |
| `watch(key, last_seen)` | sleep WATCH_INTERVAL, then return | Buckets offer no change notification a client can wait on. The caller re-reads. |
| `capabilities(prefix)` | `{share_url = driver's; chunk_size = none; max_concurrency = none; verified = function_confirmed}` | `verified` only once the function is confirmed deployed (§3). |
| `bucket_functions` | `true` | Every bucket can run the function; the domain owner confirms one is deployed (§3) before writing discard requests, and a request is durable once its `put` returns. |

Request objects are written through the driver's `put`, and so are admitted and counted like any upload.

## 3. Confirming the bucket-side function

A store claims `verified` only after it has evidence that the verify function is deployed on its bucket, and a domain owner writes verify and discard requests to it only after the same evidence. Whole-store verification is one empty verify request per shard (4096), every shard and not only populated ones: learning which exist costs more listings than empty requests cost invocations. Every object-store driver SHOULD support the function wherever its provider can run one: without it, a collection deletes each chunk with its own request ([06 §3.8](../06-backends.md#38-optional-operations)), and once it is confirmed a collection's deletions MUST use it. A bucket without it (a manual setup, an S3-compatible provider, a notification the operator never wired) otherwise claims checks nobody runs and accepts deletes nobody executes.

**The probe.** An empty collection delete request, at a reserved run name of its own, `0` followed by twelve random hex digits (`<probe>` below), and shard `000`:

1. Put `tsync/gc-jobs/<domain>/<probe>/000` with an empty body. An empty request names no keys, so a deployed function deletes nothing and removes the request.
2. Read the request's metadata every PROBE_POLL until it is gone, for at most FUNCTION_PROBE_WAIT.
3. Gone → the function is confirmed. Still there → it is not: delete the request and record the store as unconfirmed.

**Rules:**

- The probe runs only on a store the domain writes (a main or a copy), only with the write guard satisfied ([replication §4.9](../algorithms/replication.md#49-write-guard)), and at most once per FUNCTION_PROBE_VALIDITY per store and domain, except that a confirmation in its last day is renewed by a fresh probe, so a running owner never sees one lapse.
- One probe of a store runs at a time in a process, and a probe asked for while one runs answers with its outcome. Clients sharing a bucket probe it independently: each probe has its own request, so one that gives up deletes only its own, and no other reads that deletion as consumption. Nothing but its prober removes a probe request: re-delivery ([gc §5.7](../algorithms/gc.md)) skips reserved run names.
- The outcome, with its time, is saved in the owner's local state. Until a confirmation younger than FUNCTION_PROBE_VALIDITY is known, the store answers as unconfirmed.
- A reserved run name is older than any real collection, so it never collides with a real request, and a client listing pending requests sees it only for as long as it is really pending.
- The probe proves that the function is deployed and triggered for objects under `tsync/`. A deployment MUST trigger it for every object created under `tsync/` (§5.1), so the same evidence covers chunk checks and verification requests.

## 4. Transport

- The HTTP discipline is [01 §10](../01-core.md#10-http-request-discipline): pooled keep-alive connections, one redial for a connection that proved dead before the request left, a stall timeout on the monotonic clock, credentials computed inside it.
- **Stall timeout** is STALL_TIMEOUT (recommended 60 s). It MUST be at least the uplink governor's, since the in-flight window is sized from it ([algorithms/uplink-governor.md](../algorithms/uplink-governor.md)). Every stall is counted on the store's timeout tally.
- **Addresses.** Both IPv4 and IPv6 addresses of the endpoint are tried.
- **TLS** as [security §9](../algorithms/security-model.md#9-tls): verified HTTPS to every non-loopback endpoint.
- **Failure kinds** as [failure-model §4.2](../algorithms/failure-model.md#42-http-object-stores), by status and service error code, never by whether an error body parses. A LOAD failure carries the answer's `Retry-After`, which the ladder honours ([01 §7](../01-core.md#7-retry-ladder)).
- **Verb pattern.** Every verb is one run of the retry ladder with the store's breaker cell. Inside an attempt, a TRANSIENT outcome is raised so the ladder retries it; anything else is returned for the verb to interpret (404 by verb, 412 in a claim). Per-key bulk-delete refusals are raised after the ladder, not retried inside it: the caller decides whether to repeat the batch.

## 5. The verify function

One function per bucket, triggered for every object created under `tsync/`. What a deployment MUST do:

### 5.1 Trigger and dispatch

- The trigger fires for every object created under `tsync/`. The function decides what each object is, in this order:
  1. a collection delete request (a discard job, per [02 §2.13](../02-remote-model.md#213-corruption-marker-verify-job-discard-job));
  2. a verification request (a verify job, per the same section);
  3. a chunk: the key has a corruption-marker key;
  4. anything else: ignored, reading nothing.
- Events are at-least-once and unordered. A failed invocation is not retried by the trigger: a function that cannot read would otherwise retry every chunk forever. A missed chunk check is closed by the next whole-store verification. A missed request stays in the bucket, visible and re-deliverable.
- On a trigger that batches several objects in one event, each object is handled on its own, and one failure never abandons the rest.

### 5.2 Per-chunk check

1. Derive the marker key. None → nothing is read.
2. **Delete the marker first.**
3. Stream the body once through the chunk hash of [01 §3](../01-core.md#3-content-hashing-chunking-and-chunk-keys) and a byte count.
4. The hash equals the key's leaf → clean. Otherwise put the marker with `computed`, `size` and `at` ([02 §2.13](../02-remote-model.md#213-corruption-marker-verify-job-discard-job)).

Marker first because events are at-least-once and unordered: a stale "clean" over bad bytes is unrecoverable, while a spurious marker over good bytes costs one rewrite. The function's own marker writes trigger it again, and a marker has no marker key, so the loop ends.

### 5.3 Verification request

List the shard, run §5.2 on each chunk, then delete the request, **last**: a run that dies leaves the request in place as evidence, and re-queueing retries it.

### 5.4 Collection delete request

1. Read the body. Absent (a redelivery of a consumed request) → nothing to do.
2. Keep the keys that have a marker key **and** start with `tsync/<d>/chunks/`, so that one domain's request cannot reach another's. Log the others, which are never retried.
3. List `tsync/corrupted/<d>/` once, and keep the markers that accuse a kept key.
4. Bulk-delete the kept keys and those markers. Absent keys are success. Any other refusal → log it and **leave the request in place**. Otherwise delete the request, **last**.

The client puts back any deleted chunk the main still holds once the request is gone ([replication §4.8](../algorithms/replication.md#48-deletions-on-copies-outside-the-worker)), so the function needs no knowledge of the main.

**Re-delivery** of an outstanding request (rewriting it with only the keys still absent from the collected main, or deleting it when none remain) is [gc §5.7](../algorithms/gc.md#57-deletion-on-copies); a rewrite raises a fresh notification.

### 5.5 Deployment requirements

- **Trigger:** object created, prefix `tsync/`, covering chunks, verification requests and collection delete requests.
- **Least privilege.** The function may read chunks, and create and delete markers. It may read and delete requests, and delete chunks. It may list the bucket (bucket-wide only where the provider cannot condition listing by prefix). It MUST NOT be able to write a chunk: a wrong body would be silent, a wrong delete at least visible. The client's credentials are scoped to the bucket's objects, with no bucket or permission administration.
- **Why markers and requests sit beside the domains** (`tsync/corrupted/<d>/…` rather than `tsync/<d>/corrupted/…`): notification filters and permission conditions take one literal prefix, so one prefix must cover every domain.
- **Bucket settings.** Public access blocked; plain-HTTP requests denied where the provider allows it.
- **Lifecycle.** Incomplete multipart uploads are aborted after one day. Archival transitions MAY apply to `tsync/<d>/chunks/` only, and only to a storage class that reads online. No lifecycle rule may expire anything under `tsync/gc-jobs/`: an expired request is a silent leak.
- **Invocation bound** sized for one shard walk or one delete request (recommended 120 s).

## 6. The share function

A function deployed beside a bucket MAY serve the bucket's share links; its URL is the driver's `shareUrl`, and a link is `<shareUrl>/<token>`. It is a share server, and every rule of [security §6](../algorithms/security-model.md#6-share-capabilities) and [§13](../algorithms/security-model.md#13-html-and-browser-facing-output) applies to it. In particular:

- It serves a manifest only if it is valid ([data-model/backend §2.18](../data-model/backend.md#218-share)), and its `key` or `folderId` lies within the manifest's `domain`.
- It resolves every name inside a folder share through that domain's folder namespaces, applying the anchor rule ([data-model/backend §6.3](../data-model/backend.md#63-settling-the-anchor-decides)), and stops serving a folder share once the folder is trashed.
- Pages are built by single-pass, escaped templating.
- Downloads are redirects to presigned URLs that expire within the share presign TTL and never after the share.
- A token-keyed cached archive is rebuilt once older than `share_archive_max_age` ([data-model/backend §2.19](../data-model/backend.md#219-share-artifact-cache)).
- Its grants are read on the bucket, and create and delete on the share cache only.

## 7. Parameters

| Parameter | Recommended | Meaning |
|---|---|---|
| WATCH_INTERVAL | 2 s | Shell watch sleep ([06 §3.7](../06-backends.md#37-watch)) |
| STALL_TIMEOUT | 60 s (≥ the governor's) | Silence before an attempt fails |
| FUNCTION_PROBE_WAIT | 180 s | How long a probe request may take to be consumed |
| PROBE_POLL | 5 s | Probe request polling period |
| FUNCTION_PROBE_VALIDITY | 7 days | Age after which a confirmation is renewed |

## 8. Conformance

- The chunk hash computed by the function equals the client's on the golden vectors; a streamed hash equals the one-shot hash, and the size comes from the same pass.
- Request keys parse, and malformed ones are refused. A request is never mistaken for a chunk.
- Marker lifecycle: a good chunk gets no marker; a scrambled one is filed with the hash computed; a good rewrite clears it; a manifest is never read; a marker never earns one; domains are separated; large bodies are handled.
- A verification request sweeps its shard and is then removed; an empty shard's request is removed.
- A delete request drops its chunks and their markers, refuses keys of other domains and non-chunks, and a redelivery is a no-op; a refused key leaves the request in place.
- An empty delete request is consumed without deleting anything (the probe).
- A store whose bucket has no function answers `verified = false`, its owner records it unconfirmed and sends it no verify or discard request, and no probe request is left behind; with the function, it answers `true`, a whole-store verification writes 4096 shard-named requests, and a discard request carries exactly its keys.
- The share function refuses a manifest naming another domain's key or folder, stops serving a trashed folder, escapes a folder name holding `</script>`, and rebuilds an archive older than `share_archive_max_age`.
- Transport: a slow but flowing answer is not a stall; a stall is measured from the last byte; 429 and throttling 503 are LOAD, other 5xx LINK, 403 REFUSED, whatever the error body.
