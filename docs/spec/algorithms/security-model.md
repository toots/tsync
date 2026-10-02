# Security model

This file owns who tsync trusts, for what, and every mechanism that enforces it. Each mechanism is stated once here; the files that implement a mechanism link to the section. Formats stay with their owners: the key and domain-name grammar in [01-core](../01-core.md), backend byte formats (share manifests included) in [02-remote-model](../02-remote-model.md), the http-proxy wire in [backends/http-proxy](../backends/http-proxy.md), the IPC contract in [07-daemon-cli](../07-daemon-cli.md). Failure kinds are those of [the failure model](failure-model.md).

OCaml notes: [ocaml/algorithms/security-model.md](../ocaml/algorithms/security-model.md).

---

## 1. Actors and trust boundaries

| Actor | Holds | Trusted for |
|---|---|---|
| **Owner user** | The local account running tsync: config, secrets, local state | Everything on this host's tsync state. |
| **Local client** | The same account's CLI, tray, file-manager plugin, app | What the owner user may do. A **sandboxed** client (the macOS File Provider extension) is trusted only for the paths its sandbox grants (§7). |
| **Other local users** | Accounts on the same host | Nothing, unless a mount explicitly grants them read access (§8). |
| **Domain writer** | Write credentials to a domain's store, or the http-proxy secret of that domain | The whole content and metadata of that domain. Writers of one domain trust each other completely (§3.2). |
| **Proxy client** | One domain's http-proxy secret | That domain's objects on that listener, and nothing else: not other domains, not the listener host's files, not other domains' shares (§4, §5). |
| **Share recipient** | A share link | Reading one file or one folder of one domain until the link expires or is revoked (§6). |
| **Storage provider** | The bucket, disk or NAS | Durability and access control of the objects. It sees plaintext (§3.1). |
| **Network** | Any path between a tsync client and a store or listener | Nothing. |
| **Anonymous internet** | Reach to a listener's port | Fetching the status login page and share links; nothing else (§4.6, §11). |

Trust boundaries, each an enforcement point in this file:

- B1. Listener socket: anonymous network ↔ http-proxy server (§4, §10, §11, §12).
- B2. Route: one proxy client's secret ↔ another domain on the same listener (§5).
- B3. Store key ↔ host filesystem: a key naming an object ↔ a path on this machine (§5.3).
- B4. Share token ↔ domain (§6).
- B5. Local socket: another local account or a sandboxed client ↔ the owner process (§7).
- B6. Mount: other local users ↔ the owner's files (§8).
- B7. Wire: the network ↔ requests and answers (§9).
- B8. Secrets at rest: config and platform backups ↔ anyone who reads them (§10).

---

## 2. Assets

1. Domain content and metadata: file bodies, names, folder structure, versions, journal.
2. Credentials: store credentials, http-proxy secrets, share tokens.
3. The listener host's filesystem outside its stores.
4. Local state: mirror, staged bodies, chunk cache, WAL, queues. Staged bodies are the only copy of unpublished data.
5. Operational information: status reports, domain names, traffic, backend settings.

---

## 3. Threat model

### 3.1 Non-goals

- **Confidentiality from the storage provider.** Objects are stored in plaintext. Whoever administers the bucket, disk or NAS can read every file, name and journal entry. Encryption at rest is the provider's or the volume's.
- **Integrity against a domain writer.** A holder of write access to a domain can replace, delete or corrupt anything in it, including version history. tsync keeps conflicted copies and versions against *accidents*, not against a hostile writer.
- **Chunk keys as a security property.** Chunk keys are two seeded 64-bit non-cryptographic hashes ([01-core](../01-core.md)). They detect accidental corruption and drive deduplication. An adversary with write access to the store can craft colliding content and poison deduplication for every writer of the domain. Nothing in tsync MAY rely on a chunk key to authenticate content against an adversary.
- **Replay of a captured request within the freshness window** (§4.2) by a party that can read requests on the path. TLS (§9) is what keeps requests from being captured.
- **Availability against a network attacker.** A party that can reach the listener can use its bounded resources (§11). Exposure is controlled by the bind address and the operator's firewall.
- **A compromised owner account.** Anything running as the owner user can read the config and act as tsync.

### 3.2 What is relied on

| Property | Mechanism |
|---|---|
| Only holders of a domain's secret act on that domain through a listener | HMAC-SHA256 request authentication (§4) and domain confinement (§5) |
| A request or answer on the network is not read or altered | TLS with certificate and hostname verification (§9) |
| No key reaches outside its store's root or its domain | Key grammar validation at every boundary (§5) |
| A share grants exactly one domain's file or folder, for a bounded time | 128-bit random tokens, manifest validation, expiry, revocation (§6) |
| Only the owner account (and its clients' granted paths) reaches the owner process | Socket directory modes and peer-credential checks (§7) |
| Secrets are not readable by other accounts or copied off the device | File modes set at creation, backup exclusion, masking (§10) |
| Content served to a browser cannot script the listener's origin | Output escaping and sandboxing headers (§12, §13) |

---

## 4. Request authentication (http-proxy)

The wire format is owned by [backends/http-proxy §3](../backends/http-proxy.md#3-authentication); this section states the security requirements it meets.

### 4.1 Signature

- Every request other than the unsigned ones (status login page, share links) MUST carry a timestamp and an HMAC-SHA256 signature keyed with the domain's secret, over the method, the canonical request target, the timestamp and the SHA-256 of the body. The canonical encoding is specified byte-exactly in the wire file so any language can sign and verify.
- The signature binds every parameter: range offsets, claim flag, watch parameters, listing prefixes, copy source and destination. A parameter that changes behaviour MUST travel in the signed target or body, never in an unsigned header.
- Verification MUST compare in constant time and MUST refuse a signature of the wrong length or case.
- A failed verification MUST be indistinguishable, in status and body, from an unserved domain (§5.2), so an unauthenticated prober cannot enumerate domain names.

### 4.2 Freshness and replay

- The server MUST refuse a request whose timestamp is not a decimal integer or differs from its clock by more than `max_clock_skew` (300 s; MUST NOT exceed 900 s). The timestamp is checked before the body is read (§11).
- There is no nonce. Within the window an identical request can be replayed by whoever observed it. The protocol keeps this harmless in two ways: TLS (§9) keeps requests from being observed on the path, and every operation is idempotent for a given request. A replayed mutation can still undo a later write by another request inside the window; this is accepted only because observing the request requires breaking TLS or controlling an endpoint.
- A new non-idempotent operation MUST NOT be added to the protocol without a nonce and a server-side replay cache.

### 4.3 Answers

Answers are not signed. Their integrity rests on TLS alone, which is why TLS is required off loopback (§9).

---

## 5. Domain confinement

### 5.1 Names

- Keys and prefixes ([01 §2.1](../01-core.md#21-store-keys-and-prefixes)), domain names ([01 §2.2](../01-core.md#22-domain-names)), leaf names ([01 §2.3](../01-core.md#23-leaf-names-and-logical-paths)) and folder ids ([01 §2.5](../01-core.md#25-folder-ids)) have their grammars in 01-core. Reserved domain names are refused there because a domain named like a sibling root (`shares`, `corrupted`, `verify-jobs`, `gc-jobs`) would alias another domain's roots or the share space.
- Every value in the table below MUST be checked against its grammar **where it enters**, before it is used to form a key, a path or a URL.

| Enforcement point | Checked value | On failure |
|---|---|---|
| Config load, every host | Domain names (reserved names refused, unique ignoring case); backend and frontend names used in local paths | Config refused |
| Every store operation, every driver | The key or prefix the operation is given | INVALID, before any request or system call |
| Every listing, every driver | Each listed name | Omitted from the listing with a warning; never mapped to a path |
| http-proxy server, before routing | Every key and prefix of every operation: object key, bulk list elements, `copy` source and destination, listing and capability prefixes, watch key | 400 |
| http-proxy client | Every key in a bulk answer | CORRUPT |
| Any reader of a store | Chunk keys from manifests; folder ids from markers, anchors and share manifests; keys in delete-job bodies; names in journal entries and folder indexes | CORRUPT; the item is skipped, never used |
| Request handler (IPC) | Item references, leaf names, `staging` and `dest` paths (§7.3) | `invalid` / `denied` |
| Share server | Token; `path` components; manifest's domain, key and folder id (§6.3) | 400 / 404 |

A key read back from one store and written to another (mirror, backfill, replica, repair, garbage collection, import) is validated before the write. This is what keeps a hostile or damaged store from steering a write outside a domain or outside a local store's root.

### 5.2 Routes on a listener

- A route owns exactly its domain's four roots `tsync/<d>/`, `tsync/corrupted/<d>/`, `tsync/verify-jobs/<d>/`, `tsync/gc-jobs/<d>/`, plus the share space restricted as in §6.4. Because domain names are validated, these roots are disjoint across routes.
- The server MUST check **every** key and prefix an operation names against the route selected by the first one, and refuse the whole operation if any is outside. It MUST NOT narrow a request to its permitted part.
- A request for a key under no served route MUST be answered exactly as a failed signature (§4.1).

### 5.3 Filesystem-mapped stores

A store that maps keys to files (the local driver, a NAS mount, any cache filed by key) MUST refuse any key that would resolve outside its root, independently of the checks above:

1. Lexically: a key with an empty, `.` or `..` segment, a leading `/`, a NUL byte or a platform path separator other than `/` is refused before any system call.
2. Physically: the driver MUST NOT follow a symbolic link at or below its root. It resolves beneath the root (an openat-beneath primitive that refuses links, or refusing symbolic links on every component it creates or opens), so a link planted inside the store cannot redirect a read or a write.

A key given to an operation that fails either check is INVALID; a listed name that fails is omitted (§5.1). Neither is ever ABSENT.

---

## 6. Share capabilities

The share operation surface is in [05-ops-config §4.11](../05-ops-config.md#411-share); the share entity, its validity and what it follows in [data-model/backend §2.18](../data-model/backend.md#218-share); the manifest bytes in [02-remote-model](../02-remote-model.md); serving in [frontends/http-proxy](../frontends/http-proxy.md). The rules below apply to every share server, including a cloud function serving a bucket's share links, and every share-creating host.

### 6.1 Token

- A token is 16 bytes from the platform CSPRNG, written as 32 lowercase hex characters. It is the only credential for the link.
- A token that is 1–31 lowercase hex characters: servers SHOULD serve it (meaning an ordinary link); creators MUST NOT produce it. Every token a creator writes, generated or caller-chosen, is 32–128 lowercase hex characters.
- Creating a share MUST NOT overwrite an existing manifest. A caller-supplied token is written with the store's conditional create, and a token already taken is refused with EXISTS unless the existing manifest is byte-identical; a store that cannot create conditionally refuses the caller-supplied token. A generated token cannot collide and MAY be written with a plain put.
- Tokens MUST NOT appear in logs above debug level, in status reports, or in listings served through a listener (§6.4).
- **Revoke** is an operation of its own: it deletes the manifest by token or URL, then the share's token-keyed artifacts.

### 6.2 Lifetime

- Every manifest carries an expiry. The default is `share_default_ttl` (7 days). A caller MAY choose a longer finite lifetime; there is no unbounded share.
- A manifest whose expiry is missing, non-numeric or in the past is expired (410). An expiry in fractional seconds: readers SHOULD accept it (meaning that instant); writers MUST write whole seconds.
- **Revocation**: deleting the manifest revokes the link at once for every server. A server-issued redirect to a presigned URL (cloud function) MUST expire within `share_presign_ttl` (5 min) and never after the share.
- Expired manifests and their cached artifacts are removed by retention ([gc.md §4.5](gc.md#45-shares)).
- A folder share grants the folder **as it is at each request**, later additions included, until expiry, revocation or trashing of the folder ([data-model/backend §2.18](../data-model/backend.md#218-share)).

### 6.3 A share never leaves its domain

A server serves a manifest only if it passes the validity rule of [data-model/backend §2.18](../data-model/backend.md#218-share) (version 1, a valid domain name, a file key inside that domain's manifest area, a valid folder id) and, in addition, names a domain this server serves (on a listener: the domain of the route asked). Otherwise it answers as for a corrupt manifest (502) or, for another domain, an absent token (404).

Every name the share server resolves inside a folder share goes through that domain's folder namespaces on the store, applying the anchor rule ([data-model/backend §6.3](../data-model/backend.md#63-settling-the-anchor-decides)): a disowned marker is absent, and a trashed shared folder is no longer served. Nothing goes through a path or the local mirror. `path` components that are empty, `.` or `..` are refused (400).

### 6.4 The share space on a listener

The share space `tsync/shares/` belongs to no domain, so its keys are confined by content:

- **Write** (`PUT` of `tsync/shares/<token>`): the server MUST parse the body as a share manifest and accept it only if §6.3 holds for the route's domain and any manifest already at the key names the same domain. Otherwise 401.
- **Read and delete** of a manifest key: allowed only if the stored manifest names the route's domain; otherwise answered as a failed signature. Deleting an absent manifest is success (204).
- Cache artifacts live under `tsync/shares/cache/`. A share-space key that is neither `tsync/shares/<token>` nor under `cache/`: readers SHOULD accept it (meaning a cache artifact); writers MUST NOT produce it.
- **Listing** the share space through a listener MUST return only cache artifacts, never manifest keys: a listing of tokens would hand out every domain's links.
- **Cache artifacts** are rebuildable from the chunks; any route MAY list, read or delete them.
- Bulk operations MUST NOT name manifest keys; a bulk list containing one is refused whole (401).

A domain writer with direct store credentials can still write any share manifest in a bucket shared by several domains; such writers are mutually trusted (§3.1).

---

## 7. Local IPC access control

### 7.1 Socket directory and files

- The directory holding sockets MUST be created with mode 0700 by whichever process creates it first, and every process that binds a socket MUST verify before binding that the directory is owned by its own uid and grants no group or other access. A directory that fails the check is refused (the process does not serve), never silently repaired.
- A socket file MUST be created with mode 0600 (restrictive umask around bind).
- Directories holding local domain state (data dir, cache root, staged tree, queues) follow the same rule: 0700, owned by the owner uid, checked at open.

### 7.2 Peer credentials

On every accepted connection the server MUST read the peer's credentials from the kernel and refuse the connection unless the peer uid equals its own. File modes alone are not relied on: a directory created by another program or a misconfigured service may be wider.

### 7.3 Paths passed over IPC (confused deputy)

Some clients are less privileged than the owner process (the sandboxed macOS extension; any future sandboxed client). A request may carry file paths (`staging` for a write adopted by rename, `dest` for a file the core writes). The owner process MUST NOT use its own privileges on a path the client could not have used:

- Each host declares, per client kind, a **staging root** and a **destination root**. A path outside the declared root is refused `denied`. A host with no sandboxed clients MAY declare the owner's home as both roots. A host whose socket only its own clients can reach, and whose sandboxed client receives files in a directory the owner cannot learn, MAY declare no roots and rely on the rules below: on macOS the App Group container is that boundary (only the app, the extension and unsandboxed processes of the user reach the socket), and the File Provider temporary directory has no location the owner could derive ([file-provider §4.4](../frontends/file-provider.md#44-transfer-paths)).
- The path's parent is resolved without following symbolic links and MUST lie under the root; the final component MUST NOT be a symbolic link.
- `staging` MUST be a regular file owned by the owner uid. It is adopted by rename within the same filesystem; it MAY have other hard links (the system's own name for the file).
- `dest` MUST NOT exist: the core creates it exclusively, without following links, mode 0600. It never overwrites.

---

## 8. FUSE multi-user access

- By default a mount is reachable only by the mounting user.
- `allowOther` makes the mount reachable by other users. It MUST always be combined with kernel permission checking (`default_permissions`), so access follows the ownership and modes the mount reports, never more.
- Ownership and modes are explicit configuration (`uid`, `gid`, `fileMode`, `dirMode`, [fuse §2.1](../frontends/fuse.md#21-options)), defaulting to the mounting user as owner with modes 0644 (files) and 0755 (directories): read-only for everyone else.
- While the configuration grants write access to the mounting user alone (reported uid is the mounting user's and neither mode has a group or other write bit), the filesystem MUST also refuse every mutating call whose caller uid is not the mounting user's with `EACCES`, independently of the kernel check. A configuration that grants others write access is an explicit decision to let the kernel's check be the only one.
- A read-only domain clears every write bit, whatever the configured modes.
- Request-handler actions reach the mount's owner only over the owner-only socket (§7), never through the mount.

---

## 9. TLS

- A client MUST use TLS to reach a listener or store whose host is not a loopback address. An `http://` URL to a non-loopback host MUST be refused at config validation.
- The server certificate MUST be verified against a trust store, with hostname verification. There is no option to disable verification.
- **Trust store**: the platform's system store by default, read at connection setup or reloaded at least at every process start. On Android it is the platform's system CA store only: user-installed CAs MUST NOT be trusted (a user-installed CA is a common interception vector, and apps do not trust them by default); a private CA is trusted only when configured explicitly (`ca_certificate`, below). Cleartext traffic is disallowed except to loopback.
- **Private CA**: a backend MAY name a PEM bundle (`ca_certificate`). The server certificate MUST then chain to a certificate in that bundle, which replaces the system store for that backend only. Hostname verification still applies.
- A listener serving plaintext MUST bind only loopback addresses unless its `bind` option names another address explicitly (a TLS terminator on another host). The operator accepts that hop.
- A TLS listener loads its certificate and key at start; a missing or unreadable file is fatal to the listener.

---

## 10. Secret handling

### 10.1 Generation and strength

- Setup tools MUST generate http-proxy secrets from the platform CSPRNG: 32 bytes written as 64 lowercase hex characters.
- A configured http-proxy secret shorter than `min_secret_length` (32 characters) MUST be refused by config validation on both client and server. A captured signed request lets an attacker test guesses offline, so a short secret is a weak secret.

### 10.2 At rest

- A file that holds secrets (the config) MUST be created with mode 0600 in a 0700 directory, the mode set on the temporary file at creation, before any byte is written; it is then renamed into place ([durable-queue](durable-queue.md) write rule). Changing the mode after writing leaves a window where it is readable.
- A process loading the config MUST refuse (or, interactively, warn and fix) a config readable by group or other.
- Platform backup and device transfer MUST exclude files holding secrets, the client identity and local domain state (a restored identity or WAL on a second device would publish as the first). Android: backup rules excluding them, or backup disabled.

### 10.3 Masking

- Every report that prints configuration (status text and JSON, `tsync config` output, logs) masks secret values as `***`.
- Masking **fails closed**: a field is printed in clear only if its field specification marks it non-secret. A field whose specification is unknown (an unknown driver, a frontend option without a spec, a future field) is masked.
- Signatures, tokens and URLs containing credentials are masked the same way.

### 10.4 In a browser

The status page keeps the secret in page memory only, never in web storage, and signs with the platform's Web Crypto. Outside a secure context (plaintext to a non-loopback origin) it refuses to accept the secret.

### 10.5 Who realises what

These general rules are realised by the hosts, which link here: staging and destination confinement with exclusive `dest` creation (§7.3) by every host with sandboxed clients; cleartext refusal and trust-store refresh (§9) by every client host, Android included; backup exclusion (§10.2) by every host with a platform backup; `default_permissions` with read-only `allowOther` (§8) by the FUSE host; socket modes and peer checks (§7) by every IPC server; config written 0600 from creation (§10.2) by every config writer; share token rules and revoke (§6.1) by the share operation.

---

## 11. Request size and time limits (listener)

Every limit below is enforced **before** the resource it guards is spent. Parameters are listener options with the recommended values shown.

| Limit | Value | Enforced | Answer |
|---|---|---|---|
| Request line + headers | 16 KiB; target ≤ 8 KiB | while reading headers | 431 / 414, connection closed |
| Header read time | `header_timeout` 30 s from accept or previous request | reading headers | connection closed |
| Object `PUT` body | `max_put_body` 256 MiB, MUST be ≥ 4 × the largest chunk size a served domain uses | from `Content-Length` before reading; while reading a chunked body | 413 |
| Bulk request body | `max_bulk_body` 1 MiB | same | 413 |
| Bodies of other requests | empty | same | 400 |
| Bytes of bodies in flight | `max_body_memory` 1 GiB, listener-wide, reserved from `Content-Length` before reading | before reading | 503 `busy` |
| Body and response progress | `idle_timeout` 60 s without a byte in either direction | reading, writing | connection closed; slot released |
| Keep-alive idle | `keepalive_timeout` 75 s (clients close idle connections before it) | between requests | connection closed |
| Open connections | `max_connections` 512 | accept | not accepted until one closes |
| Watch hold | 30 s | §4 of the wire | 204 |
| Concurrent share responses | `max_share_responses` 64 | before headers | 503 |
| ZIP member walk | `max_zip_members` 100 000 | while walking, before headers | 413 |

Timestamp freshness (§4.2) and route resolution are checked before any body byte is read, so a stale or misrouted request costs no body buffering. Request bodies are then read into memory within the reservation, hashed, and verified before execution.

---

## 12. Status and discovery authorisation

- `/domains`, `/stats` and the status JSON answer a signed request with **only the domains whose secret verifies it**: their sections, their frontend entries, their traffic. The process block lists only those domains in `serves`. Other domains' names, settings and counters are never disclosed.
- A request no route's secret verifies is refused 401.
- Control-socket status requests (§7) are owner-only and see everything.

---

## 13. HTML and browser-facing output

Applies to every page and header a listener or share function serves.

- **JSON inside HTML.** A value embedded in a `<script>` element MUST be serialised with `<`, `>`, `&`, U+2028 and U+2029 escaped as `<`, `>`, `&`, ` `, ` `, or delivered in a non-executable `<script type="application/json">` element read as text.
- **Text and attributes.** Values placed in HTML text or attributes MUST escape `&`, `<`, `>`, `"` and `'`.
- **Single-pass templating.** Placeholders are replaced in one pass over the template; a substituted value is never scanned for placeholders.
- **Served file bytes** (a shared file shown inline or downloaded) MUST carry `Content-Security-Policy: sandbox` and `X-Content-Type-Options: nosniff`, so an HTML or SVG file cannot run script on the listener's origin, where the status page lives.
- **Headers.** `Content-Disposition` file names use an ASCII fallback with control bytes, bytes above 126, `"` and `\` replaced, plus an RFC 5987 UTF-8 form. No header value is built from unescaped user data.
- Every HTML page carries `X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer` (a share URL is a credential and must not leak through `Referer`). The status page also carries `Content-Security-Policy: frame-ancestors 'none'`.

---

## 14. Conformance

An implementation MUST exhibit:

- A signed request whose key contains an empty, `.` or `..` segment, or a leading `/`, is refused before any store is touched; every driver refuses the same keys by itself; a filesystem store follows no symbolic link below its root; a listing containing an invalid name omits it.
- A key outside the route, an unserved domain and a bad signature produce the same status and body.
- A bulk operation with one foreign key is refused whole.
- A configuration with a domain named after a reserved root, or containing `/`, is refused.
- A share manifest naming another domain, a file key outside the domain, or the trash folder id, is not served. A proxy client cannot read, overwrite, delete or list another domain's share manifests; share-space listings contain no manifest keys.
- A share with a past or missing expiry answers 410; a revoked share answers 404 at once; a share of a folder that was since trashed is no longer served.
- A caller-chosen token that is taken is refused, not overwritten.
- A socket in a directory with group or other access is not served; a connection from another uid is closed without an answer.
- A `staging` or `dest` path outside its declared root (where one is declared), or through a symbolic link, is refused `denied`; an existing `dest` is not overwritten.
- With `allowOther`, another user can read and cannot create, write, rename or delete.
- A client refuses a non-loopback `http://` URL; a plaintext listener binds loopback unless told otherwise.
- On Android, a server certificate chaining only to a user-installed CA is refused; one chaining to a configured `ca_certificate` is accepted.
- The config is never observable with a mode wider than 0600; unknown fields are masked.
- A request body larger than its limit is refused before it is read; a connection that stops sending is closed after the idle timeout.
- `/stats` signed with one domain's secret mentions no other domain.
- A folder named `</script><script>alert(1)</script>` shown on a browse page renders as text; a shared HTML file served inline runs no script on the listener origin.
