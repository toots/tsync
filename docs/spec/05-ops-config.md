# 05 — Domain config and whole-domain operations

This file owns:

- the **config schema and its validation**;
- the **Domain Context**: the live domain every subsystem above config is given, and how it is
  built from config;
- the **whole-domain operations** (import, export, rsync, mirror, resync, trash and deleted-file
  listing, expire, gc, integrity, share): their interfaces and semantics.

It does not own: the meaning of roles and the composite's read and write paths
([algorithms/replication.md](algorithms/replication.md)); backend key layout and byte formats
([02](02-remote-model.md)); the collector and expiry rules ([algorithms/gc.md](algorithms/gc.md));
uplink and link settings ([06](06-backends.md)); each driver's fields ([backends/](backends/));
where an operation runs and which process owns the domain ([07 §2](07-daemon-cli.md)). Per-item
operations a frontend calls (read, write, rename, evict, revert) are the file operations
([04 §3.5](04-checkout-cache.md)) and the request handler ([08](08-frontends.md)).

Three things are called "mirror":

| Term | Meaning |
|---|---|
| **the mirror** | this client's local projection of the domain's names ([local-cache.md](data-model/local-cache.md)) |
| **`tsync mirror`** | backend-to-backend copy of a domain's objects (§4.6) |
| **`tsync sync`** | resync: bring the mirror up to date with the store (§4.7) |

Implementation notes: [ocaml/05-ops-config.md](ocaml/05-ops-config.md).

---

## 1. Problem

A **domain** is a name, a set of stores with roles, the frontends that present it, and a few
per-domain policies. Around the per-file engine two things are needed:

1. **A config model**, validated strictly: a typo must never silently leave a store or an option
   unconfigured. And one place where a parsed domain becomes a live one with real stores.
2. **Whole-domain jobs** over whole trees and keyspaces: seeding a domain from a
   folder, writing it out, copying without moving bytes already stored, repairing one store from
   another, rebuilding this client's view, trimming history, reclaiming chunks, checking integrity,
   publishing links. They run in the domain's owner, sent there by their commands; a command runs
   one itself only when no owner is serving ([07 §2.5](07-daemon-cli.md#25-one-shot-commands)).

The operations are applications of the layers below; nothing depends on them but the CLI and the
request handler.

---

## 2. Config

### 2.1 Schema and validation

The config is one JSON object (location: [07 §2.7](07-daemon-cli.md)). Validation rules, applied by
every tool that reads or writes a config (the daemon, every command, the Android app, the wizard):

- **Unknown keys are refused at every level**: top level, each domain, `uplink`, each `links`
  entry, each backend object, and each frontend object. The known set of a backend object is the
  common keys plus its driver's declared fields; of a frontend object, `type` plus its frontend's
  option spec ([08 §2.1](08-frontends.md)).
- **Known types are part of the schema**, whatever this build compiles: every backend type and every
  frontend type of this release, with their fields and options, is known to the parser. An unknown
  type is refused at parse. A known type this build does not include is refused when something tries
  to use it ("configured but not compiled into this binary").
- **Every value has a declared type**, and a value of another JSON type is refused. `null` stands for
  an absent optional value and is refused for a required one.
- **Every error names the JSON path** of the offending value and what was expected:
  `domains[1].versioning: required boolean is missing`,
  `domains[0].backends[2]: unknown key(s) "bukcet"`.
- A tool that parses a config never falls back to defaults for a value it could not read.

**Top level**

| key | type | default | rule |
|---|---|---|---|
| `name` | string | the host name | client name, labels conflicted copies; non-empty |
| `tls` | `"native"` \| `"openssl"` | unset (the build's default) | A build has one or both. The default is OpenSSL when the build has it, else native; naming one the build lacks fails each connection INVALID. `tsync build-info` lists them. |
| `maxUploads` | int ≥ 0 | 4 | concurrent upload files; 0 means the default |
| `maxChunkBuffers` | int ≥ 0 | `maxUploads` | chunk bodies in memory across all uploads; also bounds deferred forwards and `tsync mirror` copies; 0 means the default |
| `maxDownloads` | int ≥ 0 | 8 | concurrent file downloads; 0 means the default |
| `uplink`, `links` | objects | | [06](06-backends.md); a `links` entry naming a link no backend uses is refused |
| `domains` | array | required | |

**Domain**

| key | type | required | rule |
|---|---|---|---|
| `name` | string | yes | the domain-name grammar of [01 §2.2](01-core.md#22-domain-names), which refuses the reserved root names and `/`; unique among domains **ignoring case** (it names directories, sockets and macOS identifiers on case-insensitive filesystems); on macOS, two `file_provider` domains whose identifiers or replica-folder projections collide are refused ([file-provider.md §3.3](frontends/file-provider.md#33-domain-identifier)) |
| `backends` | array | yes | each per the backend object below; then role validation |
| `frontends` | non-empty array | yes | each `"<type>"` or `{"type":"<type>", …options}` |
| `symlinks` | `"keep"` \| `"follow"` \| `"skip"` | yes | |
| `versioning` | bool | yes | |
| `readOnly` | bool | no | false; forced true when no backend has a writable role |
| `chunkSize` | size | no | unset: the main's recommendation, else 8 MiB; within the range of [01 §3.5](01-core.md#35-chunk-size) |
| `cacheChunkSize` | size | no | unset: 16 MiB |
| `maxCache` | size | no | unset: unbounded |

**Backend object**

| key | rule |
|---|---|
| `type` | required; a known backend type |
| `name` | required, non-empty, not `.` or `..`, no `/`; unique within the domain **ignoring case** (it names the target's deferred log directory and its counters) |
| `role` | required: `"main"`, `"replica"`, `"backfill"` or `"readOnly"` ([replication.md](algorithms/replication.md)) |
| `link` | optional non-blank string, trimmed; default `"wan"`; refused on `type: local` (a local store has no link) |
| other keys | the driver's declared fields ([backends/](backends/)), each with its declared type. A field declared as a list (for example an `exec` command) takes a JSON array. A local store's `path` is absolute or starts with `~/`. |

**Role validation.** With no `main`: a `replica` is refused ("a replica is a copy of a source of
truth"); a `backfill` is refused ("nothing to fill it from"); no `readOnly` either is refused
("nothing here can answer a read").

**Frontends.**

- Each type at most once per domain.
- At most one **presenting** frontend per domain ([08 §2.1](08-frontends.md)): one owner process
  hosts it ([07 §2.4](07-daemon-cli.md)).
- Options are checked against the frontend's option spec, by type, and against the rules its spec
  states (for the http-proxy: a secret of at least 32 characters, TLS unless the listener binds
  loopback, [frontends/http-proxy.md](frontends/http-proxy.md)).
- **Booleans**, in frontend options and driver fields alike, take a JSON bool or one of the strings
  `true, 1, yes, on, false, 0, no, off` (any case); any other value is refused. Ints take a JSON int
  or a decimal string.

**Sizes**: a JSON int > 0, or a string: trimmed, lower-cased, a trailing `ib` or `b` removed, an
optional trailing `k|m|g|t` (powers of 1024), the rest a finite number > 0; the result is rounded and
must be > 0. Accepts `512K`, `8M`, `1G`, `1048576`, `8.0 MB`, `1.5 GiB`.

**Serialisation**: a tool that writes a config writes it with mode `0600` from creation, durably
(temp file, fsync, rename, fsync of the directory)
([security-model.md §10.2](algorithms/security-model.md#102-at-rest)). User documentation describes
these rules; it MUST NOT say that unrecognised keys pass through.

**Masking** fails closed: every report masks a field as `***` unless its spec declares it
non-secret ([security-model.md §10.3](algorithms/security-model.md#103-masking)).

Example:

```json
{
  "name": "laptop",
  "maxUploads": 4, "maxDownloads": 8,
  "uplink": { "enabled": true, "headroom": 0.8, "targetDelayMs": 50, "maxRate": "2 MB" },
  "links": { "wan": { "maxRate": "500 KB" } },
  "domains": [{
    "name": "Files",
    "symlinks": "keep", "versioning": true, "chunkSize": "8M", "maxCache": "50G",
    "frontends": ["fuse", {"type": "http-proxy", "port": 8080, "secret": "…", "shares": true}],
    "backends": [
      {"type": "s3", "name": "cloud", "role": "main", "bucket": "…", "accessKeyId": "…",
       "secretAccessKey": "…", "shareUrl": "https://…"},
      {"type": "local", "name": "backup", "role": "backfill", "path": "/mnt/backup"}
    ]
  }]
}
```

### 2.2 Domain resolution

Everywhere a domain is picked: an explicit name → the recorded default domain if it is configured
→ the sole configured domain. Errors: "no domains configured", "multiple domains configured — use
--domain to select", "domain not found: X".

---

## 3. The Domain Context

### 3.1 Interface

An immutable value handed to every subsystem working on one domain, one per domain per process:

| field | meaning |
|---|---|
| `domain_name`, `client_name`, `versioning`, `read_only`, `symlink_policy` | from config |
| `domain_prefix`, `chunk_prefix`, `versions_prefix`, `journal_prefix`, `shares_prefix`, `cursor_key` | key names ([02](02-remote-model.md)) |
| `cache_root`, `data_dir`, `socket_path` | local paths ([07 §2.7](07-daemon-cli.md)) |
| `max_uploads`, `max_chunk_buffers`, `max_downloads` | concurrency budgets |
| `chunk_size`, `cache_chunk_size`, `max_cache` | unresolved config values |
| `store` | the **composite** store ([06](06-backends.md)) |
| `members` | the individual stores in role order, each with the store interface and `{name, role, readable, type, masked config, link, deferred stats, traffic, local_path}` |

- Everything that reads or writes a domain key goes through `store`. `members` is for a caller that
  needs one store, not the domain: a report, `tsync mirror`, share placement, the collector,
  integrity repair.
- `capacity(members)`: among non-`readOnly` members with a local path, the disk-space record of the
  one with the least available space (the whole record from one disk); none if no member is local.
- `chunks_per_group(chunk_size, cache_chunk_size)` = 1 if `chunk_size` ≤ 0, else
  `max(1, round(cache_chunk_size / chunk_size))`.

Derived contexts:

- `reading_from(name)`: every read entry point (single and batched reads, ranged reads, heads,
  listings, `watch`, health) goes to the named member; writes still go through the composite, so
  deferred targets still fill. An unknown name fails; so would an ambiguous one, which validation
  rules out.
- `reading_at_most(n)`: `max_downloads := n`; n < 1 fails.

### 3.2 Building a domain

1. Resolve the domain (§2.2) and its socket path.
2. Configure the process's uplink governor from `uplink` and `links`, once per process
   ([06](06-backends.md)).
3. For each backend, in role order ([replication.md](algorithms/replication.md)): fresh traffic
   counters; its link's admission; **one** store client (every layer above shares it: two clients
   against one store would be two sets of health and limits); an uplink probe for remote stores.
4. Build the composite: mains; `readOnly` archives; each `replica` and `backfill` as a deferred
   target whose job log lives at `<data_dir>/deferred-pending/<domain>/<escaped backend name>/`,
   which forwards a manifest only after its chunks and never forwards folder indexes.
5. Build the members.
6. **Deferred logs are resumed only by the domain's owner** ([07 §2.2](07-daemon-cli.md)). Any other
   process submits the jobs its writes cause to the logs and pokes the owner; it never runs them
   ([durable-queue.md §4.2](algorithms/durable-queue.md#42-ownership)). A command that takes ownership resumes the logs like
   any owner.

Building has no side effect on the stores.

### 3.3 Who builds a Domain Context

| process | builds | notes |
|---|---|---|
| owner (FUSE, File Provider, headless, Android app, a command holding ownership) | yes | resumes deferred logs |
| store server | yes | submits deferred jobs; uses `store` only |
| other one-shot commands | yes | submits |
| tray, discovery library, wizard | no | parse only (mount points, roots, validation) |

---

## 4. Whole-domain operations

### 4.1 Rules common to every operation

- **Where it runs.** An operation that changes a domain runs in the domain's owner: its CLI command
  sends the request, and only when no owner serves does the command take ownership and run it
  itself ([07 §2.5](07-daemon-cli.md#25-one-shot-commands)). An operation that only reads may run in
  any process. Running elsewhere needs a stated reason in 07 §2.5.
- **Pause.** Operations that write a domain's stores refuse while the domain is paused
  ([07 §2.6](07-daemon-cli.md#26-pause)).
- **GC interlock.** Every operation that publishes a reference to a chunk (a manifest from an
  upload, an import, an rsync copy or rename, a revert) does so through the writer interlock of
  [gc.md](algorithms/gc.md). No operation relies on a memo of "this chunk exists on a copy" across a
  collection except as [gc.md §5.6](algorithms/gc.md#56-the-generation-and-presence-memos) allows;
  a memo about a collectable main is harmless, since the gate checks presence at every publication and
  its "missing chunks" refusal drops the named keys.
- **Per-entry isolation.** A per-entry failure is recorded and the run continues, unless this file
  says the whole run fails.
- **Failures** carry the kinds of [failure-model.md](algorithms/failure-model.md); "could not read"
  is never "absent".
- **Whole-store listings** use the `tsync/` prefix or a narrower one, never the empty prefix
  ([01 §2.1](01-core.md#21-store-keys-and-prefixes)).
- **Private temporaries.** An operation's own spill and listing files are temporaries of the local
  temp-name grammar ([01 §2.9](01-core.md#29-temporary-and-reserved-local-names)), removed when their
  owning process is dead; their contents are not a contract.
- **Progress callbacks.** Totals (`on_plan`, `on_scan`) fire once before work; `on_start` fires when
  an item is picked up; `on_file` / `on_entry` when it is done. Byte totals planned equal the bytes
  later reported, and a file's progress sums to its size.
- **Narration.** Every operation takes a narration sink and tells it what [07 §5.1](07-daemon-cli.md#51-conventions)
  `--verbose` promises: its steps, its non-obvious decisions with their reasons, and its progress, as
  sentences for an operator. The operation owns what it says, since only it knows why it decided; the
  caller only chooses where the sentences go (stderr for the CLI, nowhere by default).

### 4.2 Announcing what an operation published (import, rsync, trash restore)

Only the domain's owner mints journal entry keys and publishes entries
([wal-and-journal.md §4.9](algorithms/wal-and-journal.md#49-one-owner-per-domain)). An operation
announces its changes by the rule of
[durable-queue.md §7.3](algorithms/durable-queue.md#73-kill-point-walkthrough-publishing-without-a-local-staged-edit):

- Ops are grouped into batches of at most `ENTRY_OPS` ops, a batch closing early once `ENTRY_AGE`
  has passed since the previous one. Each batch becomes one WAL record listing its ops, made durable
  by the owner **before** the first object it announces is put on the store, and held (a submitter's
  lock, [durable-queue.md §4.2](algorithms/durable-queue.md#42-ownership), taken before the record
  has its name) until its puts ran, so the queue never decides on a manifest still landing. An op
  whose manifest never landed (a failure, a cancel, a file left for the next batch) is dropped when
  the record is published.
- The owner publishes one journal entry per record, updates its mirror and applied log, and bumps
  the cursor.
- **No peer sees a `put` before the `mkdir` naming its folder**: an operation's folder records are
  released before any record holding a file beneath those folders, and the owner publishes an
  operation's records in the order they were released.
- A crash at any point leaves every manifest already on the store named by a durable record, which
  the owner publishes (or drops, for an op whose manifest never landed) at its next rescan.

Why count and age: a deferred replica queues an entry behind the objects it names, so one entry for a
whole run hides the run from the replica's readers until its backlog drains.

### 4.3 Import

`import ~src ?only ?exclude ?force_rehash` → `{imported, skipped, skipped_symlinks, failed}`; per
entry `Imported size | Skipped_exists | Skipped_symlink | Failed reason`.

1. `src` is made absolute and resolved (a dangling resolution keeps the unresolved path).
2. **Plan**: a recursive walk of `src`, entries in the sort order of their full paths (a directory's
   path sorts with a trailing `/`), each once. Per name, its domain-relative path `r`:
   - skipped if an `exclude` glob matches `r` or its basename, at any depth;
   - a directory is recorded once by its resolved path (a cycle guard); with no `only`, its marker is
     planned at once (empty folders are imported); under `only`, only once something beneath it is
     kept; symlinked directories are never descended; an unreadable directory logs a warning and
     counts as empty;
   - a file is kept when `only` is empty, an ancestor was selected, or an `only` glob matches `r`;
   - a symlink is kept likewise, planned with 0 bytes (`skip`), its target's length (`keep`) or its
     target's size (`follow`, 0 when dangling).
   Glob syntax and matching: [01 §17](01-core.md#17-glob-patterns).
3. `on_plan(files, bytes)`.
4. **Folders first**: create each planned folder's marker on the store (claiming its folder id) and
   announce `Mkdir(r, id)` (§4.2).
5. **Files**: a key exists if the store has its manifest, or the mirror holds it published or staged
   (a permitted read, [07 §2.2](07-daemon-cli.md#22-the-domain-owner)). An existing key is
   `Skipped_exists`, **even when its content differs**, unless `force_rehash`, which uploads the file
   again (re-sending chunks missing from the store) and announces it. Otherwise upload (chunked,
   deduplicated, through the interlock) and announce `Put(r, size)`. An imported file is not cached
   locally.
6. **Symlinks** per policy: `keep` → publish a symlink manifest, dangling ones included (same
   existence rule); `follow` → import the target's content under the link's name, a dangling target
   is `Skipped_symlink`; `skip` → `Skipped_symlink`.
7. Close the last batch; poke the owner.

A rerun after a crash skips what exists; nothing it uploaded before the crash stays unannounced
(§4.2).

### 4.4 Export

`export ~dst ~paths` → `{exported, already_there, failed, pending}`; events `Plan{files, bytes,
present}`, `Started{rel, size, present}`, `Landed(rel, bytes)`, `Finished(rel, outcome)`.

Export reads the stores, never the mirror or the chunk cache: files may be too large to pass through
a cache, and the domain's cache is left untouched. A file with staged edits exports its **published**
version and is listed as pending. `dst` must be absolute.

1. Each path is resolved in the store's folder tree: missing → the whole run fails
   (`<p>: no such file or folder in <domain>`); a folder → every file manifest beneath it (an
   unusable child fails the run); a file → itself.
2. **Landing**: a file lands by its own name, a folder keeps its name, the root's contents land as
   they are (`docs/deep/b.txt` → `<dst>/b.txt`; `docs/deep` → `<dst>/deep/b.txt`; `""` →
   `<dst>/docs/deep/b.txt`).
3. The run fails on any relative path with a `.` or `..` segment (names come from a store; `dst` is
   someone's disk) and on two paths landing on one destination.
4. `pending`: this machine's staged, unpublished entries under the paths (a permitted read); they
   are reported, not exported, and make the command exit 1.
5. Per file:
   - with a **record** (below) whose identity matches and a destination file of the manifest's size →
     resume, skipping claimed chunks;
   - with no record, a destination regular file of the manifest's size and an mtime within
     `EXPORT_MTIME_SLACK` of the manifest's → `Already_there`;
   - otherwise fresh (a record whose identity no longer matches, because the file changed upstream,
     starts the file over); symlink manifests are always fresh.
6. Opening a fresh file: write the record header durably **first**, then unlink the
   destination (never write through a symlink), create it exclusively, and preallocate its full size
   (no space → fail that file with `not enough space in <dir>: needs X, Y available`, removing file
   and record). Per chunk: read it verified against its key, check its length, write it at its
   offset, fsync, then append its index to the record. When a file has no chunk left: close, set its
   mtime to the manifest's, remove the record. A symlink manifest: unlink, create the link.
7. A failure settles its file `Failed` and never stops the other files. Files with no outcome at the
   end count as failed. A failed file is left at full length with its record, for resume.

Invariant: a record exists before any byte of its file; it never claims a chunk the file does not
durably hold.

**Export record** at `<cache_root>/<domain>/exports/<xxh(dst,0)>-<xxh(dst,1)>` (hex, the path hashed
with the two seeds of [01](01-core.md)):

```
tsync-export 1 <h1> <h2> <size> <chunk_size> <escaped dst>\n
<chunk index>\n
…
```

The header is compared whole, byte for byte, with the expected one. Then one decimal chunk index
per line, each appended after its chunk is durable. Reading stops at the first line that is not an
in-range index spelled canonically; the text after the last newline is ignored (a torn append).
The export holds an exclusive lock on each record it uses for its whole run; a second export to the
same destination fails that file with `busy`, and the owner's sweep of export records removes only
unlocked records older than the sweep's grace.

### 4.5 Rsync (copy and move)

`rsync ~src ~dst ?move ?dry_run` with `src`, `dst` each `Local path | Domain rel` →
`{copied, skipped, dirs, failed, bytes_moved}`. Local to local is refused; both domain endpoints are
the same domain.

**Facts.** Every domain-side fact comes from the **store** (its folder tree and manifests), never
from the mirror; a local fact from the local filesystem. `source = Missing | Dir | File(local) |
Key(manifest)`; `target = Absent(side) | Dir(side) | File(local) | Key(manifest)`;
`local = Link(target) | Hashed(chunk keys) | Unhashed`.

**Decision** (pure):

| source \ target | decision |
|---|---|
| Missing, _ | Skip `Source_missing` |
| Dir, Absent s / Dir s | Make_dir s |
| Dir, File / Key | Skip `Target_not_a_dir` |
| File / Key, Dir | Skip `Target_is_dir` |
| Key m, Absent Domain, move | Rename_in_domain m |
| Key m, Absent Domain | Copy_manifest m |
| Key a, Key b | Identical if the content hashes are equal, else Copy_manifest a |
| File, Absent Domain | Upload Fresh |
| File l, Key d | Identical if `unchanged(l, d)`, else Upload Replacing |
| Key m, Absent Local | Assemble m |
| Key m, File l | `differing`: unknown → Identical if unchanged else Assemble; none → Identical; some indices → Patch_local(m, indices) |
| File, Absent Local / File | Skip `Not_in_domain` |
| any entry inside a folder whose own decision was a Skip | Skip `Under_skipped`, without gathering its facts |

- `unchanged`: link vs symlink manifest → same target; hashed keys vs a file manifest → same count
  and every key equal; unhashed → false; a kind mismatch → false. **Identity is bytes**, never mtime.
- A local file is hashed only against a manifest, cut at that manifest's chunk size.
- `source_disposal(move)`: Skip, Rename_in_domain and Make_dir keep the source; everything else
  drops it iff `move`.

**Execution.**

- Entries are handled in sorted order, a directory before its content.
- Each action uses the facts its decision was made on; it never re-reads a fact and assumes it is
  still there.
- Copy_manifest: a symlink → publish its manifest; a file → publish a manifest over the **inherited
  chunk keys** through the writer interlock (zero bytes moved; the chunks are promoted before the
  manifest appears, so an open collection cannot sweep them). Announce `Put` (§4.2).
- Upload: symlinks per policy (`skip` → Skip `Symlink_policy`; `keep` → publish the link; `follow`
  → the target's content, a dangling target → Skip `Dangling_symlink`); a vanished source → Failed;
  else upload (the store deduplicates, so only differing chunks are sent). Announce `Put`.
- Assemble: a symlink manifest → a local symlink; else write the file from its chunks.
- Patch_local: consecutive indices merged into runs, each fetched into place; then set the mtime.
- Rename_in_domain: publish the manifest at the destination, delete the source manifest, announce one
  `Rename(dst, src, size, is_dir=false)`.
- Make_dir: local `mkdir -p`, or a domain folder and `Mkdir(rel, id)`.
- Drop source (move): local unlink, or delete the manifest and announce `Delete`.
- The end closes the last batch and pokes the owner (§4.2).
- Unpublished local edits under a domain source are not part of the copy; they are listed with the
  result.
- `bytes_moved` counts what crossed: chunks an upload actually put (deduplicated ones are not
  counted), and chunks a download fetched.
- A folder that could not be created fails every entry beneath it with that reason, without
  attempting them.

### 4.6 `tsync mirror` (store to store)

`mirror ?source ?scope:(All | Manifests | Path rel)` → per destination `{name, checked, copied,
copied_bytes}`.

1. Source: the named member, else the first member in role order.
2. `All` and `Path` are refused while a collection is open ([gc.md](algorithms/gc.md): the chunk
   space is partly under another name); the message names the phase and age and suggests `tsync gc`
   or `tsync gc --abort`. `Manifests` is allowed.
3. **Source listing**:
   - `All`: chunks, then the domain's manifests, markers and versions, then journal entries, then
     the cursor.
   - `Manifests`: the domain's manifests and markers.
   - `Path rel`: walk the folder tree down to and under `rel`, collecting markers and manifests and
     every chunk key those manifests name; each is checked on the source (missing → the run fails
     `<key> is missing from source <name>`); no journal, versions or cursor (they would state a
     history that never happened).
   - Internal leaves (folder indexes) are skipped: an index records store-reported versions and
     duplicates every manifest body.
4. `on_scan(objects, bytes)`.
5. For each other member, in config order: the write guard
   ([replication.md](algorithms/replication.md)) must allow writing it. Compare each source object
   with the destination's (from a listing of the destination for listed scopes, a head per object for
   `Path`):
   - a **chunk** (content-addressed, immutable) is copied when absent or of another size;
   - **every other key** (manifests, markers, anchors, versions, journal entries, the cursor) is
     mutable, and is copied when absent or when its body differs from the source's.
   A copy is a get from the source and a put to the destination.
6. Every chunk is copied before any manifest that names it, and the cursor last: a reader of the
   destination never sees a manifest whose chunks are not there yet, or a cursor ahead of its
   entries.

An object a destination refuses (a reference gate missing the chunks a manifest names, under
`Manifests`) is counted refused for that destination with its reason, and the run goes on; any
refusal makes the command exit 1.

Additive: nothing is deleted on a destination. A chunk's content (same size, wrong bytes) is
integrity's (§4.10). Stateless: a restart re-lists.

### 4.7 Resync (`tsync sync`)

`resync ?full ~parallelism` → `Full{manifests, failed, reason} | Incremental{applied}`. It runs in the
domain's owner (the `sync` bulk action when requested over IPC,
[07 §4.3](07-daemon-cli.md#43-deadlines-bulk-actions-and-the-liveness-probe)), and is refused while
paused.

1. Let the metadata queue publish what it owes, bounded by the settle timeout.
2. Decide: **full** when `full` was asked, or when the domain cannot bridge (the conditions B1–B4 of
   [wal-and-journal.md §4.8](algorithms/wal-and-journal.md#48-retention-horizon-bridging-and-rebuild),
   reported with their reason). Otherwise incremental.
3. **Incremental**: one journal pass ([wal-and-journal.md §4.4](algorithms/wal-and-journal.md#44-inbound-applying-entries))
   → `Incremental{applied}`.
4. **Full**: a rebuild, meeting every rebuild obligation of
   [wal-and-journal.md §4.8](algorithms/wal-and-journal.md#48-retention-horizon-bridging-and-rebuild)
   (refused while metadata is owed: "N metadata operation(s) are not published yet, and a rebuild
   would undo them"; listing before walking; mark and sweep only after a walk with no failure). The
   walk itself:
   - walks the store's folder tree (`parallelism` = the command's `-j`), rewriting the mirror **in
     place** entry by entry; staged edits and cached chunks are kept;
   - reports each difference as ops noted in the applied log as found (at most `RESYNC_NOTE_OPS` per
     noted entry): a changed file → `Put`; a changed folder → `Mkdir(rel, id)`; a replaced folder →
     `Rmdir(rel, old id)` then `Mkdir`; after a complete walk, removed entries (and their cached
     bodies) are reported as removals;
   - counts unusable children, logging a sample;
   - ends by stamping a new resync generation and calling the frontend's `reannounce`
     ([08 §3.2](08-frontends.md#32-hooks)).
   The mount serves the mirror throughout.

### 4.8 Trash, deleted files and retention

- **Trash**: a removed folder's marker moves into the trash namespace; its subtree is untouched
  (unreachable from the root) until expiry.
- `trashed()`: list the trash namespace; read each entry for its path; an unparsable body is passed
  over (a write in flight).
- `restore(path)`: find the entry for `path`; the target is the folder marker at `path`, which needs
  the parent's folder id on this client (else `Parent_unknown`). Refuse when a live folder already
  has the name. Write the anchor (parent, name), then the marker, then delete the trash entry (already
  gone is logged and still `Restored`); announce `Mkdir(path, id)` (§4.2) so peers learn it.
- `purge(path)` → `Purged n | Not_in_trash | Live_elsewhere`: the rules (anchors kept as tombstones,
  trash entry last, refusal of a folder live elsewhere) are
  [gc.md §4.2](algorithms/gc.md#42-purge).
- `deleted_in_folder(key)` and `deleted_in_domain()`: from the versions namespace; a grouping whose
  live manifest is absent is a deleted file, named from a version body. They look up folder ids, never
  mint them.
- `expire(cutoff, ?apply)` → `{trash_deleted, versions_deleted, journal_deleted, shares_deleted}`, in that
  order (trash, versions, journal, shares); its rules are [gc.md §4](algorithms/gc.md#4-retention).
  Without `apply` it is a dry run: the same counts, and each key it would delete, with nothing deleted.
  `purge(path, ?apply)` likewise.
  A client offline for longer than the retention window cannot bridge and rebuilds
  ([wal-and-journal.md §4.8](algorithms/wal-and-journal.md#48-retention-horizon-bridging-and-rebuild)).
- Reverting a file (a file operation, [04 §3.4](04-checkout-cache.md#34-operations)) saves a version
  of the content it replaces when the domain keeps versions.

### 4.9 Garbage collection

`gc` → `dry_run ?verify`, `start`, `step`, `run ?budget ?pause`, `abort`, `status`, `outstanding`,
`retry_outstanding`, with `stats{outcome: Completed | Suspended{phase, cursor}; roots_marked; chunks_promoted;
chunks_verified; chunks_corrupt; chunks_unreadable; chunks_cleared; chunks_reclaimed;
bytes_reclaimed}` and failures `Unsupported(reason)`, `Busy(holder)`. The collector, its phases,
precondition and writer interlock are [gc.md](algorithms/gc.md).

`dry_run` → per collectable main, `survey{run: (phase, cursor) option; chunks_referenced;
chunks_reclaimable; bytes_reclaimable; chunks_missing; per_copy: (member, count) list;
chunks_corrupt}` and the same failures, where `chunks_missing` lists referenced chunks the main lacks
(files a reader cannot open, and publications the gate would refuse); it changes
nothing ([gc.md §5.9](algorithms/gc.md#59-dry-run)). The operator command runs it unless a collection is
explicitly requested; `abort` and `retry_outstanding` are explicit by nature.

**Exclusion.** At most one collection session per domain runs at a time on a machine, whatever the
processes and sessions: a session takes the domain's collection lock before reading the run marker,
and the in-process part of that lock is taken without any suspension point between checking and
setting it (a kernel lock alone merges locks of one process). A second session gets `Busy` naming the
holder. `gc` refuses while the domain is paused.

`outstanding()` lists, per deferred member, delete jobs a copy has not consumed yet, with count and
age, and is warned at every start; `retry_outstanding()` rewrites each job over itself (write guard
first) to re-fire the copy's notification. Both are safe to repeat.

### 4.10 Integrity

- `tree_report()`: a read-only walk from the root. Per folder: its id and paths; a missing anchor →
  `Unanchored{path, id, parent}`; a marker disowned by its anchor → `Disowned{marker, anchor}`; an id
  at two or more paths → `Twice`; a trash entry whose id was reached from the root → `Trashed_live`;
  a trashed folder not reached from the root that has no anchor → `Unanchored` with the trash as its
  parent.
  **Orphans**: list the manifest namespaces on the first main (any store type), mark every
  namespace reachable from the root and from each trashed id; each unmarked namespace holding a child
  object → `Orphan{id, objects, sample ≤ 3}` ([gc.md §4.6](algorithms/gc.md#46-orphan-namespaces)). Order: Twice (sorted), Disowned, Trashed_live, Unanchored, Orphan.
- `repair_tree(dry_run)`: refused on a read-only domain unless dry; Disowned and Trashed_live →
  delete the stale object; Unanchored → write the anchor (for a trashed folder its "in trash" anchor,
  created only if still absent, so a restore racing the repair keeps its live anchor); a top-level
  Orphan older than
  `orphan_grace` → adopted into the trash, and a tombstone MAY be deleted, as
  [gc.md §4.6](algorithms/gc.md#46-orphan-namespaces) specifies; Twice is left and reported, and so
  is an Unanchored folder whose id is also Twice: anchoring it would choose where it lives.
- `verify()`: per member whose bucket function this owner confirmed (write guard first), one verify
  request per shard ([object-store-common §3](backends/object-store-common.md)): `Queued n`; any other
  member `Unsupported`; none queued → `Nothing_queued`; else follow each queued member: poll
  every `VERIFY_POLL` the remaining jobs and corruption markers; done at 0; unchanged for
  `VERIFY_STALL_POLLS` polls → `on_stalled` (a verifier not deployed or not notified). A failed
  listing is not "0 left".
- `repair(source?, dry_run)`: refused on a read-only domain unless dry; per corruption marker: the bad
  store's own copy hashes right → rewrite it over itself (`Cleared`; the store's verifier clears the
  marker); else the first readable other member (only `source` if given) whose copy hashes to the key
  → write it to the bad store only (`Repaired{from}`); else `Unrepairable`. The local cache is never a
  source; nothing here deletes a marker.

### 4.11 Share

Token, expiry, overwrite and revocation rules are
[security-model.md §6.1–6.2](algorithms/security-model.md#61-token); the share entity is
[data-model/backend.md §2.18](data-model/backend.md#218-share); the manifest bytes are
[02](02-remote-model.md).

- **Store choice**: when a non-main member exists, the write guard first (fail fast rather than
  climbing a dead main's retry ladder). Then members readable-first, backfill last; the first whose
  capabilities give a share URL is chosen (write guard on it). None → `Share_unavailable "Sharing is
  not available for <domain>."`.
- **`create(rel, expires, token?)`**: resolve `rel` through the composite: a file manifest → a file
  share (filename = its leaf); a folder (marker, else the local folder-id index, never minted) with at
  least one child → a folder share (the root's filename is `<domain>.zip`); else `Share_not_found`.
  The object MUST be present **on the chosen member** (a head there, or for a folder its namespace
  listing); otherwise `Share_unavailable "<rel> is not on <member> yet"`. The manifest is written to
  the chosen member directly, not through the composite (shares sit outside every domain root, so a
  read-only domain can share), never overwriting an existing one. Every share has a finite expiry,
  `SHARE_DEFAULT_EXPIRY` unless the caller chooses another. Returns `<share URL>/<token>`.
- **`revoke(token | url)`**: delete the manifest, then its token-keyed artifacts.
- **`clear_cache()`**: delete every object under the share cache, and every object of the share
  space whose name is not a share token; returns count and bytes. A reader of the share space SHOULD
  accept objects there that are neither share manifests nor under the share cache (meaning: cached
  artifacts, safe to delete); writers MUST NOT produce them. Links keep working.
- Expired shares are removed by `expire` ([gc.md §4.5](algorithms/gc.md#45-shares)). When a domain is
  removed from a store, its share manifests on that store go with it.

---

## 5. Concurrency and failure

- **Config** is read-only after load; the uplink configuration is set once per process.
- **Deferred work** is durable before a write is reported done; only the owner runs it (§3.2).
- **Import and rsync**: every manifest put is named by a durable record first (§4.2); mkdirs before
  puts; a crash leaves nothing unannounced and a rerun converges.
- **Export**: record header before the file, per-chunk fsync then claim; resume from claims.
- **Mirror**: stateless, additive, idempotent.
- **Resync**: runs in the owner under its serialisation; mark and sweep only after a complete walk.
- **Restore**: anchor before marker, announcement after.
- **GC**: every phase saved before acting ([gc.md](algorithms/gc.md)); exclusive per domain (§4.9).
- **Write guard**: every operation that writes a named member calls it; mains are always allowed.
- **Concurrent work inside one operation** hands each item (a chunk, a listing record) to exactly one
  worker, opens and finishes each exported file once, and settles each file's outcome once.

---

## 6. Design rationale

- **Strict keys everywhere, types from the schema**: a renamed, mistyped or misplaced key otherwise
  leaves a store or an option silently at its default (a mistyped `mountPoint` mounted elsewhere).
- **Unique names ignoring case**: names become directory names and platform identifiers; two targets
  sharing one deferred log each ran the other's jobs against the wrong store.
- **Role required, replica and backfill one mechanism**; **read-only forced** when nothing is
  writable (EROFS at the mount beats a store error per attempt).
- **Operations never write the owner's state or publish entries**: they submit records, so one
  process decides every local change and mints every entry key.
- **Batches by count and age; mkdirs before puts.**
- **Import never overwrites** unless asked.
- **Rsync decides from the store, before acting, by bytes**; in-domain copies inherit chunks through
  the interlock.
- **Export off the stores**, with preallocation and claims; a record is believed only beside a file
  of the right length.
- **Mirror** orders chunks before manifests and compares mutable keys by body: a same-size stale
  manifest or cursor would otherwise stay stale forever.
- **Resync rewrites in place and reports ops** rather than clearing: clearing served an empty tree
  for minutes and forced every reader to re-list.
- **Shares** at a fixed root (IAM and lifecycle target one prefix), created exclusively, verified on
  the member that serves them, never minting folder ids.

---

## 7. Conformance

- **Config**: unknown keys refused at every level including frontend and backend objects; roles
  limited to the four spellings and the read order following role then config order; a domain with
  no main valid only when all its stores are `readOnly`, and then read-only; `uplink` fields validated
  per [06](06-backends.md); the mount point defaulting to `$HOME/tsync/<name>`; the size parser
  accepting whatever the size printer emits; http-proxy secrets shorter than 32 characters and a
  plaintext listener off loopback refused; two `file_provider` domains colliding on identifier or
  replica folder refused; a member named `.` or `..` refused; a local `path` that is neither absolute
  nor `~/`-relative refused; secret fields masked in every report, fields not declared non-secret
  included; a known but
  not compiled type refused at use, an unknown type at parse; wrong JSON types refused with the JSON
  path in the message; duplicate domain names and backend names (ignoring case) refused; a domain
  name outside the grammar refused; two presenting frontends or a duplicate frontend refused; role
  validation as §2.1; `link` default and refusal on `local`; `links` merged over `uplink` and an
  unused link refused; sizes parsed as §2.1; `maxChunkBuffers` follows `maxUploads`; zero means the
  default; a lone `readOnly` backend forces read-only; the wizard cannot write a config the parser
  refuses.
- **Read order and capacity** as [replication.md](algorithms/replication.md) and §3.1.
- **Import**: no put published before the mkdir naming its folder; entries in full-path order,
  each once; names with newlines and tabs survive; `only` imports only selected entries with markers
  only for folders holding them; filters apply at any depth; empty folders are imported; `**/.git`
  excludes `.git` directories only; each symlink policy as §4.3 (kept dangling links included; broken
  followed links skipped and counted); planned bytes equal reported bytes and a file's progress sums
  to its size; a restart transfers nothing new; an existing key is skipped even when its content
  differs, and `--force-rehash` republishes it with its new content and re-sends missing chunks;
  identical content is deduplicated; killing an import at any point leaves no manifest unannounced
  after the owner's next start.
- **Export**: every file under its own path with the right bytes and mtime, no record left; a rerun
  finds everything already there with zero chunk reads; a refused chunk fails only its file, left at
  full length with a record claiming the landed chunks, and the next run fetches only the missing
  ones; a file changed upstream restarts from scratch; a file with staged edits exports its published
  version and is listed pending; the domain's cache is untouched; collisions, unknown paths, `..`
  names and relative destinations refused.
- **Rsync**: the full decision table including patch indices; a copy within a domain moves no bytes;
  a move of a file the mirror does not hold yet succeeds.
- **Mirror**: heals a missing chunk, a wrong-size chunk and a missing manifest on a secondary; an
  in-sync run copies nothing; a same-size stale manifest or cursor is replaced; no destination ever
  holds a manifest without its chunks.
- **Resync**: no mark → rebuild with a reason; a clean rebuild sets the mark; a caught-up client
  applies the journal and reports nothing; `--full` reports nothing for unchanged files; the mirror is
  rewritten in place (chunks survive); moves, recreations and removals of folders are reported by id;
  a failed walk leaves mark and sweep alone; owed metadata is published first and a rebuild is
  refused while it is owed.
- **Trash**: a restore is seen by a peer's next journal pass; purge per
  [gc.md](algorithms/gc.md#10-conformance) (anchors kept); a purge of a live folder is refused.
- **GC**: two sessions for one domain, in one process or two, never run at once; the rest per
  [gc.md](algorithms/gc.md).
- **Integrity**: an unanchored tree reports TWICE, TRASHED-LIVE, UNANCHORED and ORPHAN with a sample;
  repair removes disowned and stale trash entries, anchors the rest, and adopts an orphan older than
  `orphan_grace` into the trash (a younger one is left); orphans are found on a remote main too.
- **Share**: manifest fields for a file and a folder; root share named `<domain>.zip`; refused when no
  member advertises a share URL; a missing path or an empty folder → not found; a read-only domain can share; a backfill-only share store is used
  when it is the only one with a URL, and refused while it lacks the object; a given token that
  exists is refused; revoke removes the link; `clear_cache` removes only cached artifacts, counts
  correctly, and is idempotent.

---

## 8. Parameters

| name | value | rule |
|---|---|---|
| `ENTRY_OPS` / `ENTRY_AGE` | 2000 ops / 10 s | ops per announced batch |
| `RESYNC_NOTE_OPS` | 64 | ops per locally noted resync entry |
| `EXPORT_MTIME_SLACK` | 2 s | |
| `EXPORT_RECORD_GRACE` | 30 days | age past which the owner's daily sweep removes an unlocked export record |
| resync walk parallelism | CLI `-j`, default 32 | |
| `VERIFY_POLL` / `VERIFY_STALL_POLLS` | 3 s / 5 | |
| `SHARE_DEFAULT_EXPIRY` | 7 days | [security-model.md §6.2](algorithms/security-model.md#62-lifetime) |
| default chunk / cache chunk size | 8 MiB / 16 MiB | range: [01 §3.5](01-core.md#35-chunk-size) |
