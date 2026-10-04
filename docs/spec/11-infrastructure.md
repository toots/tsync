# 11 — Store infrastructure

Scope: the cloud resources that have to exist around a bucket for it to be a complete tsync store,
on AWS and on Google Cloud, and the operator tooling that creates them. What the bucket-side
functions *do* is [object-store-common §5–6](backends/object-store-common.md); this file owns what
is deployed, with which identity, permissions, limits and trigger.

**Status: descriptive.** This file states what the configuration under `terraform/` provisions
today, in terms of the providers' own concepts. It is exact enough to reproduce a store by hand in
either console. It is not yet normative: where the two providers differ, both are described as they
are.

Each section is one functionality, stated first for both providers where they agree, then under
**AWS** and **GCS** separately.

---

## 1. Vocabulary

| Term | Meaning |
|---|---|
| **deployment** | One applied configuration: any number of S3 stores and GCS stores, plus what they share. |
| **store** | One bucket and everything attached to it: a client identity, the verify function and its trigger, optionally the share function and its endpoint, lifecycle rules. |
| **store name** `N` | The operator's short name for a store. It only builds resource names; it is not a tsync domain name. |
| **function package** | One archive of the function source, shared by every store, both providers and both functions. |
| **operator state** | The provisioning tool's record of what it created, including the client secrets. |

A store is in exactly one provider. One bucket may serve several tsync domains: every key is under
`tsync/<domain>/` or one of the store-level prefixes `tsync/shares/`, `tsync/corrupted/`,
`tsync/verify-jobs/`, `tsync/gc-jobs/`.

## 2. Deployment inputs

A deployment is a map of S3 stores and a map of GCS stores, each from store name to the options of
§10, plus the provider-wide inputs below. Both maps default to empty.

### AWS

| Input | Default | Meaning |
|---|---|---|
| region | none; required with an S3 store | Region of every S3 bucket, function, certificate and API. |

Store names match `[A-Za-z0-9_-]`. Every S3 store is in the one region and one account. A deployment
with no S3 store makes no AWS call and needs no AWS credentials.

### GCS

| Input | Default | Meaning |
|---|---|---|
| project | none; required with a GCS store | Project holding every resource. |
| bucket location | none; required with a GCS store | Default bucket location (a region or a multi-region), and the location of the source bucket (§3). |
| function region | `us-central1` | Default region of the functions. A region, never a multi-region. |
| source bucket name | `<project>-tsync-functions-src` | §3. |

Store names match `[a-z0-9-]`. Location and function region can be set per store. A deployment with
no GCS store creates nothing in the project.

## 3. Function package

A zip of the repository's `lambda/` directory as it is on the operator's disk, without the test
files, the vendored package's README and interpreter or test caches. It holds both entry modules
(`handler`, `verify`), their shared modules, the share pages' assets, `requirements.txt`, and a
vendored `xxhash`.

A function is redeployed when the package's SHA-256 changes.

### AWS

Each function is created directly from the zip. The runtime installs nothing: the functions use the
runtime's own AWS SDK and the vendored `xxhash`, which is built for Linux on arm64 with Python 3.13.

### GCS

When the deployment has at least one GCS store, one **source bucket**: in the default bucket
location, uniform bucket-level access, deletable with its contents. Each store uploads the zip to it
as the object `tsync-share-<N>/<base64 sha256>.zip`, and both of the store's functions build from
that object. The build installs `requirements.txt` (the storage client and `xxhash`); the vendored
`xxhash` is not used.

## 4. Bucket

Either **created** or **adopted** (an existing bucket, named).

### AWS

A created bucket has the provider's defaults (no versioning, default encryption, no ACLs) and:

- all four public-access blocks on;
- a bucket policy denying every S3 action to every principal on the bucket and its objects when the
  request is not over TLS (`aws:SecureTransport` false).

An adopted bucket's access settings and policy are not read or changed. Its lifecycle and
notifications are still taken over unless opted out (§9, §6).

### GCS

A created bucket is in the store's location, with uniform bucket-level access and public access
prevention enforced.

An adopted bucket's settings are not read or changed, and neither is its lifecycle (§9).

## 5. Client identity

The credentials a tsync backend is configured with: object read, write, delete and list on the one
bucket, and no bucket or permission administration.

### AWS

- An IAM user `tsync-client-<N>` (the name can be overridden).
- One inline policy `tsync-store-access`:

  | On | Actions |
  |---|---|
  | the bucket | `s3:ListBucket`, `s3:ListBucketMultipartUploads` |
  | every object | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts` |

- One access key. Its id and secret are the backend's `accessKeyId` and `secretAccessKey`.

### GCS

- A service account `tsync-client-<N>`.
- On the bucket: `roles/storage.objectUser` (read, create, delete and list objects).
- One user-managed key. Its JSON is the backend's `serviceAccountKey`.

## 6. Verify function

Always deployed, one per store, triggered by the bucket for every object created under `tsync/`.
Timeout 120 s, memory 512 MB, at most 32 concurrent executions, Python 3.13.

### AWS

- **Role** `tsync-verify-<N>`, assumable by the Lambda service, with the managed policy
  `AWSLambdaBasicExecutionRole` (its own logs) and one inline policy `tsync-verify-s3`:

  | On | Actions |
  |---|---|
  | `tsync/*/chunks/*` | `s3:GetObject`, `s3:DeleteObject` |
  | `tsync/corrupted/*` | `s3:PutObject`, `s3:DeleteObject` |
  | `tsync/verify-jobs/*` | `s3:GetObject`, `s3:DeleteObject` |
  | `tsync/gc-jobs/*` | `s3:GetObject`, `s3:DeleteObject` |
  | the bucket | `s3:ListBucket` |

- **Function** `tsync-verify-<N>`: Lambda, handler `verify.handler`, architecture arm64 (the
  vendored hash is built for it), the limits above with the concurrency ceiling as reserved
  concurrency, environment `BUCKET=<bucket>`. Retries of a failed asynchronous invocation are left
  at the provider's default.
- **Invoke permission**: the S3 service may invoke the function, for events from this bucket's ARN
  and this account only.
- **Trigger**: a bucket notification `tsync-verify`, events `s3:ObjectCreated:*`, key prefix
  `tsync/`, to the function. It is **the bucket's whole notification configuration**: applying it
  replaces any other notification on the bucket. An option (§10) leaves the bucket's notifications
  untouched instead, and then nothing triggers the function.

### GCS

- **Service account** `tsync-verify-<N>`, with:

  | Scope | Role | Condition on the object name |
  |---|---|---|
  | the bucket | `roles/storage.objectViewer` | none |
  | the bucket | `roles/storage.objectUser` | starts with `tsync/corrupted/`, `tsync/verify-jobs/` or `tsync/gc-jobs/` |
  | the bucket | a custom project role `tsyncChunkDeleter_<N>` (dashes as underscores) holding only `storage.objects.delete` | matches `tsync/<any>/chunks/` (`resource.name.extract(...) != ""`) |
  | the project | `roles/eventarc.eventReceiver` | |
  | the function's Cloud Run service | `roles/run.invoker` | |

  Object names in conditions are spelled `projects/_/buckets/<bucket>/objects/<key>`.

- **Function** `tsync-verify-<N>`: 2nd-generation Cloud Function in the store's function region,
  entry point `gcp_verify` in `verify.py` (build variable `GOOGLE_FUNCTION_SOURCE=verify.py`), the
  limits above with the concurrency ceiling as the maximum instance count, running as the verify
  service account, environment `BUCKET=<bucket>`, `STORE=gcs`.
- **Topic** `tsync-chunks-<N>` in Pub/Sub. The project's Cloud Storage service agent has
  `roles/pubsub.publisher` on it.
- **Trigger**: a bucket notification to the topic (event `OBJECT_FINALIZE`, object name prefix
  `tsync/`, payload `JSON_API_V1`), added beside any other notification on the bucket; and a
  Pub/Sub trigger from the topic to the function, in the function region, delivered as the verify
  service account, **without retry**.

## 7. Share function

Deployed unless the store is declared without it (§10), one per store, on an unauthenticated public
URL. Timeout 900 s, memory 2048 MB, Python 3.13. Environment: `BUCKET=<bucket>`,
`PRESIGN_TTL=<seconds>` (600), `MAX_BYTES=<bytes>` (10 GiB).

The store's **share URL** is the function's URL without its trailing slash, or the vanity domain
(§8).

### AWS

- **Role** `tsync-share-<N>`, assumable by the Lambda service, with `AWSLambdaBasicExecutionRole`
  and one inline policy `tsync-share-s3`:

  | On | Actions |
  |---|---|
  | every object | `s3:GetObject` |
  | `tsync/shares/*` | `s3:PutObject`, `s3:AbortMultipartUpload` |
  | the bucket | `s3:ListBucket` |

- **Function** `tsync-share-<N>`: Lambda, handler `handler.handler`, the provider's default
  architecture, ephemeral storage 10240 MB. `MAX_BYTES` is fixed at its default.
- **Public endpoint**: a function URL with no authentication, and a resource permission letting any
  principal call `lambda:InvokeFunctionUrl` on it with authentication type none.

### GCS

- **Service account** `tsync-share-<N>`, with:

  | Scope | Role | Condition on the object name |
  |---|---|---|
  | the bucket | `roles/storage.objectViewer` | none |
  | the bucket | `roles/storage.objectUser` | starts with `tsync/shares/` |
  | itself | `roles/iam.serviceAccountTokenCreator` | |

  The last one lets the function sign download URLs as itself, with no private key at run time.

- **Function** `tsync-share-<N>`: 2nd-generation Cloud Function in the store's function region,
  entry point `gcp_handler` in `handler.py` (`GOOGLE_FUNCTION_SOURCE=handler.py`), the provider's
  default instance ceiling, running as the share service account, with `STORE=gcs` added to the
  environment. Its temporary directory is memory, so an archive it assembles is bounded by the
  function's memory, not by `MAX_BYTES`.
- **Public endpoint**: `roles/run.invoker` for `allUsers` on the function's Cloud Run service.

## 8. Vanity domain

Only when the store names a domain `D`. The share URL becomes `https://D`. No DNS record is created:
the operator publishes the records the deployment reports (§11).

### AWS

1. A public certificate for `D` in the store's region, validated by DNS. The provisioning waits
   until it is issued, so the operator publishes the validation record while it waits.
2. An HTTP API `tsync-share-<N>` with one Lambda proxy integration to the share function (payload
   format 2.0), the `$default` route to it, and a `$default` stage deployed automatically.
3. A resource permission letting API Gateway invoke the share function from any route and stage of
   that API.
4. A regional custom domain name `D` on the API, minimum TLS 1.2, with the certificate, mapped to
   the stage.

The operator publishes two records: the certificate's validation CNAME, and a CNAME from `D` to the
custom domain's regional target. The function URL stays public beside the domain.

### GCS

A Cloud Run domain mapping of `D` to the share function's service, in the function region, and only
when the store has a share function. Cloud Run issues and renews the certificate once DNS resolves;
provisioning does not wait for it.

The operator verifies ownership of the parent domain for their account beforehand, and publishes
the records the mapping reports: a CNAME for a subdomain, A and AAAA records for an apex.

## 9. Lifecycle

When managed (the default): incomplete multipart uploads are aborted after 1 day, and each
**archived domain** has its chunks (prefix `tsync/<domain>/chunks/`) moved to a storage class
`after_days` after creation. Nothing else under `tsync/` is transitioned or expired.

An archived domain's key is not empty, holds no `/`, and is not one of `shares`, `corrupted`,
`verify-jobs`, `gc-jobs`. `after_days` is positive.

### AWS

Applies to a created and to an adopted bucket alike. The rules are **the bucket's whole lifecycle
configuration**: applying them replaces any rule already there.

| Rule id | Filter | Action |
|---|---|---|
| `tsync-abort-incomplete` | whole bucket | abort incomplete multipart uploads 1 day after initiation |
| `tsync-archive-<domain>`, one per archived domain | prefix `tsync/<domain>/chunks/` | transition to the domain's storage class after `after_days` |
| each of the operator's extra rules | its prefix (default: whole bucket) | its transitions (days, class) and its expiration (days) |

Storage class: one of `STANDARD_IA`, `ONEZONE_IA`, `INTELLIGENT_TIERING`, `GLACIER_IR`, `GLACIER`,
`DEEP_ARCHIVE`, default `GLACIER_IR`. `after_days` is at least 30 for the two `_IA` classes.

When not managed, the bucket's lifecycle is not read or changed, and nothing aborts incomplete
uploads.

### GCS

Applies to a created bucket only, as rules of the bucket itself. An adopted bucket's lifecycle is
never read or changed, whatever the options.

| Condition | Action |
|---|---|
| age 1 day | abort incomplete multipart uploads |
| one per archived domain: age `after_days`, prefix `tsync/<domain>/chunks/` | set the domain's storage class |

Storage class: one of `NEARLINE`, `COLDLINE`, `ARCHIVE`, default `ARCHIVE`. At most 99 archived
domains. There are no extra rules.

## 10. Store options

On both providers:

| Option | Default | Meaning |
|---|---|---|
| bucket name | required | |
| create the bucket | yes | no = adopt (§4) |
| vanity domain | none | §8 |
| manage lifecycle | yes | §9 |
| archived domains | none | map: domain → `after_days`, storage class (§9) |
| presigned URL lifetime | 600 s | `PRESIGN_TTL` (§7) |
| share memory | 2048 MB | §7 |
| verify timeout | 120 s | §6 |
| verify memory | 512 MB | §6 |
| verify concurrency ceiling | 32 | §6 |
| deploy the share function | yes | not settable per store in a deployment; only the conformance stack (§14) turns it off |

### AWS

| Option | Default | Meaning |
|---|---|---|
| client user name | `tsync-client-<N>` | §5 |
| extra lifecycle rules | none | §9 |
| manage notifications | yes | §6 |
| share ephemeral storage | 10240 MB | §7 |

### GCS

| Option | Default | Meaning |
|---|---|---|
| bucket location | the deployment's | §4 |
| function region | the deployment's | §6, §7 |
| share size ceiling | 10 GiB | `MAX_BYTES` (§7) |

## 11. Outputs

What a deployment reports, per store name, for the operator to set on a tsync backend. The share
URL is null for a store without a share function. Nothing else has to be set for the store to work:
the client confirms the verify function itself
([object-store-common §3](backends/object-store-common.md#3-confirming-the-bucket-side-function)).

The configuration wizard ([07 §5](07-daemon-cli.md)) reads the outputs as JSON from `terraform`,
then from `tofu`, and takes top-level string outputs named like a backend field.

### AWS

| Output | Per store | Backend field of [s3](backends/s3.md) |
|---|---|---|
| `stores` | `bucket`, `region`, `share_url`, `access_key_id` | `bucket`, `region`, `shareUrl`, `accessKeyId` |
| `secret_access_keys` (sensitive) | the secret | `secretAccessKey` |
| `custom_domain_dns` | for a store with a vanity domain: the certificate validation records (name, type, value) and the CNAME target | |

### GCS

| Output | Per store | Backend field of [gcs](backends/gcs.md) |
|---|---|---|
| `gcs_stores` | `bucket`, `share_url` | `bucket`, `shareUrl` |
| `gcs_service_account_keys` (sensitive) | the key JSON | `serviceAccountKey` |
| `gcs_custom_domain_dns` | for a store with a vanity domain: the domain and the records to publish (name, type, data) | |

## 12. Operator state

The state holds every client secret. It is kept locally, or in one bucket of either provider,
whatever the providers of the stores.

The state bucket is created by a separate, minimal configuration whose own state is local and
disposable. Its old state versions expire after 90 days, and its incomplete multipart uploads abort
after 1 day. The backend choice and the state bucket's name are local files that are never
committed.

A client secret is rotated by replacing its key resource.

### AWS

- State object `tsync/terraform.tfstate`, encrypted.
- Locking by a lock object beside the state (tool version ≥ 1.10).
- State bucket: versioning on; AES-256 default encryption; all four public-access blocks on.

### GCS

- State under the prefix `tsync`.
- Locking by the state object's generation.
- State bucket: versioning on; uniform bucket-level access; public access prevention enforced.

## 13. Setup script

`terraform/init.sh` is interactive. It asks the provider, the provider's location inputs, a first
store's name, bucket and whether to create it, and the state bucket's name. It then:

1. refuses to continue when the other provider's backend is already active;
2. writes the deployment's variables for that one store, unless the file exists and the operator
   keeps it;
3. writes the backend settings, unless kept;
4. optionally creates the state bucket (§12);
5. activates the chosen backend and initialises the deployment against it;
6. prints how to review, apply and read the outputs.

It applies nothing to the deployment itself. It invokes `terraform` by name.

### AWS

- Asks the region (default `us-east-1`); reads the account id from the AWS CLI when it can.
- Proposes the store bucket `tsync-<N>-<account>-<region>` and the state bucket
  `tsync-tfstate-<account>-<region>`.
- For an adopted bucket, warns when the bucket cannot be reached, or already has lifecycle rules
  that applying would replace.
- Backend settings: state bucket and region.

### GCS

- Asks the project (default: the gcloud CLI's) and the bucket location (default `US`).
- Proposes the store bucket `<project>-<N>` and the state bucket `<project>-tfstate`.
- Backend settings: state bucket.

## 14. Conformance stack

A second, separate configuration (`terraform/ci/`) provisions what the live-store tier
([10 §3.3](10-delivery.md#33-live-stores)) triggers. Its state is always in a GCS bucket, under a
prefix of its own (`tsync-ci`), so that applying it cannot reach a real deployment's stores.

For each provider given a bucket, it deploys one store named `ci` on that **adopted** bucket, with
lifecycle unmanaged and **no share function**: the client identity (§5), the verify function and its
trigger (§6). It builds the function package the same way as §3, from its own copy of the exclusion
list.

`scripts/setup_ci_secrets.sh` creates the buckets and their credentials, applies this stack with
`tofu` or else `terraform`, and stores the results as CI secrets.

### AWS

- Inputs: the bucket and its region (default `us-east-1`). No bucket: nothing is deployed, and no
  AWS credentials are needed.
- The bucket's notification configuration is taken over (§6).
- Reports the verify function's name, `tsync-verify-ci`, or null.

### GCS

- Inputs: the bucket, the project, the source bucket's region and the function region (both default
  `us-central1`). No bucket: nothing is deployed.
- Its own source bucket, `<project>-tsync-ci-functions-src`.
- Reports the verify function's name, `tsync-verify-ci`, or null, and the function region.
