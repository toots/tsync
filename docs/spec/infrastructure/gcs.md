# Store infrastructure on Google Cloud

How a GCS store meets [11 — Store infrastructure](../11-infrastructure.md). Section numbers are that
file's; a rule stated there is not repeated here. The driver is [backends/gcs](../backends/gcs.md).

Resource names are fixed ([11 §15](../11-infrastructure.md#15-compatibility)). `N` is the store name,
`B` the bucket, `P` the project. An object name in a permission condition is spelled
`projects/_/buckets/B/objects/<key>`.

---

## 2. Deployment

| Input | Default | Meaning |
|---|---|---|
| project | none; required with a GCS store | Project holding every resource. |
| bucket location | none; required with a GCS store | Default location of a store's bucket (a region or a multi-region), and the location of the source bucket (§3). |
| function region | `us-central1` | Default region of a store's functions. A region, never a multi-region. |
| source bucket name | `<P>-tsync-functions-src` | §3. |

- A store name matches `[a-z][a-z0-9-]{0,16}` and does not end with `-`: it has to fit a service
  account id.
- A store MAY name its own bucket location and function region.
- Functions are 2nd-generation Cloud Functions, each backed by a Cloud Run service of the same name.
- **Services enabled by the deployment:** Cloud Functions, Cloud Run, Cloud Build, Artifact
  Registry, Eventarc, Pub/Sub, IAM, IAM Service Account Credentials, Cloud Storage.
- **Prerequisites:** the Service Usage and Cloud Resource Manager APIs enabled; credentials able to
  create the resources below and to grant roles on the project; for a vanity domain, ownership of
  the parent domain verified for the operator's account.

## 3. Function package

- One **source bucket** per deployment with at least one GCS store: in the default bucket location,
  uniform bucket-level access, deletable with its contents.
- The package is uploaded to it once, as the object `<hex sha256>.zip`. Every function of every
  store builds from that object, and is redeployed when its name changes.
- Runtime Python 3.13. The build installs `requirements.txt` (the storage client and `xxhash`); the
  `xxhash` carried in the package is not used.
- The build variable `GOOGLE_FUNCTION_SOURCE` names the entry module's file.

## 4. Bucket

A created bucket is in the store's location, with uniform bucket-level access and public access
prevention enforced. The provider has no setting to deny plain HTTP.

One-per-bucket documents ([11 §4](../11-infrastructure.md#4-bucket)): none on an adopted bucket.
The lifecycle is part of the bucket itself, so it is managed on a created bucket and never touched
on an adopted one (§9). Notifications and permission grants are added beside what exists.

## 5. Client identity

- A service account `tsync-client-<N>`.
- On `B`: `roles/storage.objectUser`.
- One user-managed key: its JSON text is `serviceAccountKey`.

## 6. Verify function

- **Service account** `tsync-verify-<N>`, with:

  | Scope | Role | Condition on the object name |
  |---|---|---|
  | `B` | `roles/storage.objectViewer` | none |
  | `B` | `roles/storage.objectUser` | starts with `tsync/corrupted/`, `tsync/verify-jobs/` or `tsync/gc-jobs/` |
  | `B` | the custom project role `tsyncChunkDeleter_<N>` (dashes as underscores), holding only `storage.objects.delete` | `resource.name.extract("…/objects/tsync/{domain}/chunks/") != ""` |
  | `P` | `roles/eventarc.eventReceiver` | |
  | the function's Cloud Run service | `roles/run.invoker` | |

  The read is bucket-wide ([11 §6](../11-infrastructure.md#6-verify-function)): a listing cannot be
  conditioned on a prefix, and a verifier that cannot read reports a clean store.
- **Function** `tsync-verify-<N>` in the store's function region: entry point `gcp_verify` in
  `verify.py`, the limits of [11 §6](../11-infrastructure.md#6-verify-function) with the concurrency
  ceiling as the maximum instance count, running as the verify service account, environment
  `BUCKET=B`, `STORE=gcs`.
- **Topic** `tsync-chunks-<N>` in Pub/Sub, on which the project's Cloud Storage service agent has
  `roles/pubsub.publisher`.
- **Trigger:** a bucket notification to the topic (event `OBJECT_FINALIZE`, object name prefix
  `tsync/`, payload `JSON_API_V1`), and a Pub/Sub trigger from the topic to the function, in the
  function region, delivered as the verify service account. A storage trigger is not used: it has
  no prefix filter.
- **No retry:** the trigger's retry policy is "do not retry".
- **Callers:** the run-invoker grant above is the only one on the service.

## 7. Share function

- **Service account** `tsync-share-<N>`, with:

  | Scope | Role | Condition on the object name |
  |---|---|---|
  | `B` | `roles/storage.objectViewer` | none |
  | `B` | `roles/storage.objectUser` | starts with `tsync/shares/cache/` |
  | itself | `roles/iam.serviceAccountTokenCreator` | |

  Assembly composes through temporary objects under the cache, hence the delete. The last grant
  lets the function sign download URLs as itself, with no private key at run time.
- **Function** `tsync-share-<N>` in the store's function region: entry point `gcp_handler` in
  `handler.py`, the limits of [11 §7](../11-infrastructure.md#7-share-function), running as the
  share service account, environment `BUCKET=B`, `PRESIGN_TTL=<seconds>`, `MAX_BYTES=<bytes>`,
  `STORE=gcs`.
- **Endpoint:** `roles/run.invoker` for `allUsers` on the function's Cloud Run service; the
  function's own URL.
- The scratch space is the function's memory, shared with the function itself. SHARE_MAX_BYTES
  defaults to 1 GiB and MUST NOT exceed the share memory less 512 MB: the operator raises the two
  together.

## 8. Vanity domain

For a domain `D`: a Cloud Run domain mapping of `D` to the share function's service, in the function
region. Cloud Run issues and renews the certificate once DNS resolves; applying does not wait for
it. Domain mapping exists only in some regions.

Records to publish: those the mapping reports, a CNAME for a subdomain, A and AAAA records for an
apex. They are reported once the mapping has them, which MAY take a second read of the outputs.

## 9. Lifecycle

On a created bucket, always, as rules of the bucket:

| Condition | Action |
|---|---|
| age ABORT_INCOMPLETE | abort incomplete multipart uploads |
| one per archived domain: age `after_days`, prefix `tsync/<domain>/chunks/` | set the domain's class |

- **Classes:** `NEARLINE`, `COLDLINE`, `ARCHIVE`, all of which read online. Default `ARCHIVE`.
- At most 99 archived domains: a bucket takes 100 rules.
- There are no operator rules: a rule added by hand to a created bucket is removed by the next
  apply.

On an adopted bucket the lifecycle is the operator's
([11 §9](../11-infrastructure.md#9-lifecycle)). Archived domains named for one are refused. Rules to
add by hand: the abort rule above, and nothing that expires under `tsync/`.

## 10. Store options

Beyond [11 §10](../11-infrastructure.md#10-store-options):

| Option | Default | Meaning |
|---|---|---|
| bucket location | the deployment's | §4 |
| function region | the deployment's | §6, §7 |

## 11. Outputs

- `stores[N]`: `type = "gcs"`, `bucket`, and `shareUrl` with a share function.
- `store_secrets[N]`: `serviceAccountKey`, the key's JSON text.
- `custom_domain_dns[N].records`: the records the domain mapping reports.

## 12. Operator state

- State under the prefix `tsync`, locked by the state object's generation.
- State bucket: versioning on; uniform bucket-level access; public access prevention enforced;
  the provider's default encryption; rules deleting noncurrent versions and aborting incomplete
  uploads.

## 13. Tooling

The setup script:

- asks the project (default: the gcloud CLI's) and the bucket location (default `US`);
- proposes the store bucket `<P>-<N>` and the state bucket `<P>-tfstate`;
- for an adopted bucket, says that its lifecycle stays the operator's and prints the rule to add.

## 14. Conformance stack

- Inputs: the bucket, the project, the source bucket's location and the function region. No bucket:
  nothing is created.
- Its own source bucket, `<P>-tsync-ci-functions-src`.
- Reports the verify function's name, `tsync-verify-ci`, and its region.
