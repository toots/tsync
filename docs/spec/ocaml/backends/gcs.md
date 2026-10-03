# gcs — Google Cloud Storage driver — OCaml implementation notes

Companion to the language-neutral spec [../../backends/gcs.md](../../backends/gcs.md). The shell every bucket shares is in [s3.md](s3.md). See [README.md](../README.md) for how these notes are organised.

Code: `lib/store/gcs/gcs.ml` and `gcs_auth.ml` (a `private_modules` of `tsync_gcs`), over `Tsync_store.Object_store`, `Tsync_store.Bucket_xml` and `Tsync_http.Client`.

## Map

| Spec | Code |
|---|---|
| Fields (§1) | `fields` in `gcs.ml`: `bucket`, `serviceAccountKey` (secret), `endpoint` (`Field_spec.http_url`), `shareUrl`; `create` trims one trailing `/` and refuses an anonymous store off loopback |
| Service-account key (§1.1) | `Gcs_auth.create`, with the four messages of the table |
| JWT (§2) | `jwt` in `gcs_auth.ml`: `Mirage_crypto_pk.Rsa.PKCS1.sign ~mask:`No ~hash:`SHA256`, key from `X509.Private_key.decode_pem` |
| Exchange and its kinds (§2) | `mint` |
| Token cache (§2) | `Gcs_auth.token`: an `Atomic` of the token and its expiry on `Rt.now`, minted under `Rt.Fmutex` with a second look inside |
| 401 from storage (§2) | `call` in `gcs.ml`: `Gcs_auth.invalidate`, one fresh token, one more send |
| Key encoding (§3) | `Gcs.segment` |
| Verbs (§3) | `upload`, `put_if_absent`, `put_if_unchanged`, `get_opt`, `get_range`, `head_opt`, `delete`, `copy` (`rewriteTo`, repeated while the answer carries a `rewriteToken`) |
| Metadata to entry (§3.1) | `entry_of_json`, `Gcs.rfc3339` (`Ptime.of_rfc3339`), `Checksum.md5_of_base64` |
| Listing (§3.2) | `list_page`, with the `fields` projection that keeps `generation` and `md5Hash` |
| Bulk delete (§3.3) | `delete_page`: `Bucket_xml.delete_body`, `Content-MD5` from `Digest.string`, `Bucket_xml.delete_errors`, `Object_store.per_key_failure`; a key `Bucket_xml.safe` refuses goes through `delete` |
| Status mapping | `fail` over `Object_store.status_failure`, with `Retry-After` |
| Registration | the top-level `Driver.register "gcs"` |

## Departures

- **The token is fetched before the storage request, on its own endpoint**, not inside the storage attempt's stall window. `Gcs_auth` has its own `Client.endpoint` (two connections) and `mint` is bounded by that request's stall timeout.
- **`put_if_unchanged` answers `Changed` without a request for an etag that is not a decimal generation**: such a version was named by another store.

## Learnings

- **REFUSED with a reason is `Fail.Denied`** (`refused/denied`): a refused grant in `mint`, and a second 401 through `Object_store.status_failure`. Both are permanent and cost one attempt; `Retry.ladder` counts a permanent failure as an answer for the member's health.
- **No RNG is needed.** PKCS#1 v1.5 signing with `` ~mask:`No `` is deterministic, so the driver signs before anything has seeded `Mirage_crypto_rng`.
- **The cache is an `Atomic`, the mint a fiber mutex.** The fast path reads without a lock from any domain; `Rt.Fmutex` suspends the waiting fibers instead of blocking their threads across the token request. A failed mint caches nothing, so each waiter runs its own.
- **`invalidate` compares the token it was handed** and clears with `compare_and_set`: a 401 on an old token never drops one a concurrent caller has just minted.
- **Freshness is on the monotonic clock, `iat` on the wall clock.** `Rt.now` decides whether the cached token is fresh; `Unix.gettimeofday` fills the claims, which Google compares with its own time.
- **Targets are built by hand.** `segment` escapes every byte outside the unreserved set, `/` included, and the string goes to `Client.request` as the target; no URI library sits in between to turn `%2F` back into `/` (pitfall B-2.8).
- **`json` refuses an answer that is not a JSON object as CORRUPT**, so `Yojson.Safe.Util.member`, which raises `Type_error` on anything else, never sees one at the top level (pitfall B-10.6).
- **`size` is a JSON string on GCS and an integer on emulators**; `entry_of_json` accepts both and fails CORRUPT on anything else. `generation` is read the same way.
- **The etag is the generation, the checksum the service's `md5Hash`.** A composite object carries no `md5Hash`, and `Object_store`'s `compute_checksum` then downloads the body.
- **Bulk delete is the one XML call.** It shares `Bucket_xml` with S3, takes the same bearer token, and needs `Content-MD5` (`Stdlib.Digest` is MD5). `NoSuchKey` and `NotFound` are both absences.
- **Tests.** `tests/store/gcs_test` runs the contract against a fake served by `Tsync_http.Server` on loopback, and against a real bucket when `TSYNC_CI_GCS_BUCKET` and `TSYNC_CI_GCS_SERVICE_ACCOUNT_KEY` are set. `segment` and `rfc3339` are exported past `(**/**)` for it.
