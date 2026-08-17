# tsync stores (Terraform)

Single point of entry for provisioning tsync S3 storage. Each **store** is:

- an **S3 bucket** (created, or an existing one you point at),
- an **IAM user + access key** scoped to that bucket, for the tsync client
  (`accessKeyId` / `secretAccessKey` in your config),
- the **share Lambda** behind a public Function URL that serves `tsync share`
  download links (assembles the file, or zips the folder, on first request and
  caches the result),
- a **lifecycle rule** that expires cached share artifacts,
- the **verify function**, triggered by the bucket's own object-created
  notification, which holds each stored chunk against its own name and also
  carries out the deletes a `tsync gc` hands it (see below).

You can provision **several stores** — for multiple domains or redundant storage —
from one `stores` map.

## Quick start

Interactive setup — asks which cloud (S3 or GCS), defines your first store in
`terraform.tfvars`, creates the bucket that holds Terraform state, activates the
matching backend, and runs `terraform init` against it:

```
./init.sh
terraform apply
```

Then wire each store into the matching tsync domain. The easy path is
`tsync config --edit`: edit the s3 or gcs domain, choose **Sync from Terraform**, and
it pulls the values from `terraform output` (or `tofu output`, whichever of the two
is installed) and writes them onto the backend — for
s3 `bucket`/`region`/`accessKeyId`/`secretAccessKey`/`shareUrl`, for gcs
`bucket`/`serviceAccountKey`/`shareUrl`. Nothing Terraform-specific is stored in
the config.

To wire it by hand instead, read the outputs:

```
terraform output stores
terraform output -json secret_access_keys | jq -r '.["files"]'
```

and set those fields on the store's s3 backend, including `shareUrl` (the
`share_url`) to enable sharing for that bucket:

```json
{
  "type": "s3",
  "bucket": "...",
  "region": "...",
  "accessKeyId": "...",
  "secretAccessKey": "...",
  "shareUrl": "<share_url from `terraform output stores`>",
  "role": "main"
}
```

`shareUrl` lives on the **backend**, not the domain: `tsync share` uses the first
backend that has one, and writes the share manifest to that bucket. With several
s3 backends (redundant storage), put `shareUrl` only on the one whose Lambda
should serve shares.

## Defining stores

`terraform.tfvars`:

```hcl
region = "us-east-1"

stores = {
  # key = short logical name; suffixes IAM/Lambda resource names.
  files = {
    bucket = "my-tsync-files"
  }

  # Another domain, and/or a redundant bucket — just add entries.
  media = {
    bucket = "my-tsync-media"
  }

  # Point at a pre-existing bucket instead of creating one.
  legacy = {
    bucket        = "already-there"
    create_bucket = false
  }
}
```

Per-store options (`bucket` required): `create_bucket` (default true),
`iam_user_name` (default `tsync-client-<key>`), `manage_lifecycle` (default true),
`share_expiry_days` (default 30), `archive_after_days` (see below),
`extra_lifecycle_rules` (see below), `custom_domain` (see below), plus
`presign_ttl`, `lambda_memory_mb`, `ephemeral_storage_mb`.

Shares live under a single fixed prefix, `tsync/shares/` (domain-independent — a
share manifest records its own domain in its body). The module hardcodes it to
match the daemon, so there's nothing to configure: it's what the Lambda serves,
what the write IAM is scoped to, and what the lifecycle rule expires.

When `create_bucket = true` the bucket is locked down (public access blocked,
TLS-only bucket policy). When `false`, Terraform only reads the bucket and leaves
its access settings alone.

## The verify function, and chunk deletes

One function serves three kinds of object, told apart by the key alone, because
one notification is all a bucket gets: S3 rejects overlapping prefix filters, so
the filter says `tsync/` and the code decides what it was handed.

- a **chunk** is hashed and, if it is not what its name says, a marker is filed
  under `tsync/corrupted/<domain>/`;
- a **sweep request** under `tsync/verify-jobs/<domain>/<shard>`, written by
  `tsync data-integrity --verify`, checks a whole shard;
- a **delete request** under `tsync/gc-jobs/<domain>/<run>/<shard>`, written by
  `tsync gc`, drops the chunks it names and the markers accusing them.

The third is why the function's role can delete chunks. That grant is the
ceiling on how wrong a malformed request can go, so it is as narrow as each
cloud allows — `tsync/*/chunks/*` on AWS; on GCS an IAM condition, which offers
no wildcard, matched with `extract` on the same shape. Narrower still is the
function's own check: a request may only name keys under its *own* domain's
chunk prefix, and anything else is logged and left alone.

A request is deleted last and only when every key went, so a partial or failed
run leaves it in the bucket. `tsync gc --status` lists what is outstanding.
Nothing retries on its own — GCS runs the function with `DO_NOT_RETRY` and the
Lambda has no dead-letter queue — so an outstanding request means a copy holding
chunks nothing references, which is wasted space rather than lost data.

Two things to keep in mind if you manage the bucket yourself:

- with `manage_notifications = false` (AWS) the trigger is yours to wire, and it
  must cover `tsync/gc-jobs/` as well as chunks and sweep requests. A collection
  hands its deletes to any s3 or gcs copy, so a trigger that misses that prefix
  leaves requests nobody consumes — `tsync gc --status` lists them and `tsync gc
  --retry-jobs` re-delivers once it is wired;
- no lifecycle rule you add through `extra_lifecycle_rules` may expire anything
  under `tsync/gc-jobs/`: a request is the record of a delete that has been
  promised and not yet made.

`deploy_share = false` deploys the verification half alone -- the verifier, its
trigger and the client credentials, with no share function and no public
endpoint. That is what `terraform/ci/` uses to give the conformance suite
something real to trigger without standing up an unauthenticated URL over a
test bucket.

There is nothing to set on the client: an s3 or gcs bucket is assumed to carry
the function that made it, the same assumption `verified` already rests on.

## Custom domain (optional)

By default share links use the raw function URL. Set `custom_domain` on a store to
serve them from a vanity host instead (`https://tsync.example.org/<token>`); the
store's `share_url` output then points at the domain. Stores without
`custom_domain` are unchanged — no extra infrastructure, cert, or DNS needed. DNS
is not managed here (works with any provider — Route 53, Cloudflare, a registrar);
you add the records by hand.

### S3

```hcl
stores = {
  files = {
    bucket        = "my-tsync-files"
    custom_domain = "tsync.example.org"
  }
}
```

This provisions an API Gateway HTTP API + a regional ACM cert in front of the
Lambda. You add two `CNAME` records by hand. Create the cert first so apply never
hangs waiting on validation:

```
# 1. Create just the ACM cert (adjust the store key).
terraform apply -target='module.store["files"].aws_acm_certificate.share[0]'

# 2. Read the validation CNAME and add it at your DNS provider.
terraform output -json custom_domain_dns
```

Add the `acm_validation` record as a CNAME, then run the full `terraform apply`.
It waits for ACM to issue the cert (usually a minute or two once the record
resolves) and completes.

Once apply completes, add a second CNAME from your domain (`tsync.example.org`)
to the `cname_target` in `terraform output -json custom_domain_dns`.

On Cloudflare, set both CNAMEs to **DNS only** (grey cloud) — a proxied record
hides the CNAME and ACM validation / routing won't work.

Then copy the store's `share_url` into your s3 backend's `shareUrl`.

### GCS

```hcl
gcs_stores = {
  media = {
    bucket        = "tsync-media"
    custom_domain = "share.example.org"
  }
}
```

This maps the domain onto the share Cloud Function's Cloud Run service, which
serves it and renews its own cert — no load balancer, so no hourly forwarding-rule
charge. Two things it does not do: path routing, CDN and Cloud Armor are not
available, and domain mapping is offered only in a subset of Cloud Run regions.

The parent domain must be verified for the deploying account **before** `apply`,
or the mapping is rejected:

```
gcloud domains verify example.org
```

Then publish whatever Cloud Run asks for — a `CNAME` for a subdomain, `A`/`AAAA`
sets for an apex:

```
terraform apply
terraform output -json gcs_custom_domain_dns   # { "media": { domain, records } }
```

`records` stays empty until the mapping leaves `PENDING`; re-run `terraform
refresh` if the first apply returns nothing. `apply` does not block on the cert —
it provisions on its own once DNS resolves (~15–60 min). Check status with:

```
gcloud beta run domain-mappings describe --domain=share.example.org --region=<region>
```

On Cloudflare, set the records to **DNS only** (grey cloud). Then copy the
store's `share_url` into your gcs backend's `shareUrl`.

## Remote state

State lives in a remote bucket — **either** S3 **or** GCS, whichever cloud you're
on. The two are independent alternatives (a config may have only one backend
block); pick one, and it's unrelated to which *store* backends you provision. The
repo ships both as `backend-*.tf.example`; you activate exactly one. Because the
state bucket must exist first, a tiny `bootstrap-*` config creates it, keeping its
own state locally.

Follow the section for your cloud — neither assumes you did the other. `init.sh`
automates whichever one you pick.

### S3

```
# 1. Activate the S3 backend.
mv backend-s3.tf.example backend-s3.tf

# 2. Create the state bucket (versioned, encrypted, private).
terraform -chdir=bootstrap-s3 init
terraform -chdir=bootstrap-s3 apply -var state_bucket=my-tsync-tfstate -var region=us-east-1

# 3. Point the main config at it and initialize.
cp backend-s3.hcl.example backend.hcl   # then edit bucket/region
terraform init -backend-config=backend.hcl
```

Locking uses S3 natively (`use_lockfile`, Terraform ≥ 1.10) — no DynamoDB table.

### GCS

```
# 1. Activate the GCS backend.
mv backend-gcs.tf.example backend-gcs.tf

# 2. Create the state bucket (versioned, uniform access, private).
terraform -chdir=bootstrap-gcs init
terraform -chdir=bootstrap-gcs apply -var project=my-gcp-project -var location=US -var state_bucket=my-tsync-tfstate

# 3. Point the main config at it and initialize.
cp backend-gcs.hcl.example backend.hcl  # then edit bucket
terraform init -backend-config=backend.hcl
```

The gcs backend locks state on its own (via the object's generation) — no lock
table needed.

`backend.hcl` and the activated `backend-*.tf` are git-ignored so your choice
stays local; only the `.example` templates are committed. If you'd rather not use
remote state at all, don't activate either — `terraform init` uses local state.

## Credentials are in Terraform state

The client credentials are generated by Terraform, so the secrets live in your
state: S3 access keys for s3 stores, service-account JSON keys for GCS stores.
Keep state in the remote bucket (see Remote state above) — encrypted for S3,
private/UBLA for GCS — treat that bucket as sensitive and restrict access to it.
Rotate a key by replacing it:
`terraform apply -replace='module.store["files"].aws_iam_access_key.client'`
(or `module.store_gcs["files"].google_service_account_key.client` for GCS).

## Multi-region

All stores use `var.region`. S3 bucket region comes from the provider, so buckets
in **different** regions need a provider per region. Add an aliased provider and a
second module call (or a second root/workspace). Sketch:

```hcl
provider "aws" { alias = "eu", region = "eu-west-1" }

module "store_eu" {
  source    = "./modules/store-s3"
  providers = { aws = aws.eu }
  name      = "files-eu"
  bucket    = "my-tsync-files-eu"
  # ...same inputs as a stores entry...
  lambda_zip      = data.archive_file.handler.output_path
  lambda_zip_hash = data.archive_file.handler.output_base64sha256
}
```

(Same-region redundant buckets are just extra `stores` entries — no provider
needed.)

## Bucket lifecycle

Each store installs one rule that expires everything under `tsync/shares/`
after `share_expiry_days` (default 30), so cached artifacts and their manifests
don't accumulate. Keep `share_expiry_days` **≥ the longest `tsync share --expires`
you hand out** — expiring a manifest revokes its link, so a short lifecycle window
kills links that should still be live.

### Cold storage (`archive_after_days`)

Both `stores` (S3) and `gcs_stores` (GCS) take an opt-in `archive_after_days`,
`null` (off) by default. When set, it transitions **every** object in the
bucket — including `tsync/shares/` — to a cold storage class after N days:
`GLACIER_IR` on S3, `ARCHIVE` on GCS.

```hcl
stores = {
  media = {
    bucket             = "my-tsync-media"
    archive_after_days = 60
  }
}

gcs_stores = {
  media = {
    bucket             = "tsync-media"
    archive_after_days = 60
  }
}
```

Shares are meant to be deleted, not archived — so **keep `archive_after_days`
strictly greater than `share_expiry_days`**. That ordering is your
responsibility; the module doesn't enforce it, and the two clouds fail
differently if you get it backwards:

- **S3** rejects the whole lifecycle config at apply time: it requires a
  transition's `days` to be strictly less than any expiration on the same
  object, so `archive_after_days <= share_expiry_days` is a hard error.
- **GCS** applies Delete over SetStorageClass whenever both match the same
  object at the same age, so `archive_after_days == share_expiry_days` silently
  never archives shares (harmless but pointless). Set it *below*
  `share_expiry_days` and shares really would reach the cold class before
  deletion — but `ARCHIVE` carries a 365-day minimum storage duration, so
  anything deleted sooner incurs an early-deletion charge for the unused
  remainder.

For anything beyond a single flat cutoff on S3 (a different storage class,
scoping to one prefix, tiering through multiple classes) use
`extra_lifecycle_rules` instead — see below.

### Why you have to care about existing rules

AWS models bucket lifecycle as a **single** object
(`aws_s3_bucket_lifecycle_configuration`) that owns *all* rules on the bucket —
there is no per-rule resource. So when a store manages lifecycle, `terraform apply`
**replaces** whatever lifecycle that bucket already had (relevant mainly for
`create_bucket = false`). Any rule you don't carry over is silently dropped.

Check a pre-existing bucket before your first apply:

```
aws s3api get-bucket-lifecycle-configuration --bucket YOUR_BUCKET
```

If that returns rules, use one of the two options below.

### Option A — carry rules in `extra_lifecycle_rules` (recommended)

List the bucket's current rules in the store entry and the module emits them
**alongside** its shares-expiry rule, so nothing is lost:

```hcl
stores = {
  legacy = {
    bucket        = "already-there"
    create_bucket = false

    extra_lifecycle_rules = [{
      id              = string          # required, unique rule name
      prefix          = string          # optional, default "" = whole bucket
      expiration_days = number          # optional, delete objects after N days
      transitions = [{                  # optional, zero or more
        days          = number
        storage_class = string          # STANDARD_IA | ONEZONE_IA | INTELLIGENT_TIERING
      }]                                # | GLACIER_IR | GLACIER | DEEP_ARCHIVE
    }]
  }
}
```

For example, transition everything to Glacier Instant Retrieval after 30 days:

```hcl
extra_lifecycle_rules = [{
  id          = "glacier-ir"
  transitions = [{ days = 30, storage_class = "GLACIER_IR" }]
}]
```

More shapes:

```hcl
extra_lifecycle_rules = [
  # Scope a transition to one prefix, leave the rest of the bucket alone.
  {
    id          = "media-to-ia"
    prefix      = "my-prefix/media/"
    transitions = [{ days = 60, storage_class = "STANDARD_IA" }]
  },
  # Tier down over time, then delete.
  {
    id          = "archive-then-delete"
    prefix      = "my-prefix/"
    transitions = [
      { days = 30, storage_class = "GLACIER_IR" },
      { days = 180, storage_class = "DEEP_ARCHIVE" },
    ]
    expiration_days = 3650
  },
]
```

**Interaction with the shares rule.** A whole-bucket (empty-prefix) rule like the
Glacier one above *also* matches the `tsync/shares/` cache objects. Usually
harmless — Glacier IR objects are still downloaded instantly — but two edges are
worth knowing:

- Glacier IR bills a 90-day minimum storage duration. Since share caches are
  deleted at `share_expiry_days` (30 by default), any that got transitioned incur
  an early-deletion charge for the unused ~60 days. Small, but not zero.
- To keep short-lived shares in Standard, give your transition rule a `prefix` that
  doesn't cover `tsync/shares/` (as in the scoped example), or raise
  `share_expiry_days` past 90.

Rule ordering doesn't matter to S3 — each rule is evaluated independently. Just
keep every `id` unique.

### Option B — manage lifecycle yourself

Set `manage_lifecycle = false` on the store and the module won't touch that
bucket's lifecycle at all (no clobber, no shares-expiry rule). You then own it
entirely — remember to add your own rule expiring `tsync/shares/`, or share caches
pile up forever. Useful when lifecycle is managed by a separate stack, an SCP, or
by hand.

## Notes

- **Auth**: each Function URL is public. The unguessable manifest id in the URL is
  the only gate; delete the share manifest object (under `tsync/shares/`) to
  revoke a link.
- **Limits**: folder zips build in `/tmp` (10 GB) within the 900 s Lambda timeout;
  single files cap at ~80 GB (10,000 multipart parts).

## The share Lambda

The Lambda source lives at the repo top level in [`../lambda/`](../lambda/); this
config packages and deploys it. Test it locally from the repo root:

```
python3 -m venv .venv && . .venv/bin/activate
pip install boto3 moto pytest
pytest lambda/test_handler.py
```
