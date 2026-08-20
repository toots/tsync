# tsync stores (Terraform)

Single point of entry for provisioning the cloud storage behind a tsync domain, on
**AWS (S3)** or **Google Cloud (GCS)**.

The two are equal citizens: same capabilities, same options, same outputs. Pick one
per store, or run both.

A **store** is one bucket and everything that has to exist around it:

- the **bucket** — created and locked down, or an existing one you point at;
- **client credentials** scoped to that bucket, for the tsync daemon (an IAM user +
  access key on AWS, a service-account key on GCP);
- a **share endpoint** on a public URL, serving `tsync share` links — a folder is
  zipped on first request, then cached, so a repeat download is immediate;
- **automatic data-integrity checking** of everything the store holds, and the
  server-side deletes `tsync gc` asks for;
- a **lifecycle rule set** that cleans up abandoned uploads and, if you ask for it,
  moves a domain's chunks to cold storage.

Provision **several stores** — for several domains, or for redundant copies of one —
by adding entries to the `stores` (S3) or `gcs_stores` (GCS) map.

---

## Contents

- [Quick start](#quick-start)
- [A complete store](#a-complete-store)
  - [S3](#s3)
  - [GCS](#gcs)
  - [Store options](#store-options)
- [Wiring a store into tsync](#wiring-a-store-into-tsync)
- [Share links](#share-links)
  - [A vanity domain for share links](#a-vanity-domain-for-share-links)
- [Cold storage (`archive_domains`)](#cold-storage-archive_domains)
  - [Why you have to name the domains](#why-you-have-to-name-the-domains)
  - [What it costs](#what-it-costs)
- [Working with an existing bucket](#working-with-an-existing-bucket)
  - [Option A — carry rules in `extra_lifecycle_rules` (recommended)](#option-a--carry-rules-in-extra_lifecycle_rules-recommended)
  - [Option B — manage lifecycle yourself](#option-b--manage-lifecycle-yourself)
- [Data integrity, and server-side deletes](#data-integrity-and-server-side-deletes)
  - [When a delete is outstanding](#when-a-delete-is-outstanding)
  - [If you wire the trigger yourself](#if-you-wire-the-trigger-yourself)
- [Remote state](#remote-state)
  - [S3](#s3-2)
  - [GCS](#gcs-2)
  - [Credentials are in Terraform state](#credentials-are-in-terraform-state)
- [Multi-region](#multi-region)
- [The function source](#the-function-source)

---

## Quick start

Interactive setup — asks which cloud, defines your first store in `terraform.tfvars`,
creates the bucket that holds Terraform state, activates the matching backend, and
runs `terraform init` against it:

```
./init.sh
terraform apply
```

Then wire the store into a tsync domain. The easy path is `tsync config --edit`: edit
the s3 or gcs domain and choose **Sync from Terraform**.

That pulls the values from `terraform output` (or `tofu output`, whichever you have
installed) and writes them onto the backend. Nothing Terraform-specific ends up in
your tsync config.

---

## A complete store

Each block below is a whole `terraform.tfvars`. The two clouds take the same shape —
a map of stores, keyed by a short logical name — and differ only in the top-level
settings and a handful of per-store options.

### S3

```hcl
region = "us-east-1"

stores = {
  # Map key = short logical name. It suffixes IAM and Lambda resource names, so
  # keep it short and unique — it is not the tsync domain name.
  files = {
    bucket = "my-tsync-files"
  }

  media = {
    bucket = "my-tsync-media"

    # Serve share links from a vanity host instead of the raw Lambda URL.
    custom_domain = "tsync.example.org"

    # Move this domain's chunks to cold storage. Keyed by tsync DOMAIN name.
    archive_domains = {
      "Movies" = { after_days = 60 }
      "Photos" = { after_days = 180, storage_class = "DEEP_ARCHIVE" }
    }
  }

  # Point at a pre-existing bucket instead of creating one. Terraform reads it and
  # leaves its access settings alone — but still owns its lifecycle unless told
  # otherwise, so see "Working with an existing bucket" below.
  legacy = {
    bucket        = "already-there"
    create_bucket = false

    extra_lifecycle_rules = [{
      id          = "glacier-ir"
      transitions = [{ days = 30, storage_class = "GLACIER_IR" }]
    }]
  }
}
```

### GCS

```hcl
gcp_project         = "my-gcp-project"
gcp_region          = "us-east1"
gcp_function_region = "us-east1" # must be a region, not a multi-region like US

gcs_stores = {
  files = {
    bucket = "my-tsync-files"
  }

  media = {
    bucket = "my-tsync-media"

    custom_domain = "share.example.org"

    archive_domains = {
      "Jellyfin Media" = { after_days = 60 }
      "Files"          = { after_days = 30, storage_class = "NEARLINE" }
    }
  }

  legacy = {
    bucket        = "already-there"
    create_bucket = false
  }
}
```

GCS uses native OAuth (a service-account key), not S3 interop.

`gcs_stores` has no `extra_lifecycle_rules` — on GCS, lifecycle is only ever managed
on a bucket the module created.

### Store options

`bucket` is the only required one; everything else has a default. These work on both
clouds:

| Option | Default | |
| --- | --- | --- |
| `bucket` | — | required |
| `create_bucket` | `true` | false = use a bucket that already exists |
| `custom_domain` | none | vanity host for share links |
| `archive_domains` | `{}` | per-domain cold storage |
| `manage_lifecycle` | `true` | false = don't touch the bucket's lifecycle at all |
| `presign_ttl` | `600` | lifetime (s) of a signed download URL |
| `verify_timeout_seconds` | `120` | stall guard on an integrity check |
| `verify_memory_mb` | `512` | memory for one integrity check |

S3 only: `iam_user_name`, `extra_lifecycle_rules`, `lambda_memory_mb`,
`ephemeral_storage_mb`, `manage_notifications`, `verify_max_concurrency`.

GCS only: `location`, `function_region`, `memory_mb`, `max_share_bytes`,
`verify_max_instances`.

---

## Wiring a store into tsync

`tsync config --edit` → **Sync from Terraform** does this for you. By hand, read the
outputs:

```
terraform output stores
terraform output -json secret_access_keys | jq -r '.["files"]'
```

```
terraform output gcs_stores
terraform output -json gcs_service_account_keys | jq -r '.["files"]'
```

and set them on the domain's backend — for s3
`bucket`/`region`/`accessKeyId`/`secretAccessKey`/`shareUrl`, for gcs
`bucket`/`serviceAccountKey`/`shareUrl`:

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
backend that has one, and writes the share manifest to that bucket.

With several backends (redundant storage), put `shareUrl` only on the one whose
function should serve shares.

There is nothing else to set on the client.

---

## Share links

`tsync share` publishes a link to a file or a folder. There is nothing to configure
here — every store serves them out of the box.

Each link carries **its own expiration**, set per share when it is created and
enforced on every request. Nothing in the bucket expires them on a shared clock, so
`--expires` means what it says.

The link is guarded only by the unguessable token in it. To revoke one early, delete
its manifest object under `tsync/shares/`.

A share is refused with a 413 above `max_share_bytes` — 10 GiB by default, for a
single file or a whole folder alike — and the build has to finish within 15 minutes.

On GCS a folder zip is assembled in memory, so it is bounded by the function's
`memory_mb` (2 GB by default) well before that ceiling. Raise the two together.

### A vanity domain for share links

By default share links use the raw function URL. Set `custom_domain` on a store to
serve them from your own host instead (`https://tsync.example.org/<token>`); that
store's `share_url` output then points at the domain.

Stores without `custom_domain` are unchanged — no extra infrastructure, cert, or DNS.

DNS is never managed here. Any provider works — Route 53, Cloudflare, a registrar —
and you add the records by hand.

#### S3

```hcl
stores = {
  files = {
    bucket        = "my-tsync-files"
    custom_domain = "tsync.example.org"
  }
}
```

This provisions an API Gateway HTTP API + a regional ACM cert in front of the Lambda,
and needs two `CNAME` records from you.

Create the cert first, so apply never hangs waiting on validation:

```
# 1. Create just the ACM cert (adjust the store key).
terraform apply -target='module.store["files"].aws_acm_certificate.share[0]'

# 2. Read the validation CNAME and add it at your DNS provider.
terraform output -json custom_domain_dns
```

Add the `acm_validation` record as a CNAME, then run the full `terraform apply`. It
waits for ACM to issue the cert — usually a minute or two once the record resolves.


Once apply completes, add a second CNAME from your domain (`tsync.example.org`) to the
`cname_target` in `terraform output -json custom_domain_dns`.

On Cloudflare, set both CNAMEs to **DNS only** (grey cloud) — a proxied record hides
the CNAME and ACM validation / routing won't work.

#### GCS

```hcl
gcs_stores = {
  media = {
    bucket        = "my-tsync-media"
    custom_domain = "share.example.org"
  }
}
```

This maps the domain onto the share Cloud Function's Cloud Run service, which serves
it and renews its own cert — no load balancer, so no hourly forwarding-rule charge.

Two things it does not do: path routing, and CDN / Cloud Armor. Domain mapping is also
offered only in a subset of Cloud Run regions.

The parent domain must be verified for the deploying account **before** apply, or the
mapping is rejected:

```
gcloud domains verify example.org
```

Then publish whatever Cloud Run asks for — a `CNAME` for a subdomain, `A`/`AAAA` sets
for an apex:

```
terraform apply
terraform output -json gcs_custom_domain_dns   # { "media": { domain, records } }
```

`records` stays empty until the mapping leaves `PENDING`; re-run `terraform refresh` if
the first apply returns nothing.

Apply does not block on the cert — it provisions on its own once DNS resolves
(~15–60 min). Check status with:

```
gcloud beta run domain-mappings describe --domain=share.example.org --region=<region>
```

On Cloudflare, set the records to **DNS only** (grey cloud).

---

## Cold storage (`archive_domains`)

Both `stores` and `gcs_stores` take `archive_domains`, a map keyed by **tsync domain
name**. Each entry moves that domain's chunks — its file data — to a cold storage
class once they are `after_days` old:

```hcl
archive_domains = {
  "Movies" = { after_days = 60 }
  "Photos" = { after_days = 180, storage_class = "DEEP_ARCHIVE" }
}
```

`storage_class` defaults per cloud: `GLACIER_IR` on S3, `ARCHIVE` on GCS. An empty
`archive_domains` (the default) transitions nothing. Keys are domain names exactly as
the daemon spells them — capitals and spaces included, so quote them.

### Why you have to name the domains

Only chunks are archived. The bookkeeping a store keeps beside them is read on every
sync and stays in the standard class, so archiving is never all-or-nothing.

Telling the two apart takes the domain name, and neither cloud offers a wildcard that
would let one rule stand for every domain — hence the map.

A domain you don't list is never archived. A name that doesn't match a real domain
does nothing at all: no error, no effect. Check it against your tsync config.

### What it costs

`tsync gc` deletes chunks, and a chunk deleted before its class's **minimum storage
duration** is billed for the unused remainder anyway: 30 days for `STANDARD_IA` /
`NEARLINE`, 90 for `GLACIER_IR` / `COLDLINE`, **365 for `ARCHIVE`**.

Archive a domain that churns and those early-deletion charges can outweigh what the
cold class saves. Pick the class for how long chunks actually live, not just for how
cold you want them.

Two smaller edges: S3 will not transition an object under 128 KiB at all, so a small
file's only chunk stays hot; and `STANDARD_IA` / `ONEZONE_IA` reject `after_days` below
30, which the module catches at plan time.

Rule counts: S3 allows 1000 lifecycle rules per bucket, GCS 100 — one per domain, plus
the abort rule, plus any `extra_lifecycle_rules`.

---

## Working with an existing bucket

`create_bucket = false` adopts a bucket instead of creating one. Terraform reads it and
leaves its access settings alone.

On AWS it does still take over the bucket's **lifecycle**, and there is no partial
version of that: `terraform apply` **replaces** whatever lifecycle the bucket already
had, and any rule you don't carry over is silently dropped.

Check before your first apply:

```
aws s3api get-bucket-lifecycle-configuration --bucket YOUR_BUCKET
```

If that returns rules, use one of the two options below. GCS is unaffected — an
adopted bucket's lifecycle is never touched there.

### Option A — carry rules in `extra_lifecycle_rules` (recommended)

List the bucket's current rules in the store entry and the module emits them
**alongside** its own, so nothing is lost:

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

**Interaction with the module's own rules.** A whole-bucket (empty-prefix) rule like
the Glacier one above sweeps up a store's bookkeeping and its share cache too —
precisely what `archive_domains` is careful to leave in the standard class.

If chunks are what you want archived, reach for `archive_domains`. Use a whole-bucket
transition only when you really do mean everything, and price the minimum storage
duration against how fast `tsync gc` turns chunks over.

Nothing you add here may expire anything under `tsync/gc-jobs/`: a request there is the
record of a delete that has been promised and not yet made.

Rule ordering doesn't matter to S3 — each rule is evaluated independently. Just keep
every `id` unique, and clear of the module's own (`tsync-abort-incomplete`,
`tsync-archive-<domain>`).

### Option B — manage lifecycle yourself

Set `manage_lifecycle = false` and the module won't touch that bucket's lifecycle at
all — no clobber, and none of its own rules.

You then own it entirely: nothing aborts abandoned uploads and nothing archives
anything unless you write the rules. There is no shares-expiry rule to reproduce —
a link's expiration is enforced per share, not by a bucket rule.

Useful when lifecycle is managed by a separate stack, an SCP, or by hand.

---

## Data integrity, and server-side deletes

Every store deploys a verify function that the bucket triggers itself. Two things
come out of it, and neither needs anything set on the client.

**Chunks are checked automatically as they are written.** Corruption is caught in the
store rather than on some later read, and `tsync data-integrity` reports and repairs
what was found. The same command can ask for a full re-check of everything already
there.

**`tsync gc` deletes happen in the cloud.** Collection decides what is unreferenced
on the client, but the removal runs next to the data. The function can only ever
delete chunks, and only in the domain that asked.

No chunk leaves the region to be checked.

### When a delete is outstanding

A delete request is cleared only once every chunk it names is gone, so a partial or
failed run leaves it behind. Nothing retries on its own.

`tsync gc --status` lists what is outstanding, and `tsync gc --retry-jobs`
re-delivers it.

An outstanding request means a copy is still holding chunks nothing references —
wasted space rather than lost data.

### If you wire the trigger yourself

With `manage_notifications = false` (AWS) the notification is yours to set up, and it
has to cover deletes as well as chunk writes.

A collection hands its work to any s3 or gcs copy, so a trigger that misses
`tsync/gc-jobs/` leaves requests nobody consumes.

For the same reason, no lifecycle rule may expire anything under `tsync/gc-jobs/`: a
request there is a delete that has been promised and not yet made.

A store can also be deployed with `deploy_share = false`: this half alone, with no
share endpoint and no public URL. That is a module-level option rather than a
`tfvars` one — `terraform/ci/` uses it, so the conformance suite has something real
to trigger without an unauthenticated URL over a test bucket.

---

## Remote state

State lives in a remote bucket — **either** S3 **or** GCS, whichever cloud you're on.
The two are independent alternatives, and unrelated to which *store* backends you
provision.

The repo ships both as `backend-*.tf.example`; you activate exactly one.

Because the state bucket must exist first, a tiny `bootstrap-*` config creates it,
keeping its own state locally.

`init.sh` automates whichever one you pick. By hand:

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

The gcs backend locks state on its own (via the object's generation) — no lock table
needed.

`backend.hcl` and the activated `backend-*.tf` are git-ignored so your choice stays
local; only the `.example` templates are committed.

If you'd rather not use remote state at all, don't activate either — `terraform init`
uses local state.

### Credentials are in Terraform state

The client credentials are generated by Terraform, so the secrets live in your state:
S3 access keys for s3 stores, service-account JSON keys for GCS stores.

Keep state in the remote bucket above — encrypted for S3, private/UBLA for GCS. Treat
that bucket as sensitive and restrict access to it.

Rotate a key by replacing it:

```
terraform apply -replace='module.store["files"].aws_iam_access_key.client'
terraform apply -replace='module.store_gcs["files"].google_service_account_key.client'
```

---

## Multi-region

All S3 stores use `var.region`. Bucket region comes from the provider, so buckets in
**different** regions need a provider per region.

Add an aliased provider and a second module call, or a second root/workspace. Sketch:

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

Same-region redundant buckets are just extra `stores` entries — no provider needed. On
GCS, `location` is per store, so nothing special is required.

---

## The function source

Both functions live at the repo top level in [`../lambda/`](../lambda/); this config
packages and deploys them. One zip serves both clouds and both roles — the entry
point and a `STORE` environment variable pick which.

Test them locally from the repo root:

```
python3 -m venv .venv && . .venv/bin/activate
pip install boto3 moto pytest
pytest lambda/test_handler.py
```

The GCS-side tests (`test_store_gcs.py`, `test_verify_gcs.py`) additionally need
`google-cloud-storage`.
