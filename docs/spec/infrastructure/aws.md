# Store infrastructure on AWS

How an S3 store meets [11 — Store infrastructure](../11-infrastructure.md). Section numbers are that
file's; a rule stated there is not repeated here. The driver is [backends/s3](../backends/s3.md).

Resource names are fixed ([11 §15](../11-infrastructure.md#15-compatibility)). `N` is the store name,
`B` the bucket, `R` the store's region.

---

## 2. Deployment

| Input | Default | Meaning |
|---|---|---|
| region | none; required with an S3 store | Default region of a store. |

- A store name matches `[A-Za-z0-9_-]{1,51}`. New names SHOULD be lowercase letters, digits and `-`.
- A store MAY name its own region; its bucket, functions, certificate and API are all in it. IAM
  resources are global.
- Every store is in the one account the operator's credentials reach.
- **Prerequisites:** none beyond credentials able to create the resources below.

## 3. Function package

- Each function is created directly from the zip, and redeployed on a change of its SHA-256.
- Runtime Python 3.13. The runtime installs nothing: the functions use its own AWS SDK, and the
  package carries `xxhash` as a compiled extension built for that runtime on arm64.
- The verify function, which loads it, runs on arm64. The share function never loads it and runs on
  either architecture.

## 4. Bucket

A created bucket has:

- all four public-access blocks on;
- a bucket policy denying every S3 action, to every principal, on the bucket and its objects, when
  `aws:SecureTransport` is false.

One-per-bucket documents ([11 §4](../11-infrastructure.md#4-bucket)): the **lifecycle
configuration** (§9) and the **notification configuration** (§6). Both are taken over by default on
created and adopted buckets alike; each can be declined (§10).

## 5. Client identity

- An IAM user `tsync-client-<N>`, or the name the operator gives (§10).
- One inline policy `tsync-store-access`:

  | On | Actions |
  |---|---|
  | `B` | `s3:ListBucket`, `s3:ListBucketMultipartUploads` |
  | every object of `B` | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts` |

- One access key: `accessKeyId` and `secretAccessKey`.

## 6. Verify function

- **Role** `tsync-verify-<N>`, assumable by the Lambda service, with the managed policy
  `AWSLambdaBasicExecutionRole` and one inline policy `tsync-verify-s3`:

  | On | Actions |
  |---|---|
  | `tsync/*/chunks/*` | `s3:GetObject`, `s3:DeleteObject` |
  | `tsync/corrupted/*` | `s3:PutObject`, `s3:DeleteObject` |
  | `tsync/verify-jobs/*` | `s3:GetObject`, `s3:DeleteObject` |
  | `tsync/gc-jobs/*` | `s3:GetObject`, `s3:DeleteObject` |
  | `B` | `s3:ListBucket` |

- **Function** `tsync-verify-<N>`: Lambda, handler `verify.handler`, the limits of
  [11 §6](../11-infrastructure.md#6-verify-function) with the concurrency ceiling as reserved
  concurrency, environment `BUCKET=B`.
- **No retry:** asynchronous invocation configured with 0 retry attempts, and the provider's default
  maximum event age.
- **Callers:** a resource permission letting the S3 service invoke the function, for events from
  `B`'s ARN and this account only.
- **Trigger:** the bucket's notification configuration holds one entry `tsync-verify`: events
  `s3:ObjectCreated:*`, key prefix `tsync/`, to the function. One entry, because S3 refuses
  overlapping prefixes for one event.
- When the operator declines the notification configuration, nothing triggers the function until
  they add that entry to their own.

## 7. Share function

- **Role** `tsync-share-<N>`, assumable by the Lambda service, with `AWSLambdaBasicExecutionRole`
  and one inline policy `tsync-share-s3`:

  | On | Actions |
  |---|---|
  | every object of `B` | `s3:GetObject` |
  | `tsync/shares/cache/*` | `s3:PutObject`, `s3:AbortMultipartUpload` |
  | `B` | `s3:ListBucket` |

  Assembly is server-side copy and multipart upload, which need no delete. URLs are signed with the
  role's own credentials.
- **Function** `tsync-share-<N>`: Lambda, handler `handler.handler`, the limits of
  [11 §7](../11-infrastructure.md#7-share-function), ephemeral storage SHARE_SCRATCH, environment
  `BUCKET=B`, `PRESIGN_TTL=<seconds>`, `MAX_BYTES=<bytes>`.
- **Endpoint:** a function URL with authentication type `NONE`, and two resource permissions for
  every principal: `lambda:InvokeFunctionUrl` conditioned on that authentication type, and
  `lambda:InvokeFunction` conditioned on the call coming through the function URL.
- SHARE_SCRATCH defaults to 10240 MB, the provider's maximum, and SHARE_MAX_BYTES to 8 GiB. The
  ceiling MUST NOT exceed the scratch space less 1 GiB.

## 8. Vanity domain

For a domain `D`:

1. A public certificate for `D` in `R`, validated by DNS.
2. An HTTP API `tsync-share-<N>` with one Lambda proxy integration to the share function (payload
   format 2.0), the `$default` route to it, and a `$default` stage deployed automatically.
3. A resource permission letting API Gateway invoke the share function from any route and stage of
   that API.
4. A regional custom domain name `D` on the API, minimum TLS 1.2, with the certificate, mapped to
   the stage.

Records to publish: the certificate's validation CNAME, then a CNAME from `D` to the custom domain's
regional target. Applying waits for the certificate to be issued, so the operator creates the
certificate alone first, publishes its validation record, then applies the rest. The function URL
stays public beside the domain.

## 9. Lifecycle

The store's rules are the bucket's whole lifecycle configuration:

| Rule id | Filter | Action |
|---|---|---|
| `tsync-abort-incomplete` | whole bucket | abort incomplete multipart uploads ABORT_INCOMPLETE after initiation |
| `tsync-archive-<domain>`, one per archived domain | prefix `tsync/<domain>/chunks/` | transition to the domain's class after `after_days` |
| each operator rule | its prefix (default: whole bucket) | its transitions (days, class) and its expiration (days) |

- **Classes that read online:** `STANDARD_IA`, `ONEZONE_IA`, `INTELLIGENT_TIERING`, `GLACIER_IR`.
  Default `GLACIER_IR`. `GLACIER` and `DEEP_ARCHIVE` need a restore and are refused for an archived
  domain, and for an operator rule that can match under `tsync/`.
- `after_days` is at least 30 for `STANDARD_IA` and `ONEZONE_IA`.
- An operator rule can match under `tsync/` when its prefix is a prefix of `tsync/`, or begins with
  it. Its id MUST differ from the store's own.
- At most 1000 rules.
- When the operator declines the lifecycle configuration it is neither read nor changed, and the
  abort rule is theirs to add.

## 10. Store options

Beyond [11 §10](../11-infrastructure.md#10-store-options):

| Option | Default | Meaning |
|---|---|---|
| region | the deployment's | §2 |
| client user name | `tsync-client-<N>` | §5 |
| manage lifecycle | yes | no = decline the lifecycle configuration (§9) |
| operator lifecycle rules | none | §9 |
| manage notifications | yes | no = decline the notification configuration (§6) |
| share scratch space | 10240 MB | §7 |

## 11. Outputs

- `stores[N]`: `type = "s3"`, `bucket`, `region`, `accessKeyId`, and `shareUrl` with a share
  function.
- `store_secrets[N]`: `secretAccessKey`.
- `custom_domain_dns[N].records`: the validation record, and the CNAME from the domain to its
  target once the custom domain exists.

## 12. Operator state

- State object `tsync/terraform.tfstate`, encrypted, locked by a lock object beside it.
- State bucket: versioning on; AES-256 default encryption; all four public-access blocks on; one
  lifecycle rule expiring noncurrent versions and aborting incomplete uploads.

## 13. Tooling

The setup script:

- asks the region (default `us-east-1`) and reads the account id from the AWS CLI when it can;
- proposes the store bucket `tsync-<N>-<account>-<region>` and the state bucket
  `tsync-tfstate-<account>-<region>`;
- for an adopted bucket, shows the existing lifecycle and notification configurations that applying
  would replace, and names the two ways out: carry the rules as operator rules, or decline the
  document.

## 14. Conformance stack

- Inputs: the bucket and its region. No bucket: no AWS call.
- The notification configuration of the adopted bucket is taken over; the lifecycle is declined.
- Reports the verify function's name, `tsync-verify-ci`.
