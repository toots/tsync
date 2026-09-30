# Object stores: the shared shell, HTTP client and server-side function

What the `s3` and `gcs` drivers share: the shell that turns a handful of bucket verbs into the full [store contract](../06-backends.md), the pooled stall-timeout HTTP client, the retry pattern every verb follows, and the server-side half — one function per bucket, triggered by the bucket's own object-created notification, that verifies chunks and executes whole-store verify and GC delete requests ("the bucket is the queue"), deployed by the terraform in `terraform/`.

Per-driver wire details: [s3.md](s3.md), [gcs.md](gcs.md). OCaml notes: [../ocaml/backends/s3.md § Object-store common](../ocaml/backends/s3.md#object-store-common).

Code: `lib/backends/api/object_store.ml` (shell), `verifier.ml`, `discard_job.ml`, `corruption_marker.ml`, `lib/core/chunk_layout.ml` (key layout), `lib/core/http_client.ml` + `lib/lwt/core/http_client_lwt.ml`, `lambda/verify.py`, `lambda/store_aws.py`, `lambda/store_gcs.py`, `terraform/modules/store-{s3,gcs}/verify.tf`, `terraform/ci/`.

---

## 1. Layering

```
contract ops (Stored_key)          ← composite, domain logic
        │  Object-store shell: key → string, everything bucket-generic
        ▼
bucket verbs (string keys)         ← s3 / gcs driver: wire, auth, error mapping
        │
        ▼
HTTP (gcs: shared pooled client · s3: the aws-s3 library's own pool)
```

A driver supplies only the verbs of §2.1 plus its share URL and its `Health.t`. It never implements `watch`, `capabilities`, `verify_all`, `discard`, `get_many`, `list_many`, `fast_read` or `local_path`: the shell answers those identically for every bucket.

## 2. The shell

### 2.1 Verbs a driver supplies

All keys are plain strings (the shell renders `Stored_key` with its string form), bodies are off-heap byte buffers.

| Verb | Obligation (beyond the contract op it backs) |
|---|---|
| `put(key, data)` | Single atomic write. `data` stays owned by the caller and must remain valid until the call returns (retries resend it). |
| `put_if_absent(key, data) → body` | Server-side precondition (S3 `If-None-Match: *`, GCS `ifGenerationMatch=0`). Won → return `data` itself (same buffer); lost (412) → read the key and return the holder's body. |
| `get(key) → body` | Absent → Permanent failure. |
| `get_opt(key) → body?` | Absent (404) → none. |
| `get_range(key, offset, length) → body?` | Service range read; the answer passed through `checked_range` (longer than `length` → `Backend_error`). Absent → none. |
| `head_opt(key) → entry?` | `{key, size, last_modified, etag}`. |
| `delete(key) → existed` | Whether an object was there. |
| `delete_multi(keys)` | Pages at the service cap (1000 for both); absent keys are success; any other per-key error inside a 2xx answer → raise Transient. |
| `copy(src, dst)` | Both drivers: `get` + `put`. |
| `list_all(prefix, max_keys?) → entries` | Flat, recursive, service order; follows pagination; stops once `≥ max_keys` collected. |
| `share_url() → string?` | From config. |
| `health() → Health.t` | One per store instance. |

### 2.2 What the shell answers itself

| Contract member | Shell behaviour | Why |
|---|---|---|
| `fast_read` | `false` | A range costs the same round trip as a whole object; reading more than asked only spends bandwidth. |
| `local_path` | none | No filesystem access. |
| `get_many`, `list_many` | none | No native multi-GET; `batched_get_many` fans out `get_opt` through its process-wide pool of 32. |
| `watch(key, last_seen)` | sleep `default_watch_interval` = 2 s, then return | Buckets have no change notification a client can wait on. The caller re-reads the cursor and compares. Cost: one GET per 2 s per watched domain per process. |
| `capabilities(prefix)` | `{share_url = driver's; chunk_size = none; max_concurrency = none; verified = true}` | No chunk size or concurrency opinion (limited by network and the service, neither measurable here). `verified = true` is **asserted**, not probed: the function that checks each chunk is deployed by the same terraform that creates the bucket (§7). |
| `verify_all(chunk_prefix)` | 4096 empty PUTs (§3.1), 32 in flight, progress logged at info every 256 and at the last; returns `Queued 4096` | Every shard, not the populated ones: learning which exist costs more listings than empty jobs cost invocations. No bulk put exists on either service. |
| `discard(chunk_prefix, run, name, keys)` | One PUT of the GC job object (§3.2); returns `Queued` once the PUT succeeded | Taken as given, like `verified`. A request nothing consumes is visible through `tsync gc --status` and re-delivered by `tsync gc --retry-jobs`. |

The job PUTs go through the driver's `put` verb directly, beneath the traffic wrapper: they are neither counted nor gated by the uplink governor. The same holds for the `get`+`put` inside `copy`.

## 3. Job and marker objects (the queue's wire format)

Key layout ([06 §2.1](../06-backends.md)); `<d>` = domain name, `<s>` = 3 lowercase hex chars (`000`…`fff`, 4096 shards) = first 3 chars of the chunk key, chunk key = `<16 hex>-<16 hex>`.

### 3.1 Verify job

- Key: `tsync/verify-jobs/<d>/<s>`. Body: empty (0 bytes).
- Meaning: "check every chunk under `tsync/<d>/chunks/<s>/`".
- Written by `verify_all`; consumed (deleted) by the function after the shard was walked.

### 3.2 GC delete job

- Key: `tsync/gc-jobs/<d>/<run>/<name>`. `<run>` = the collection's run name, `sprintf "%013.0f" (start_time × 1000)` (milliseconds, zero-padded to 13 digits). `<name>` = the shard the flush belongs to; the function **requires** it to be 3 lowercase hex.
- Body: full chunk keys (`tsync/<d>/chunks/<s>/<h1>-<h2>`) joined by `\n`, no trailing newline required; empty lines ignored on both sides. Nothing needs escaping (hex, `-`, `/`, and the domain).
- The run in the key keeps a later collection from overwriting a request an earlier one left unconsumed.
- Re-delivery (`tsync gc --retry-jobs`): for each copy store, list `tsync/gc-jobs/<d>/`, and for each job key whose shard parses, GET the body and PUT it back unchanged — a fresh object-created event.

### 3.3 Corruption marker

- Key: `tsync/corrupted/<d>/<s>/<chunkkey>`, derived from a chunk key by `marker_key` (last `/chunks/` segment, 3-hex shard, valid chunk key, non-empty domain; anything else — markers, `chunks.from/`, manifests — has none).
- Body (JSON, from the function): `{"computed": "<h1>-<h2>", "size": <int>, "at": <epoch float>}`. Readers accept any subset and ignore unknown fields ([06 §2.6](../06-backends.md)).
- Findings are read by clients listing `tsync/corrupted/<d>/` with their ordinary credentials; no body ever leaves the cloud to be checked.

## 4. Shared HTTP client (gcs and http-proxy; **not** s3)

s3 uses its client library's own pool and has no stall timeout ([s3.md §6](s3.md)). gcs and the http-proxy client use this one:

- **Pool per client instance**, keyed by endpoint (cohttp's connection cache): keep idle connections **60 s**, at most **32 parallel** connections per endpoint. The caller's own concurrency bounds work; this only must not be the narrower limit.
- **Redial once**: if a pooled connection turns out unusable before the request left (`Redial`), the whole pool is replaced (once per generation, so concurrent requests that hit the same dead pool share one redial) and the request re-issued.
- **Stall timeout, not a latency budget**: each attempt runs under `with_stall_timeout(timeout)`. The timer starts with the attempt (so minting a bearer token in the header thunk counts inside the deadline), is reset once the headers are built, and again by every piece of the response as it arrives. A request body being uploaded is **not** heard: it must cross within one `timeout`, which is why the uplink window is sized as half the stall timeout × the admitted rate. Expiry raises the scheduler's timeout exception → Transient, and the ladder records it with `Health.timed_out` (the governor's congestion signal).
- Timeouts: gcs uses `Uplink_budget.stall_timeout` (60 s, read at construction, so window and deadline are one setting); http-proxy 300 s.
- **Status classification**: `5xx` and `429` Transient; every other status Permanent. `call_retry` raises on Transient statuses inside the ladder; every other response (404 included) is returned for the verb to interpret. Error detail = `HTTP <code>: <excerpt>`, the excerpt being the body with whitespace runs flattened to one space, cut at 200 chars with ` ...` (an HTML error page from a proxy, or pretty-printed JSON, stays one bounded log line).
- Bodies are sent and received as off-heap buffers; request bodies are passed through without a copy, so they must stay valid until the call returns.

## 5. The verb pattern (both drivers)

Every verb is one ladder run ([06 §4.1](../06-backends.md): 8 attempts, jittered exponential backoff capped at 20 s, interruptible by stop) with the store's `Health.t`:

1. Inside the attempt, issue the request; if the outcome is Transient, raise so the ladder retries it; otherwise return the outcome (success, 404, 412, a Permanent status).
2. After the ladder, the verb interprets: 404 → none/false/Permanent depending on the verb; 412 in `put_if_absent` → read back; Permanent → raise `Retry.Failed{Permanent}` (and log it).
3. A per-key bulk-delete refusal is raised after the ladder as Transient: the caller decides whether to repeat the batch.

Shared helpers keep drivers from drifting: `absent_code` (`NoSuchKey`, `NotFound` = the object was already gone) and `checked_range`.

## 6. Server-side function

One Python module (`lambda/verify.py`) with two entry points, one storage adapter per cloud (`STORE=aws|gcs`, default `aws`), built lazily on first use so importing the module needs no credentials.

### 6.1 Storage adapter surface

`get_bytes(key)` (missing → `FileNotFoundError`), `put_bytes(key, bytes)`, `delete(key)` (absent is not an error), `delete_many(keys) → [(key, code)] refused` (absent is success), `list_keys(prefix)` (flat, paginated), `read_chunk(key) → iterable of byte slices`.

| | AWS (`boto3`) | GCP (`google-cloud-storage`) |
|---|---|---|
| `delete_many` | `DeleteObjects` in batches of 1000, `Quiet=true`; `Errors` with code not `NoSuchKey`/`NotFound` returned | JSON batch endpoint, 100 sub-requests per call; a failed batch is redone key by key in parallel (32 threads), `NotFound` ignored, other exceptions returned as `(key, exception name)` |
| `read_chunk` | streamed in 1 MiB slices | one whole download (chunks are bounded) |
| `list_keys` | `list_objects_v2` paginator | `list_blobs` |

### 6.2 Dispatch per event key

In this order: GC job (`gc_job_domain(key)` parses) → verify job (`job_target(key)` parses) → chunk (`marker_key(key)` exists) → anything else is ignored (manifests, journal, markers, `chunks.from/`, shares). The filter on the trigger is only configuration; the code decides.

- `gc_job_domain`: key starts `tsync/gc-jobs/`; the rest splits (from the right) into `<domain>/<run>/<shard>` with a 3-hex shard, non-empty domain and run. The domain may contain `/`.
- `job_target`: key starts `tsync/verify-jobs/`; the rest splits from the right into `<domain>/<shard>`; answers the prefix `tsync/<domain>/chunks/<shard>/`.

### 6.3 Per-chunk check (`verify_object`)

1. `marker = marker_key(key)`; none → nothing read, return "not a chunk".
2. **Delete the marker first.**
3. Stream the body once through two XXH3-64 states (seeds 0 and 1) and a byte counter; `computed = "%016x-%016x"`.
4. `computed == leaf` → clean. Otherwise PUT the marker JSON `{computed, size, at}`.

Marker-first because object events are at-least-once and unordered: a stale "clean" (no marker) over bad bytes is unrecoverable, a spurious marker over good bytes costs one re-upload. The function's own marker writes land under `tsync/` and trigger it again; `marker_key(marker)` is none, so the second invocation reads and writes nothing — the loop terminates.

### 6.4 Verify job (`verify_shard`)

List `tsync/<d>/chunks/<s>/`, run §6.3 on each, then delete the job object **last** (a run that dies leaves the request as evidence; re-queueing retries it). Returns `{checked, corrupt}`.

### 6.5 GC job (`run_gc_job`)

1. Parse the domain; GET the body. Missing (a redelivery of a consumed request) → no-op.
2. `wanted` = non-empty trimmed lines. Keep those passing `may_delete(k, d)` = `marker_key(k)` exists **and** `k` starts with `tsync/<d>/chunks/` (one domain's request cannot reach another's; markers, manifests, `chunks.from/` fail the shape test). Refused keys are logged, never retried.
3. List `tsync/corrupted/<d>/` once and keep the markers that accuse a kept key (deleting derived markers unseen doubled the cost and rate-limited a real bucket).
4. `delete_many(kept + markers)`. Any refusal → log and **leave the request in place** (a bulk delete's success status hides per-key refusals). Otherwise delete the request.

### 6.6 Entry points and delivery semantics

| | AWS | GCP |
|---|---|---|
| Entry | `verify.handler(event, context)` | `verify.gcp_verify(event, context=None)` |
| Event | S3 notification: `Records[].s3.object.key`, URL-encoded with `+` for space → `unquote_plus` | Pub/Sub message (either CloudEvent `.data.message` or the legacy background dict); key = `attributes.objectId` |
| Batch | every record in the event, each in its own `try`: one bad object never abandons the rest, and an exception never escapes (S3 would redeliver the whole notification) | one object per message |
| Failure | logged traceback; the event is not retried | the exception propagates, but the trigger's retry policy is `DO_NOT_RETRY` (a bucket the function cannot read would otherwise retry every chunk forever) |
| Result | `{checked, corrupt, deleted}` summed | same shape; nothing to do → zeros |

So on both clouds a failed invocation is dropped: a chunk check is lost (re-run with `tsync data-integrity --verify`), a verify job or GC job stays in the bucket (reported by the client, re-delivered by re-writing it).

## 7. Deployment (terraform)

Modules `store-s3` and `store-gcs` provision one "store": the bucket (created, or an existing one adopted with `create_bucket = false`), client credentials scoped to it, the verify function and its trigger, optionally the share function, and lifecycle rules. The verify half and the share half ship in one source zip; the entry point differs. Outputs feed `tsync config --edit` → "Fill from Terraform".

### 7.1 Verify function and trigger

| | AWS (`store-s3/verify.tf`) | GCP (`store-gcs/verify.tf`) |
|---|---|---|
| Runtime | Lambda `python3.13`, **arm64** (the vendored `xxhash` wheel is aarch64; `vendor/` is appended to `sys.path` so an installed copy wins) | Cloud Functions gen2 `python313`, `GOOGLE_FUNCTION_SOURCE = verify.py`, `xxhash` from `requirements.txt` |
| Timeout / memory | `verify_timeout_seconds` 120 s / `verify_memory_mb` 512 | same variables and defaults |
| Concurrency cap | `reserved_concurrent_executions = verify_max_concurrency` (32) | `max_instance_count = verify_max_instances` (32) |
| Trigger | `aws_s3_bucket_notification`: one rule, `s3:ObjectCreated:*`, `filter_prefix = "tsync/"` (S3 forbids overlapping filters for one event, and chunks, verify jobs and GC jobs all live under `tsync/`). The resource **owns** the bucket's whole notification configuration; `manage_notifications = false` leaves it untouched for an operator to wire (must cover chunks and `tsync/gc-jobs/`). Invoke permission scoped to the bucket ARN and source account. | Storage notification `OBJECT_FINALIZE`, `object_name_prefix = "tsync/"`, payload `JSON_API_V1`, onto a Pub/Sub topic (Eventarc's storage trigger has no prefix filter); GCS service agent granted publisher on the topic; function subscribed via Eventarc `messagePublished`, retry policy `DO_NOT_RETRY`; the function's service account has `eventarc.eventReceiver` and `run.invoker` on itself (without it every event is rejected silently). |
| Env | `BUCKET` | `BUCKET`, `STORE=gcs` |

The 120 s timeout is a stall guard sized for one chunk, one shard walk, or one GC job of up to twice `--delete-batch` keys (chunks plus markers) in 1000-key deletes; raising `--delete-batch` is the operator's to keep in step.

### 7.2 Grants (least privilege)

| Principal | AWS | GCP |
|---|---|---|
| tsync client | IAM user + access key: `ListBucket`, `ListBucketMultipartUploads` on the bucket; `Get/Put/DeleteObject`, `AbortMultipartUpload`, `ListMultipartUploadParts` on `bucket/*` | service account + JSON key: `roles/storage.objectUser` on the bucket |
| verify function | `GetObject` on `tsync/*/chunks/*`; `Put/DeleteObject` on `tsync/corrupted/*`; `Get/DeleteObject` on `tsync/verify-jobs/*` and `tsync/gc-jobs/*`; `DeleteObject` on `tsync/*/chunks/*`; `ListBucket` | `objectViewer` bucket-wide (list cannot be prefix-conditioned); `objectUser` conditioned on `startsWith` of `tsync/corrupted/`, `tsync/verify-jobs/`, `tsync/gc-jobs/`; custom role `tsyncChunkDeleter_<name>` (`storage.objects.delete` only) conditioned on `resource.name.extract(".../objects/tsync/{domain}/chunks/") != ""` |

Why markers and jobs sit beside the domains (`tsync/corrupted/<d>/…`) rather than inside (`tsync/<d>/corrupted/…`): notification filters and IAM conditions take only a literal prefix (GCP: `startsWith`), so one prefix must cover every domain. The function may delete chunks but never write one: a wrong body would be silent, a wrong delete at least visible. The request body chooses what is deleted, so it is validated in code (§6.5) and the grant is the ceiling on how wrong that can go.

### 7.3 Bucket settings

- New buckets: public access blocked; AWS bucket policy denies any request without TLS (`aws:SecureTransport = false`); GCS uniform bucket-level access, public access prevention enforced.
- Lifecycle (`manage_lifecycle`, default on; on AWS the resource owns the whole lifecycle configuration, `extra_lifecycle_rules` preserves others): abort incomplete multipart uploads after 1 day (tsync writes none; the share function's assembly does); optional `archive_domains`: per domain, transition `tsync/<d>/chunks/` only after `after_days` to `GLACIER_IR` (AWS default) / `ARCHIVE` (GCS default) — one rule per domain because a filter holds one literal prefix. Manifests, versions, journal, cursor, shares and jobs stay in the standard class. No rule may expire `tsync/gc-jobs/` (an expired request is a silent leak).

### 7.4 CI stack

`terraform/ci/` deploys only the verify half (`deploy_share = false`, `manage_lifecycle = false`, `create_bucket = false`, notifications managed) over existing CI buckets on both clouds, from a zip built from `lambda/` minus tests. `tests/conformance` then checks that `verify_all` queues 4096 shard-naming objects (or already consumed ones), that `discard` writes a request with exactly the keys, and that the live function removes the named chunk.

### 7.5 Share function (context only)

`handler.py` behind a public Lambda Function URL (optionally API Gateway + ACM custom domain) or a public Cloud Run service reads share manifests under `tsync/shares/`, assembles files server-side (S3 `CopyObject`/multipart upload-copy; GCS `compose` in tiers of 32), caches under `tsync/shares/cache/`, and redirects to presigned GETs (TTL 600 s). Its URL is what a driver's `shareUrl` carries; a share link is `<shareUrl>/<token>`. Specified with shares.

## 8. Test-pinned invariants

- `lambda/test_*`: the Python chunk key equals the OCaml golden vectors; a streamed hash equals the one-shot hash and the size comes from the same pass; GC job keys parse and malformed ones are refused; a request is never mistaken for a chunk; marker lifecycle (a good chunk gets no marker, a scrambled one is filed, a good rewrite clears it, a manifest is never read, a marker never earns one, domains are separated, large bodies); a verify job sweeps its shard, an empty shard's job is dropped; a delete job drops chunks and their markers, refuses other domains and non-chunks, a redelivery is a no-op; both Pub/Sub calling conventions are accepted.
- `tests/conformance` (real buckets): §7.4, plus `verified = true`.
- `tests/backends/http_reuse`: ten requests share one accepted connection. `http_stall`: a slow but flowing body is not a stall; a stall is measured from the last byte.

## 9. Open questions

1. **`verified` and `discard = Queued` are assertions**: a bucket deployed without the function (manual setup, S3-compatible provider, `manage_notifications = false` never wired) claims checks nobody runs and accepts deletes nobody executes. Nothing probes for the function.
2. **Dropped invocations are not retried on either cloud**; a failed chunk check leaves no trace except the function's log.
3. **Every chunk write costs one function invocation**, plus one per marker, verify job and GC job, bounded only by the concurrency cap (32); a large upload queues invocations behind it.
4. **The GCS verify reader is bucket-wide** (`objectViewer`), wider than the AWS policy; flagged in the module for narrowing.
5. **s3 does not use the shared HTTP client**, so the stall timeout, pool limits and status classification differ between the two object stores ([s3.md §10](s3.md)).
6. `verify_all` starts all 4096 PUTs as pending tasks at once and bounds only those in flight (32); fine at 4096, but the width is the data's, not the code's.
