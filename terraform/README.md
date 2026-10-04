# tsync stores (Terraform)

Single point of entry for provisioning the cloud storage behind a tsync domain, on
**AWS (S3)** or **Google Cloud (GCS)**. What it has to provision, and why, is specified
in [`docs/spec/11-infrastructure.md`](../docs/spec/11-infrastructure.md).

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
- [Testing this configuration](#testing-this-configuration)

---

## Quick start

Interactive setup — asks which cloud, defines your first store in `terraform.tfvars`,
creates the bucket that holds the state, activates the matching backend, and
initialises the deployment against it:

```
./init.sh
tofu apply
```

**Either CLI works.** Everything here applies unchanged with OpenTofu (`tofu`) or
Terraform (`terraform`), 1.10 or later. Commands below are written with `tofu`. The
scripts and `tsync config --edit` all pick the same one: the program named by
`TSYNC_TF` if you set it, otherwise `tofu` if installed, otherwise `terraform`.

Then wire the store into a tsync domain. The easy path is `tsync config --edit`: edit
the s3 or gcs domain and choose **Sync from Terraform**.

That reads the deployment's outputs, asks which store when there are several, and
writes its fields onto the backend. Nothing Terraform-specific ends up in your tsync
config.

---

## A complete store

Each block below is a whole `terraform.tfvars`. The two clouds take the same shape —
a map of stores, keyed by a short logical name — and differ only in the top-level
settings and a handful of per-store options.

### S3

```hcl
region = "us-east-1"

stores = {
  # Map key = short logical name. It suffixes IAM and Lambda resource names and
  # keys the outputs, so keep it short, and unique across stores and gcs_stores —
  # it is not the tsync domain name.
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
      "Photos" = { after_days = 180, storage_class = "STANDARD_IA" }
    }
  }

  # A store in another region, with no share endpoint: just the bucket, the
  # client credentials and the integrity check.
  backup = {
    bucket = "my-tsync-backup"
    region = "eu-west-1"
    share  = false
  }

  # Point at a pre-existing bucket instead of creating one. Its access settings
  # are left alone — but its lifecycle and notifications are taken over unless
  # told otherwise, so see "Working with an existing bucket" below.
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

On GCS, lifecycle is part of the bucket: a bucket the store created has its lifecycle
managed, always, and an adopted bucket's lifecycle is never touched. So `gcs_stores`
has no `manage_lifecycle` and no `extra_lifecycle_rules`, and `archive_domains` needs
a created bucket.

### Store options

`bucket` is the only required one; everything else has a default. These work on both
clouds, under the same names:

| Option | Default | |
| --- | --- | --- |
| `bucket` | — | required |
| `create_bucket` | `true` | false = use a bucket that already exists |
| `share` | `true` | false = no share endpoint: credentials and integrity check only |
| `custom_domain` | none | vanity host for share links |
| `archive_domains` | `{}` | per-domain cold storage |
| `presign_ttl` | `300` | lifetime (s) of a signed download URL |
| `max_share_bytes` | 8 GiB on S3, 1 GiB on GCS | largest file or folder a link serves |
| `share_memory_mb` | `2048` | memory for the share endpoint |
| `verify_timeout_seconds` | `120` | stall guard on an integrity check |
| `verify_memory_mb` | `512` | memory for one integrity check |
| `verify_max_concurrency` | `32` | integrity checks running at once |

S3 only: `region`, `iam_user_name`, `manage_lifecycle`, `extra_lifecycle_rules`,
`manage_notifications`, `share_scratch_mb`.

GCS only: `location`, `function_region`.

---

## Wiring a store into tsync

`tsync config --edit` → **Sync from Terraform** does this for you. By hand, read the
outputs — both are keyed by store name, whatever the cloud:

```
tofu output stores
tofu output -json store_secrets | jq '.["files"]'
```

Each entry's members are named like the backend's fields, so the two merge into a
backend as they are, minus `type`. For an s3 store:

```json
{
  "type": "s3",
  "bucket": "...",
  "region": "...",
  "accessKeyId": "...",
  "secretAccessKey": "...",
  "shareUrl": "...",
  "role": "main"
}
```

and for a gcs store `bucket`, `serviceAccountKey` and `shareUrl`. A store deployed
with `share = false` reports no `shareUrl`.

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

A file or folder is refused with a 413 above `max_share_bytes`, and the build has to
finish within 15 minutes.

A folder is zipped inside the function before it is uploaded, which is what the
default follows: 8 GiB on S3, where the function has a 10 GB disk, and 1 GiB on GCS,
where it only has its memory. The ceiling has to leave room there — 1 GiB of
`share_scratch_mb` on S3, 512 MB of `share_memory_mb` on GCS — and a store asking for
more is refused at plan time. On GCS, raise the two together.

### A vanity domain for share links

By default share links use the raw function URL. Set `custom_domain` on a store to
serve them from your own host instead (`https://tsync.example.org/<token>`); that
store's `share_url` output then points at the domain.

Stores without `custom_domain` are unchanged — no extra infrastructure, cert, or DNS.
A store with `share = false` cannot have one.

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
tofu apply -target='module.store["files"].aws_acm_certificate.share[0]'

# 2. Read the validation CNAME and add it at your DNS provider.
tofu output -json custom_domain_dns   # { "files": { domain, records } }
```

Publish the one record listed, then run the full `tofu apply`. It waits for ACM to
issue the cert — usually a minute or two once the record resolves.

Once apply completes, `records` holds a second entry: the CNAME from your domain
(`tsync.example.org`) to its target. Publish that one too.

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
tofu apply
tofu output -json custom_domain_dns   # { "media": { domain, records } }
```

`records` stays empty until the mapping leaves `PENDING`; re-run `tofu refresh` if
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
  "Photos" = { after_days = 180, storage_class = "STANDARD_IA" }
}
```

`storage_class` defaults per cloud: `GLACIER_IR` on S3, `ARCHIVE` on GCS. Only classes
a chunk can be read from at once are accepted, since opening a file reads its chunks:
`STANDARD_IA`, `ONEZONE_IA`, `INTELLIGENT_TIERING` and `GLACIER_IR` on S3, and
`NEARLINE`, `COLDLINE` and `ARCHIVE` on GCS. S3's `GLACIER` and `DEEP_ARCHIVE` need a
restore first and are refused. An empty
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

`create_bucket = false` adopts a bucket instead of creating one. Its access settings
are left alone.

On AWS two of its settings are still taken over, and there is no partial version of
either: `tofu apply` **replaces** the bucket's whole **lifecycle** configuration and
its whole **notification** configuration. `init.sh` shows you both before you apply.
Check by hand with:

```
aws s3api get-bucket-lifecycle-configuration --bucket YOUR_BUCKET
aws s3api get-bucket-notification-configuration --bucket YOUR_BUCKET
```

For existing lifecycle rules, use one of the two options below. For existing
notifications, set `manage_notifications = false` and see
[If you wire the trigger yourself](#if-you-wire-the-trigger-yourself).

On GCS nothing is taken over. An adopted bucket's lifecycle stays yours, so add the
one rule every store needs by hand: abort incomplete multipart uploads after 1 day.

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
        storage_class = string          # any S3 storage class
      }]
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

**Rules that reach `tsync/`.** A rule whose prefix can match a key under `tsync/` —
a whole-bucket rule, or one on `tsync/…` — is refused at plan time if it expires
anything, or transitions to a class that needs a restore (`GLACIER`,
`DEEP_ARCHIVE`). Expiring there loses data, or a delete that was promised and not yet
made; a restore class makes files unreadable.

A whole-bucket transition to an online class, like the Glacier Instant Retrieval one
above, is accepted, but it sweeps up a store's bookkeeping and its share cache too —
precisely what `archive_domains` is careful to leave in the standard class. If chunks
are what you want archived, reach for `archive_domains`.

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

A failed check is not retried by the cloud: a missed one is caught by the next full
re-check.

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

A store can also be deployed with `share = false`: this half alone, with no share
endpoint and no public URL. `terraform/ci/` uses it, so the conformance suite has
something real to trigger without an unauthenticated URL over a test bucket.

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
tofu -chdir=bootstrap-s3 init
tofu -chdir=bootstrap-s3 apply -var state_bucket=my-tsync-tfstate -var region=us-east-1

# 3. Point the main config at it and initialize.
cp backend-s3.hcl.example backend.hcl   # then edit bucket/region
tofu init -backend-config=backend.hcl
```

Locking uses S3 natively (`use_lockfile`, either CLI ≥ 1.10) — no DynamoDB table.

### GCS

```
# 1. Activate the GCS backend.
mv backend-gcs.tf.example backend-gcs.tf

# 2. Create the state bucket (versioned, uniform access, private).
tofu -chdir=bootstrap-gcs init
tofu -chdir=bootstrap-gcs apply -var project=my-gcp-project -var location=US -var state_bucket=my-tsync-tfstate

# 3. Point the main config at it and initialize.
cp backend-gcs.hcl.example backend.hcl  # then edit bucket
tofu init -backend-config=backend.hcl
```

The gcs backend locks state on its own (via the object's generation) — no lock table
needed.

`backend.hcl` and the activated `backend-*.tf` are git-ignored so your choice stays
local; only the `.example` templates are committed.

If you'd rather not use remote state at all, don't activate either — `tofu init`
uses local state.

### Credentials are in Terraform state

The client credentials are generated by Terraform, so the secrets live in your state:
S3 access keys for s3 stores, service-account JSON keys for GCS stores.

Keep state in the remote bucket above — encrypted for S3, private/UBLA for GCS. Treat
that bucket as sensitive and restrict access to it.

Rotate a key by replacing it:

```
tofu apply -replace='module.store["files"].aws_iam_access_key.client'
tofu apply -replace='module.store_gcs["files"].google_service_account_key.client'
```

---

## Multi-region

An S3 store takes its own `region`; without one it is in the deployment's `region`.
The bucket, both functions and a vanity domain's certificate all follow it:

```hcl
region = "us-east-1"

stores = {
  files    = { bucket = "my-tsync-files" }
  files-eu = { bucket = "my-tsync-files-eu", region = "eu-west-1" }
}
```

On GCS, `location` and `function_region` are per store in the same way.

---

## The function source

Both functions live at the repo top level in [`../lambda/`](../lambda/); this config
packages and deploys them. One zip serves both clouds and both roles — the entry
point and a `STORE` environment variable pick which. What goes into it is defined
once, in `modules/package`, and it holds the runtime files only: no tests, no caches.

Test them locally from the repo root:

```
python3 -m venv .venv && . .venv/bin/activate
pip install boto3 moto pytest
pytest lambda/test_handler.py
```

The GCS-side tests (`test_store_gcs.py`, `test_verify_gcs.py`) additionally need
`google-cloud-storage`.

---

## Testing this configuration

The plan-level tests need no account and no credentials: they plan against mocked
providers and check what the configuration accepts and refuses.

```
tofu init -backend=false
tofu test
```
