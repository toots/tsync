# 11 — Store infrastructure

Scope: the cloud resources that have to exist around a bucket for it to be a complete tsync store,
and the operator tooling that creates them. This file is the provider-neutral contract.
[infrastructure/aws.md](infrastructure/aws.md) and [infrastructure/gcs.md](infrastructure/gcs.md)
say exactly which resources meet it on each provider; they are normative too, and use this file's
section numbers.

What the bucket-side functions *do* is
[object-store-common §5–6](backends/object-store-common.md). This file owns what is deployed, with
which identity, permissions, limits and trigger.

---

## 1. Vocabulary

| Term | Meaning |
|---|---|
| **deployment** | One applied configuration: any number of stores, on any mix of providers, plus what they share. |
| **store** | One bucket and everything attached to it: a client identity, the verify function and its trigger, optionally the share function and its endpoint, lifecycle rules. |
| **store name** `N` | The operator's short name for a store, unique in its deployment whatever the provider. It builds resource names and keys the outputs; it is not a tsync domain name. |
| **created / adopted** | A created bucket is made and owned by the deployment. An adopted bucket existed before and is named by the operator. |
| **function package** | One archive of the function source, shared by every store, every provider and both functions. |
| **operator** | Whoever applies the deployment, with their own cloud credentials. |
| **operator state** | The provisioning tool's record of what it created, including the client secrets. |

A store is in exactly one provider. One bucket MAY serve several tsync domains
([02 §2](02-remote-model.md)): every key is under `tsync/<domain>/` or under one of the store-level
prefixes `tsync/shares/`, `tsync/corrupted/`, `tsync/verify-jobs/`, `tsync/gc-jobs/`.

## 2. Deployment

- A deployment is a set of stores per provider, each with the options of §10, plus the provider-wide
  inputs its provider file lists.
- A deployment with no store on a provider MUST make no call to that provider and need no
  credentials for it.
- A store name MUST be unique across the whole deployment.
- A store's functions SHOULD run in the bucket's region, or in a region inside its multi-region, so
  that no chunk leaves the region to be checked.
- Anything the provider requires to be switched on before a resource can exist (service APIs) MUST
  be switched on by the deployment, and MUST NOT be switched off when the deployment is destroyed.
  What the deployment cannot do for the operator is listed as a prerequisite in the provider file.

## 3. Function package

- One package serves every store and both functions. It holds the runtime files of the two entry
  modules and nothing else: no test, no cache, no file the working tree happens to hold.
- What goes into the package MUST be defined in one place, used by every configuration that deploys
  a function (§14 included).
- A function MUST be redeployed when the package's content changes, and only then.
- Both functions of a store run the same package on the same runtime. Where the package carries a
  compiled dependency, the function that loads it runs on the architecture it was built for.

## 4. Bucket

- **Created.** Private: public access is blocked by the provider's own switch, not merely absent
  from the permissions. Plain-HTTP requests are denied where the provider can deny them. Everything
  else is the provider's default.
- **Adopted.** Its access settings and permissions already granted are neither read nor changed.
  The deployment adds its own grants, trigger and, where the provider file says so, lifecycle.
- Some bucket settings are one document per bucket, so that writing them replaces what was there.
  The provider file names each such document. Taking one over on an adopted bucket MUST be something
  the operator can decline per document, and the setup script (§13) MUST warn before an existing
  one is replaced.
- Destroying a deployment MUST NOT delete a bucket that holds objects.

## 5. Client identity

The credentials a tsync backend is configured with.

- One identity per store, used by nothing else.
- It MAY read, create, delete and list objects in the store's bucket, and list and abort its
  incomplete uploads. It MUST NOT hold any right over another bucket, nor any bucket or permission
  administration.
- One long-lived secret, held in the operator state (§12). Replacing the secret MUST NOT replace
  the identity.

## 6. Verify function

Every store has one. Its behaviour is
[object-store-common §5](backends/object-store-common.md#5-the-verify-function).

- **Trigger.** Every object created under `tsync/` invokes it: chunks, verification requests and
  collection delete requests alike. One filter on the literal prefix `tsync/` is used, since
  notification filters take one literal prefix and domains sit below it.
- **No retry.** A failed invocation MUST NOT be retried by the trigger or the platform. An event
  waiting for a free slot under the concurrency ceiling is not a failure and MUST be kept for at
  least the provider's default queueing time.
- **Callers.** Only the bucket's own notification may invoke it. It has no public endpoint.
- **Identity.** One identity per store, used by nothing else, with exactly:

  | On | Rights |
  |---|---|
  | `tsync/<domain>/chunks/` | read, delete |
  | `tsync/corrupted/` | create, delete |
  | `tsync/verify-jobs/`, `tsync/gc-jobs/` | read, delete |
  | the bucket | list |
  | its own logs | write |

  It MUST NOT be able to create or overwrite a chunk. Where the provider cannot scope a read or a
  listing by prefix, that read MAY be bucket-wide; the provider file says so.
- **Limits.** Timeout VERIFY_TIMEOUT, memory VERIFY_MEMORY, at most VERIFY_CONCURRENCY concurrent
  executions. The ceiling is what keeps a whole-store verification, 4096 requests deliverable at
  once, from being 4096 concurrent readers.
- **Environment.** The bucket's name, and the provider where the package needs telling.

## 7. Share function

A store has one unless the operator declines it (§10). Its behaviour is
[object-store-common §6](backends/object-store-common.md#6-the-share-function).

- **Endpoint.** One public HTTPS URL, unauthenticated: a link is guarded by its token alone. The
  store's **share URL** is that URL without a trailing slash, or `https://<domain>` with a vanity
  domain (§8).
- **Identity.** One identity per store, used by nothing else, with exactly:

  | On | Rights |
  |---|---|
  | every object | read |
  | `tsync/shares/cache/` | create; delete where assembly needs temporary objects |
  | the bucket | list |
  | itself | sign download URLs, where the provider signs through an API |
  | its own logs | write |

  It MUST NOT be able to write a share manifest (`tsync/shares/<token>`), a chunk, or anything else
  outside the cache.
- **Limits.** Timeout SHARE_TIMEOUT, memory SHARE_MEMORY, and one size ceiling SHARE_MAX_BYTES
  above which a file or a folder is refused. A folder archive is built in the function's scratch
  space before it is uploaded, so the ceiling MUST leave the headroom the provider file states; a
  deployment asking otherwise is refused before anything is applied. §17 says what the ceiling
  could become.
- **Environment.** The bucket's name, the presigned-URL lifetime
  ([security §6](algorithms/security-model.md#6-share-capabilities): `share_presign_ttl`),
  SHARE_MAX_BYTES, and the provider where the package needs telling.
- A store without a share function reports no share URL, and a tsync backend on it carries no
  `shareUrl`.

## 8. Vanity domain

Optional, per store with a share function: the operator's own host name for the share URL. Asking
for one on a store without a share function is refused before anything is applied.

- The provider issues and renews the certificate. TLS 1.2 is the minimum.
- **DNS is never managed.** Any DNS host works; the deployment reports the records to publish
  (§11) and the operator publishes them.
- A store without one has no certificate, no extra endpoint and nothing to publish.

## 9. Lifecycle

- **Abandoned uploads.** Incomplete multipart uploads are aborted ABORT_INCOMPLETE after they
  began, bucket-wide.
- **Archival** is off by default and per tsync domain: an **archived domain** has the objects under
  `tsync/<domain>/chunks/` moved to a colder storage class `after_days` after creation. Nothing else
  is ever transitioned: manifests, versions, the journal and the cursor are read on every sync.
  - The domain is named because it sits in the middle of the key and a rule takes one literal
    prefix. A domain not named is not archived.
  - The key MUST NOT be empty, hold `/`, or be `shares`, `corrupted`, `verify-jobs` or `gc-jobs`.
    It is otherwise free-form, capitals and spaces included.
  - `after_days` MUST be positive, and meet the class's own minimum.
  - The class MUST be one that reads online, with no restore step: a chunk is read by `get_range`
    whenever a file is opened.
- **Nothing under `tsync/` is expired by a rule.** A request under `tsync/gc-jobs/` is a delete
  promised and not yet made; a share carries its own expiration.
- **Operator rules**, where the provider file offers them, are carried beside the store's own. A
  rule that can match a key under `tsync/` MUST NOT expire anything, and MUST transition only to a
  class that reads online; one that does is refused before anything is applied.
- Where the lifecycle cannot be managed without owning the bucket, an adopted bucket's lifecycle is
  the operator's, and the provider file lists the rules to add by hand.

## 10. Store options

| Option | Default | Meaning |
|---|---|---|
| bucket name | required | |
| create the bucket | yes | no = adopt (§4) |
| share function | yes | no = verify function and client identity only (§7) |
| vanity domain | none | §8 |
| archived domains | none | map: domain → `after_days`, storage class (§9) |
| presigned-URL lifetime | `share_presign_ttl` | §7 |
| share size ceiling | SHARE_MAX_BYTES | §7 |
| share memory | SHARE_MEMORY | §7 |
| verify timeout | VERIFY_TIMEOUT | §6 |
| verify memory | VERIFY_MEMORY | §6 |
| verify concurrency ceiling | VERIFY_CONCURRENCY | §6 |

Every store accepts these under the same names. A provider file adds only the options its provider
needs, and every refusal this file calls for happens when the deployment is planned.

## 11. Outputs

What a deployment reports. Member names are the backend's own field names, so that nothing has to
be translated.

| Output | Shape |
|---|---|
| `stores` | store name → `type` (`s3` or `gcs`), and every non-secret field of that driver's backend that the deployment decides: `bucket`, `shareUrl` when there is a share function, and the provider's own (provider file). |
| `store_secrets` (sensitive) | store name → the secret fields of that driver's backend. |
| `custom_domain_dns` | store name with a vanity domain → `domain`, and `records`: a list of `name`, `type`, `value` to publish. |

- Merging a store's `stores` and `store_secrets` entries, minus `type`, gives a complete backend
  entry but for `name`, `role` and `link`.
- Nothing else has to be set on the client: it confirms the verify function itself
  ([object-store-common §3](backends/object-store-common.md#3-confirming-the-bucket-side-function)).
- **The configuration wizard** ([07 §5](07-daemon-cli.md)), offered a deployment directory for an
  `s3` or `gcs` backend, reads the outputs as JSON with the CLI of §13, keeps the stores whose
  `type` is the backend's, asks which when there are several, and fills each field the backend does
  not have yet. Nothing about the deployment is stored in the tsync config.

## 12. Operator state

- The state holds every client secret. It MUST be kept either locally or in a bucket that is
  private, versioned, encrypted at rest and locked against concurrent writers.
- The state bucket MAY be on either provider, whatever the providers of the stores. It is created
  by a separate, minimal configuration whose own state is local and disposable: losing it loses
  nothing.
- Old state versions expire after STATE_VERSION_RETENTION; incomplete uploads as §9.
- Where the state is kept, and in which bucket, is local to the operator's checkout and MUST NOT be
  committed.

## 13. Tooling

- The configuration is written in the Terraform language and MUST apply unchanged with `terraform`
  and with `tofu`, at version 1.10 or later. Every configuration declares that minimum.
- **One rule picks the CLI**, for every script and for the wizard: the program named by the
  environment variable `TSYNC_TF` when set; otherwise `tofu` when installed; otherwise `terraform`.
  With neither, the tool says so and does nothing. No script names either program directly.
- **The setup script** is interactive. It asks the provider, the provider's location inputs, a
  first store's name, bucket and whether to create it, and where to keep the state. It then:
  1. refuses to continue when a different state location is already active;
  2. writes the deployment's variables for that one store, and the state location, each only when
     absent or when the operator agrees to overwrite;
  3. for an adopted bucket, warns when the bucket cannot be reached, and names each document of §4
     that applying would replace;
  4. optionally creates the state bucket (§12);
  5. initialises the deployment against the state;
  6. prints how to review, apply and read the outputs.

  It MUST NOT apply the deployment.

## 14. Conformance stack

What the live-store tier ([10 §3.3](10-delivery.md#33-live-stores)) triggers.

- A configuration of its own with a state of its own, so that applying it cannot reach a
  deployment's stores. Its state MAY share a deployment's state bucket, under a different name, on
  either provider.
- For each provider given a bucket: one store named `ci` on that adopted bucket, with no share
  function and no document of §4 or lifecycle taken over beyond the trigger.
- It uses the store definitions and the package definition of a real deployment (§3), not copies.
- It reports, per provider, the verify function's name and where it runs, or nothing when that
  provider was given no bucket. The provisioning script reads these back rather than assuming them.

## 15. Compatibility

- Applying this specification's configuration over an existing deployment MUST NOT replace a
  bucket, a client identity or its secret, a function's public URL, or a vanity domain: clients keep
  working with the configuration they have.
- Resource names in the provider files are therefore fixed. A resource the ideal configuration
  names differently is moved in the state, never destroyed and recreated.
- The operator's local variables and state location MAY need rewriting by hand.

## 16. Parameters

| Parameter | Value | Meaning |
|---|---|---|
| VERIFY_TIMEOUT | 120 s | One shard walk or one delete request ([object-store-common §5.5](backends/object-store-common.md#55-deployment-requirements)) |
| VERIFY_MEMORY | 512 MB | |
| VERIFY_CONCURRENCY | 32 | |
| SHARE_TIMEOUT | 900 s | One archive build |
| SHARE_MEMORY | 2048 MB | |
| SHARE_MAX_BYTES | provider file | Fits the scratch space, with headroom |
| ABORT_INCOMPLETE | 1 day | |
| STATE_VERSION_RETENTION | 90 days | |

## 17. Open

Not specified, and not required of a deployment:

- **The share ceiling is coarser than what it protects.** A single file is assembled inside the
  bucket and uses neither scratch space nor memory: only a folder archive needs a ceiling. A file
  could be refused only when the function cannot assemble it.
- **Scratch space bounds an archive only because it is built there first.** An archive uploaded as
  it is produced needs a part-sized buffer, and is then bounded by one invocation's time alone.
- **An archive could be sent to the visitor as it is produced**, where the provider's endpoint
  streams responses without a cap, or built outside the visitor's request, which lifts the time
  bound too.

## Conformance

- The configuration validates and plans with `terraform` and with `tofu`, with stores on one
  provider only and no credentials for the other.
- Planning refuses: a duplicate store name; a vanity domain without a share function; a share
  ceiling above what the provider file allows; an archived domain named `shares` or holding `/`; a storage
  class that needs a restore; an operator rule expiring a prefix that covers `tsync/gc-jobs/`.
- The package holds no test file after the test suite ran in the source directory.
- On a store just applied: the client's probe confirms the verify function
  ([object-store-common §3](backends/object-store-common.md#3-confirming-the-bucket-side-function));
  the share URL answers 404 to an unknown token; the client identity is refused on another bucket;
  the verify identity is refused creating a chunk; the share identity is refused creating
  `tsync/shares/<token>`.
- A verify invocation that fails is seen once in the function's log.
- Planning over an existing deployment shows no replacement of the resources of §15.
- With `tofu` and `terraform` both installed, `TSYNC_TF` decides which one every script runs; a
  script run with neither installed changes nothing.
