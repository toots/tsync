# 05 — Domain config and whole-domain operations

This file owns:

- the **config schema and its validation**;
- the **Domain Context**: the live domain every subsystem above config is given, and how it is
  built from config;
- the **whole-domain operations** (import, export, rsync, mirror, sync, deleted-file listing,
  expire, gc, integrity, share): their interfaces and semantics.

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
| **`tsync mirror`** | copy of the main's objects onto the domain's copies (§4.6) |
| **`tsync sync`** | one cycle now, or an arrival by state: bring the local tree to the main's (§4.7) |

Implementation notes: [ocaml/05-ops-config.md](ocaml/05-ops-config.md).

---

## 1. Problem

A **domain** is a name, a set of stores with roles, the frontends that present it, and a few
per-domain policies. Around the per-file engine two things are needed:

1. **A config model**, validated strictly: a typo must never silently leave a store or an option
   unconfigured. And one place where a parsed domain becomes a live one with real stores.
2. **Whole-domain jobs** over whole trees and keyspaces: seeding a domain from a
   folder, writing it out, copying without moving bytes already stored, repairing one store from
   another, reading the main's tree whole, trimming history, reclaiming chunks, checking integrity,
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
  entry, each backend object, each frontend object and each extension object. The known set of a
  backend object is the common keys plus its driver's declared fields; of a frontend object, `type`
  plus its frontend's option spec ([08 §2.1](08-frontends.md)); of an extension object, `type` plus
  its extension's option spec.
- **Known types are part of the schema**, whatever this build compiles: every backend type, every
  frontend type and every extension of this release, with their fields and options, is known to the parser. An unknown
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
| `maxChunkBuffers` | int ≥ 0 | `maxUploads` | *advanced*; chunk bodies in memory across all uploads; also bounds deferred forwards and `tsync mirror` copies; 0 means the default |
| `maxDownloads` | int ≥ 0 | 8 | concurrent file downloads; 0 means the default |
| `uplink`, `links` | objects | | *advanced* but for `uplink.enabled`; [06](06-backends.md); a `links` entry naming a link no backend uses is refused |
| `domains` | array | required | |

**Domain**

| key | type | required | rule |
|---|---|---|---|
| `name` | string | yes | the domain-name grammar of [01 §2.2](01-core.md#22-domain-names), which refuses the reserved root names and `/`; unique among domains **ignoring case** (it names directories, sockets and macOS identifiers on case-insensitive filesystems); on macOS, two `file_provider` domains whose identifiers or replica-folder projections collide are refused ([file-provider.md §3.3](frontends/file-provider.md#33-domain-identifier)) |
| `backends` | array | yes | each per the backend object below; then role validation |
| `frontends` | non-empty array | yes | each `"<type>"` or `{"type":"<type>", …options}` |
| `extensions` | array | no, `[]` | each `"<name>"` or `{"type":"<name>", …options}`, an extension of [extensions](extensions/README.md), at most once; absent or `[]` for none. Listing any extension gives the domain a vault ([vault](extensions/vault.md)). No extension has options yet |
| `symlinks` | `"keep"` \| `"follow"` \| `"skip"` | no | *advanced*, *domain-wide* (below); unset: the main's, else `keep` |
| `versioning` | bool | yes | |
| `readOnly` | bool | no | false; forced true when no backend has a writable role |
| `chunkSize` | size | no | *advanced*, *domain-wide* (below); unset: the main's, else 8 MiB; within the range of [01 §3.5](01-core.md#35-chunk-size) |
| `cacheChunkSize` | size | no | *advanced*; unset: 16 MiB |
| `projectLease`, `projectQuarantine`, `projectSettle` | seconds > 0 | no | *advanced*, *domain-wide* (below); unset: the main's, else 30, 300 and 600 ([publication §7](algorithms/publication.md#7-parameters)). The three in force MUST satisfy lease < quarantine < settle |
| `maxEntryCommands` | int ≥ 1 | no | *advanced*, *domain-wide* as a ceiling (below); unset: the main's, else 256. A higher value lengthens one projection, which MUST still end well within settle − quarantine on the slowest link of the domain ([publication §4.6](algorithms/publication.md#46-projection-the-tree-follows-the-log)) |
| `batchDelay` | seconds ≥ 0 | no | *advanced*; unset: 10. This machine's choice: nothing depends on it |
| `projectWidth` | int ≥ 1 | no | *advanced*; unset: 8. This machine's choice |
| `maxCache` | size | no | unset: unbounded |

**Advanced settings.** A key marked *advanced* tunes the protocol and has a default that suits a
deployment nobody is experimenting on. A config that leaves it out is complete, and no tool writes
it unasked. The config editor asks about it only in its advanced mode
([07 §5.9](07-daemon-cli.md#59-config-wizard-tsync-config---edit)).

**Domain-wide settings.** `chunkSize`, `symlinks`, the three projection timings and
`maxEntryCommands` are values the clients of one main MUST share. One rule serves them all:

1. A domain that leaves the value out uses the one its main states, when the main states one, and
   the application's default otherwise.
2. A main states its values when it is an http-proxy peer: it answers with every one in force for
   the domain it serves, configured or default ([backends/http-proxy](backends/http-proxy.md)). A
   main reached as a plain store states nothing, and the domains sharing it are the operator's to
   configure alike.
3. A domain whose configured value differs from the one its main states is refused as a
   configuration error naming both values: the owner stops serving the domain once it has learned
   the main's. `maxEntryCommands` is a ceiling: a domain MAY configure less than its main states,
   and is refused only for more.
4. The values are learned in the background from owner start on, and asked again every `SWEEP`
   ([publication §7](algorithms/publication.md#7-parameters)): a change on the main reaches a
   running client within that time, the projector it states included. Until then a local operation never waits on a
   store: the chunk size and the symlink policy are the configured one, else the default, and what
   was written under them stays ([01 §3.5](01-core.md#35-chunk-size)). The timings are different: a
   client neither projects nor takes an entry over before it has learned them
   ([publication §4.6](algorithms/publication.md#46-projection-the-tree-follows-the-log)).
5. A main that states its values MAY state a projector with them
   ([frontends/http-proxy](frontends/http-proxy.md), `projectCommits`). It is not a setting of the
   client: a client names it in the entries it creates and leaves their projection to it
   ([publication §4.6](algorithms/publication.md#46-projection-the-tree-follows-the-log)).

**Backend object**

| key | rule |
|---|---|
| `type` | required; a known backend type |
| `name` | required, non-empty, not `.` or `..`, no `/`; unique within the domain **ignoring case** (it names the target's deferred log directory and its counters) |
| `role` | required: `"main"`, `"replica"`, `"backfill"` or `"readOnly"` ([replication.md](algorithms/replication.md)) |
| `link` | *advanced*; optional non-blank string, trimmed; default `"wan"`; refused on `type: local` (a local store has no link) |
| other keys | the driver's declared fields ([backends/](backends/)), each with its declared type. A field declared as a list (for example an `exec` command) takes a JSON array. A local store's `path` is absolute or starts with `~/`. |

**Role validation.** More than one `main` is refused ("a domain has one main"). With no `main`: a `replica` is refused ("a replica is a copy of a source of
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
    "extensions": ["totp", "passwords"],
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
| `domain_prefix`, `chunk_prefix`, `versions_prefix`, `log_prefix`, `takeover_prefix`, `tree_head_key`, `shares_prefix`, `cursor_key` | key names ([02](02-remote-model.md)) |
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
4. Build the composite: the main; `readOnly` archives; each `replica` and `backfill` as a deferred
   target whose job log lives at `<data_dir>/deferred-pending/<domain>/<escaped backend name>/`,
   which forwards a manifest only after the chunks it names and never forwards
   folder indexes.
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
| other one-shot commands | yes | read-class commands ([07 §2.5](07-daemon-cli.md#25-one-shot-commands)): they write nothing through `store` |
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
- **GC interlock.** A reference to a chunk reaches a collectable main only through its reference
  gate ([gc.md §5.4](algorithms/gc.md#54-the-collection-interlock)): at the commit of the log entry
  that carries the manifest (an upload, an import, an rsync copy or rename, a revert), at the
  projection of that entry. No operation relies on a memo of "this chunk exists on a
  copy" across a collection except as
  [gc.md §5.6](algorithms/gc.md#56-the-generation-and-presence-memos) allows; a memo about a
  collectable main is harmless, since the gate checks presence at every commit and its "missing
  chunks" refusal drops the named keys.
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

### 4.2 Bulk publishers (import, rsync)

Import and rsync run in the owner and change the domain as **local operations**
([publication.md §4.10](algorithms/publication.md#410-one-owner-per-domain)). For each file they
upload its chunks and build its manifest, then set the local value at its key with its
before-value, by the rule and kill points of
[durable-queue.md §7.3](algorithms/durable-queue.md#73-kill-point-walkthrough-publishing-without-a-local-staged-edit).
A folder they create is a local `mkdir` ([04 §4.5](04-checkout-cache.md#45-namespace-operations)),
its folder id minted locally. The cycle commits these changes like any other.

**They return after the commit.** Once its last change is made, the command asks for a push and
waits until none of the keys it changed is pending. It is still running when its commits are
made, so a commit refused for missing chunks is answered from its source. While the main cannot
be reached it waits; interrupted, it leaves its changes pending, they are committed by a later
cycle, and it exits non-zero naming how many are left.

### 4.3 Import

`import ~src ?only ?exclude ?force_rehash` → `{imported, skipped, skipped_symlinks, failed}`; per
entry `Imported size | Skipped_exists | Skipped_symlink | Failed reason`.

1. `src` is made absolute and resolved (a dangling resolution keeps the unresolved path). One
   arrival runs first ([publication.md §4.4](algorithms/publication.md#44-arrive-fetch-then-merge)),
   so the local tree the import decides from holds what peers committed; its failure fails the run.
2. **Plan**: a recursive walk of `src`, entries in the sort order of their full paths (a directory's
   path sorts with a trailing `/`), each once. Per name, its domain-relative path `r`:
   - skipped if an `exclude` glob matches `r` or its basename, at any depth;
   - a directory is recorded once by its resolved path (a cycle guard); with no `only`, it is
     planned at once (empty folders are imported); under `only`, only once something beneath it is
     kept; symlinked directories are never descended; an unreadable directory logs a warning and
     counts as empty;
   - a file is kept when `only` is empty, an ancestor was selected, or an `only` glob matches `r`;
   - a symlink is kept likewise, planned with 0 bytes (`skip`), its target's length (`keep`) or its
     target's size (`follow`, 0 when dangling).
   Glob syntax and matching: [01 §17](01-core.md#17-glob-patterns).
3. `on_plan(files, bytes)`.
4. **Folders first**: create each planned folder the local tree lacks (§4.2).
5. **Files**: a key exists if the local tree holds it, as a mirror entry or a staged edit. An
   existing key is `Skipped_exists`, **even when its content differs**, unless `force_rehash` or
   the key is pending and reported as damaged ([publication.md §4.5](algorithms/publication.md#45-push)), which
   uploads the file again (re-sending chunks missing from the store) and installs its manifest
   (§4.2). Otherwise upload (chunked, deduplicated) and install the manifest (§4.2). An imported
   file is not cached locally.
6. **Symlinks** per policy: `keep` → install a symlink manifest, dangling ones included (same
   existence rule); `follow` → import the target's content under the link's name, a dangling target
   is `Skipped_symlink`; `skip` → `Skipped_symlink`.

A rerun after a crash skips the keys the local tree holds and sends only the chunks the main lacks
(§4.2).

### 4.4 Export

`export ~dst ~paths` → `{exported, already_there, failed, pending}`; events `Plan{files, bytes,
present}`, `Started{rel, size, present}`, `Landed(rel, bytes)`, `Finished(rel, outcome)`.

Export reads the stores, never the mirror or the chunk cache: files may be too large to pass through
a cache, and the domain's cache is left untouched. A key with a pending change on this machine exports what the
**main's tree** holds there and is listed as pending. `dst` must be absolute.

1. Each path is resolved in the store's folder tree: missing → the whole run fails
   (`<p>: no such file or folder in <domain>`); a folder → every file manifest beneath it (an
   unusable child fails the run); a file → itself.
2. **Landing**: a file lands by its own name, a folder keeps its name, the root's contents land as
   they are (`docs/deep/b.txt` → `<dst>/b.txt`; `docs/deep` → `<dst>/deep/b.txt`; `""` →
   `<dst>/docs/deep/b.txt`).
3. The run fails on any relative path with a `.` or `..` segment (names come from a store; `dst` is
   someone's disk) and on two paths landing on one destination.
4. `pending`: the keys under the paths that this machine's pending set names
   ([publication.md §3](algorithms/publication.md#3-state)), a permitted read; they are reported,
   not exported, and make the command exit 1.
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

**Facts.** A run starts with one arrival
([publication.md §4.4](algorithms/publication.md#44-arrive-fetch-then-merge)), whose failure fails
the run. Every domain-side fact then comes from the **local tree** (its folders and the manifests of
its mirror entries), which is where rsync's changes are made (§4.2); a local fact from the local
filesystem. `source = Missing | Dir | File(local) |
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
- Copy_manifest: a symlink → install its manifest at the destination; a file → install a manifest
  over the **inherited chunk keys** (zero bytes moved; the gate of the commit promotes the chunks,
  so an open collection cannot sweep them) (§4.2).
- Upload: symlinks per policy (`skip` → Skip `Symlink_policy`; `keep` → install the link; `follow`
  → the target's content, a dangling target → Skip `Dangling_symlink`); a vanished source → Failed;
  else upload (the store deduplicates, so only differing chunks are sent) and install the manifest
  (§4.2).
- Assemble: a symlink manifest → a local symlink; else write the file from its chunks.
- Patch_local: consecutive indices merged into runs, each fetched into place; then set the mtime.
- Rename_in_domain: a local `rename` of the file
  ([04 §4.5](04-checkout-cache.md#45-namespace-operations)).
- Make_dir: local `mkdir -p`, or a local `mkdir` in the domain (§4.2).
- Drop source (move): local unlink, or a local `delete` in the domain.
- A domain source with a staged edit that is not Uploaded
  ([04 §2.5](04-checkout-cache.md#25-staged-manifest)) is not part of the copy: its bytes are not
  on the main. It is listed with the result as skipped. A pending change whose manifest names
  content the main holds (an Uploaded staged edit, an earlier copy or move not yet committed) is
  copied.
- `bytes_moved` counts what crossed: chunks an upload actually put (deduplicated ones are not
  counted), and chunks a download fetched.
- A folder that could not be created fails every entry beneath it with that reason, without
  attempting them.

### 4.6 `tsync mirror` (the main onto its copies)

`mirror ?scope:(All | Skip_chunks | Path rel)` → per destination `{name, checked, copied,
copied_bytes, changed, unguarded}`.

1. The source is the main; the destinations are the replicas and backfills. A domain with no
   main, or with no copy, has nothing to mirror.
2. `All` and `Path` are refused while a collection is open ([gc.md](algorithms/gc.md): the chunk
   space is partly under another name); the message names the phase and age and suggests `tsync gc`
   or `tsync gc --abort`. `Skip_chunks` is allowed: it reads and writes no chunk.
3. **Source listing**:
   - `All`: chunks; then log entries in ascending number, then takeovers; then the domain's
     manifests, markers, anchors and versions; then the tree head, then the cursor. These are the four
     phases of [replication.md §4.10](algorithms/replication.md#410-repair-mirror). A backfill
     destination receives no log entry, takeover, tree head or cursor.
   - `Skip_chunks`: as `All`, without the chunks. For a destination whose chunks are known to be
     there (a run that just compared them, or a copy kept current by its jobs), it skips the
     longest listing of the run.
   - `Path rel`: walk the folder tree down to and under `rel`, collecting markers, the anchors of
     the folders they name, manifests, and every chunk key those manifests name; each is checked on the source (missing → the run fails
     `<key> is missing from source <name>`); no log entry, takeover, tree head, version or cursor
     (they would state a history that never happened).
   - Internal leaves (folder indexes) are skipped: an index records store-reported versions and
     duplicates every manifest body.
4. `on_scan(objects, bytes)`.
5. For each destination, in config order: the write guard
   ([replication.md](algorithms/replication.md)) must allow writing it. Compare each source object
   with the destination's entry (from a listing of the destination for listed scopes, a head per
   object for `Path`). An object's size, etag and checksum always come from one entry, never a
   listing's value paired with a later read:
   - a **chunk** is named by its content ([01 §3.2](01-core.md#32-chunk-keys)): it is copied only when the destination has no entry for
     it, or when the destination's is of another size. It is never compared by content: a present
     chunk of the right size is taken as equal, and one with damaged bytes is integrity's (§4.10);
   - **every other key** (manifests, markers, anchors, versions, log entries, takeovers, the tree
     head, the cursor) is copied when the destination has no entry, when the sizes differ, or when the checksums differ
     (step 6).
6. **Checksum comparison** of a key both sides hold at the same size
   ([06 §2.5](06-backends.md#25-checksums)):
   1. both entries carry comparable checksums → compare them, with no request;
   2. one entry carries a checksum → `compute_checksum` of its algorithm on the other side;
   3. neither carries one → `compute_checksum(md5)` on both sides;
   4. both carry checksums that are not comparable → compute, on one side, the algorithm the other
      carries.

   Where either side could compute, the side of lower `locality`
   ([06 §3.12](06-backends.md#312-compute_checksum-and-locality)) does (`Local < Proxy < Remote`);
   at equal locality, the source, whose body a copy would read anyway. A body crosses a link for a
   comparison only when no closer side can hash it.
7. **A copy** is a `get` from the source, then on the destination:
   - a chunk: `put`. Its name is its content, so there is nothing to guard;
   - any other key: `put_if_unchanged` with the destination's entry the comparison used (`none` when
     it had none). `Changed` means the destination was written after it was read: the mirror leaves
     it, counts it `changed`, and the next run compares it again. A destination that cannot evaluate
     the precondition (REFUSED) is written with `put`, and the key is counted `unguarded`.
8. Comparisons and copies run concurrently, at most `maxDownloads` at once, with the bodies held for
   copies bounded by `maxChunkBuffers` (§2.1).
9. The phases run in order, each finished before the next starts: every chunk is copied before any
   manifest that names it, a log entry before the tree records it gives a value to,
   both before the tree head, and the cursor last. A reader of the destination never sees a manifest whose chunks
   are not there yet, a tree head ahead of its records, or a cursor ahead of its entries. A chunk
   read from the source that does not hash to its name is not copied and is counted refused; a
   destination that did not take every chunk of the run receives none of the later phases.
10. Each destination's parked job-log records are then retried
    ([replication.md §4.10](algorithms/replication.md#410-repair-mirror)).

An object a destination refuses is counted refused for that destination with its reason, and the run goes on; any
refusal makes the command exit 1.

Additive: nothing is deleted on a destination. A chunk's content (same size, wrong bytes) is integrity's (§4.10).
Stateless: a restart re-lists. A race with another writer costs nothing: the conditional replace
never overwrites a destination object written after the comparison read it, and a source object
changed after it was compared is copied as read, or found by the next run.

### 4.7 Sync (`tsync sync`)

`sync ?full` → `{arrival: Entries n | State{files, folders}; changed; committed;
pending}`: the log entries merged, or the file records and anchors a state read found; the keys the
merge changed in the local tree; the entries this client created; the commands still pending
afterwards. It runs in the domain's owner (the `sync` bulk action when requested over IPC,
[07 §4.3](07-daemon-cli.md#43-deadlines-bulk-actions-and-the-liveness-probe)), is refused while
paused, and is refused on a lazy tree ([04 §3.5](04-checkout-cache.md#35-the-local-tree-full-and-lazy)),
which pulls instead.

1. Without `full`: one cycle now ([publication.md §4](algorithms/publication.md#4-the-algorithm)):
   arrive, push what is pushable, project. The arrival is by state when the protocol says so
   ([publication.md §4.7](algorithms/publication.md#47-state-read-and-arrival-by-state)), and the
   result then says `State`.
2. With `full`: the same cycle, its arrival by state.
3. A failed fetch, state read or push fails the request with its kind; what the cycle completed
   before it stands.

**The walk of a state read** is owned here. Every read is answered by the main
([replication.md §4.6](algorithms/replication.md#46-read-path)).

1. Read the tree head, before anything else.
2. List every namespace of the manifest area
   ([data-model/backend.md §2.5](data-model/backend.md#25-namespace)), `parallelism` at a time (the
   command's `-j`). It is an enumeration of the area, not a walk from the root: a folder is found by
   its namespace, wherever its marker is.
3. In each namespace collect the folder's **anchor**, which is the folder's value (parent id, name),
   and every **file manifest**, whose key is (the namespace's folder id, the manifest's recorded
   name). Markers and folder indexes are not values and are not collected.
4. A child that cannot be classified is skipped, and a child listed and gone at its read is absent
   ([data-model/backend.md §5.2](data-model/backend.md#52-what-readers-may-observe-mid-change)): both
   are writes of a projection, whose entry the replay covers. Any other failed listing or read fails
   the walk as a whole.
5. Hand the tree head and the collected values to the replay of the log entries above that tree
   head, which is publication's, as are the merge that follows and what it does to pending changes.
6. What the records hold that is no part of a tree is left out and logged, and integrity reports
   it (§4.10): a folder from which following parents does not reach the root in the replayed
   tree, and a file record whose folder is absent from it. Otherwise the merge would take such a
   record for a peer's change and restore a folder around it.

What changes locally is what the merge decides
([conflict-resolution.md §4](algorithms/conflict-resolution.md#4-enacting-a-merge)): the local tree
is changed in place, key by key, and never cleared; staged edits, pending changes and cached chunks
of unchanged files are kept; the mount serves throughout. The changes go to the change feed in lines
of at most `FEED_LINE_OPS` ops ([03 §2.9](03-journal-sync.md#29-feed-ops-and-the-applied-log-local)), and
no resync generation is stamped. The reverse folder index is rebuilt from the mirror afterwards
([04 §4.9](04-checkout-cache.md#49-folder-id-index)).

### 4.8 Deleted files and retention

- `deleted_in_folder(key)` and `deleted_in_domain()`: from the versions namespace; a grouping whose
  live manifest is absent is a deleted file, named from a version body. They look up folder ids, never
  mint them.
- A deleted file is recovered by reverting to one of its versions (`revert`, a file operation,
  [04 §4.6](04-checkout-cache.md#46-upload)): a local operation, committed by the cycle. The
  version of the content a change replaces is saved by the projection of its entry
  ([data-model/backend.md §2.9](data-model/backend.md#29-version)) when the domain keeps versions.
- A removed folder has nothing to recover as a folder: its removal was committed only once it was
  empty, and the files that were in it are deleted files ([gc.md §4](algorithms/gc.md#4-retention)).
- `expire(cutoff, ?apply)` → `{versions_deleted, log_deleted, shares_deleted}`, in that order
  (versions, log, shares); its rules are [gc.md §4](algorithms/gc.md#4-retention). Without `apply`
  it is a dry run: the same counts, and each key it would delete, with nothing deleted.

### 4.9 Garbage collection

`gc` → `dry_run ?verify`, `start`, `step`, `run ?budget ?pause`, `abort`, `status`, `outstanding`,
`retry_outstanding`, with `stats{outcome: Completed | Suspended{phase, cursor}; roots_marked; chunks_promoted;
chunks_verified; chunks_corrupt; chunks_unreadable; chunks_cleared; chunks_reclaimed;
bytes_reclaimed}` and failures `Unsupported(reason)`, `Busy(holder)`. The collector, its phases,
precondition and writer interlock are [gc.md](algorithms/gc.md).

`dry_run` → for a collectable main, `survey{run: (phase, cursor) option; chunks_referenced;
chunks_reclaimable; bytes_reclaimable; chunks_missing; per_copy: (member, count) list;
chunks_corrupt}` and the same failures, where `chunks_missing` lists referenced chunks the main lacks
(files a reader cannot open, and commits the gate would refuse); it changes
nothing ([gc.md §5.9](algorithms/gc.md#59-dry-run)). The operator command runs it unless a collection is
explicitly requested; `abort` and `retry_outstanding` are explicit by nature.

**Exclusion.** At most one collection session per domain runs at a time on a machine, whatever the
processes and sessions: a session takes the domain's collection lock before reading the run marker,
and the in-process part of that lock is taken without any suspension point between checking and
setting it (a kernel lock alone merges locks of one process). A second session gets `Busy` naming the
holder. `gc` refuses while the domain is paused.

`outstanding()` lists, per deferred member, delete jobs a copy has not consumed yet, with count and
age, and is warned at every start; `retry_outstanding()` re-delivers each job as
[gc.md §5.7](algorithms/gc.md#57-deletion-on-copies) says (write guard first), which re-fires the copy's notification. Both are safe to repeat.

### 4.10 Integrity

- `tree_report()`: read-only, answered by the main. It reads the tree head and whether the entry
  after it exists. If it does, a projection is owed or in progress, the records are legitimately
  between two trees ([data-model/backend.md §4.2](data-model/backend.md#42-temporarily-violated-and-who-repairs)),
  and the report says so with the two numbers and makes no finding: a tree behind its log is
  not unhealthy, and `data-integrity` exits 0 on it. Otherwise the tree head is at
  the head, and the report lists every namespace of the manifest area (as a state read does, §4.7)
  and finds, in this order:
  - `Disowned{marker, anchor}`: a marker its folder's anchor does not name, or whose folder has no
    anchor;
  - `Unmarked{id, parent, name}`: a folder with an anchor and no filed marker;
  - `Unaccounted{key, found, expected?}`: a record the log at the tree head does not account for.
    That is a record whose key a retained log entry names and which is not the value after of the
    last retained entry naming it (`expected`), a key such an entry gives a value and which has no
    record, and a manifest, marker or index in the namespace of a folder, other than the root, that
    has no anchor.
  The report is read-only and nothing repairs the tree from it: a tree behind the log is brought
  up by projection ([publication.md §4.6](algorithms/publication.md#46-projection-the-tree-follows-the-log)).
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
- **`preview(token | url)`**: a separate operation, so `create` returns the link without waiting on a
  decoder. For a file share of an image, a video or an audio file, a host with a thumbnailer makes
  the preview image ([http-proxy §A9.8](frontends/http-proxy.md#a98-preview-image)) through the
  link and writes it to the member holding the manifest, replacing any, then deletes it again if
  the manifest is gone by then; otherwise, and for any other share, it does nothing and says why. A host that created a share it can preview MUST start
  `preview` once `create` has returned, as background work that never delays nor fails the
  creation, one at a time per domain; a failure is logged at debug level. An absent or expired share → `Share_not_found`.
- **`revoke(token | url)`**: delete the manifest, then its token-keyed artifacts.
- **`clear_cache()`**: delete every object under the share cache, and every object of the share
  space whose name is not a share token; returns count and bytes. A reader of the share space SHOULD
  accept objects there that are neither share manifests nor under the share cache (meaning: cached
  artifacts, safe to delete); writers MUST NOT produce them. Links keep working.
- Expired shares are removed by `expire` ([gc.md §4.3](algorithms/gc.md#43-shares)). When a domain is
  removed from a store, its share manifests on that store go with it.

### 4.12 Voiding a log entry

`void_entry(n)` is the operator's way past an entry no client can decode
([publication.md §4.3](algorithms/publication.md#43-fetch)).

1. Read the tree head and entry `n` from the main. Refuse unless `n` is above the tree head and
   the entry exists and does not decode. An entry of an unknown version is refused: it needs a
   newer client, not a void.
2. Create the void object of `n` with `put_if_absent`. `Held` is success.

- The commands of a voided entry are not part of the main, and the chunks only they name are
  collectable.
- A client that had merged the entry before it was damaged (normally its author alone) still
  holds its values and does not publish them again. Its next arrival by state replaces them with
  the main's. The command prints this, and the operator copies aside what must be kept before
  running `tsync sync --full` there.

---

## 5. Concurrency and failure

- **Config** is read-only after load; the uplink configuration is set once per process.
- **Deferred work** is durable before a write is reported done; only the owner runs it (§3.2).
- **Import and rsync**: local operations in the owner (§4.2); a crash leaves a pending change the
  cycle commits, or chunks nothing names, which a rerun finds and a collection otherwise removes.
- **Export**: record header before the file, per-chunk fsync then claim; resume from claims.
- **Mirror**: stateless, additive, idempotent; it never overwrites a destination object written
  after its comparison read it, on a destination that evaluates the precondition.
- **Sync**: runs in the owner's cycle; a state read that fails changes nothing.
- **GC**: every phase saved before acting ([gc.md](algorithms/gc.md)); exclusive per domain (§4.9).
- **Write guard**: every operation that writes a named member calls it; the main is always allowed.
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
- **Operations that change a domain are local operations in its owner**: one process decides every
  local change and creates every log entry, and a bulk run needs no publication path of its own.
- **Import never overwrites** unless asked.
- **Rsync decides before acting, by bytes**, from the tree its changes are made to; in-domain
  copies inherit chunks.
- **Export off the stores**, with preallocation and claims; a record is believed only beside a file
  of the right length.
- **Mirror** orders chunks before manifests, compares chunks by name and size (their name is their
  content, and both come with the listing), and compares mutable keys by checksum: a same-size stale manifest or cursor would
  otherwise stay stale forever. Checksums come from the stores' listings where the service keeps
  them, and are otherwise computed on the closest side, so a run checks hundreds of thousands of
  manifests without downloading them; comparing by body read every one of them from both sides,
  one at a time. Copies of mutable keys are conditional on the destination being as compared.
- **An arrival by state merges in place and reports ops** rather than clearing: clearing served an
  empty tree for minutes and forced every reader to re-list.
- **A state read enumerates namespaces** rather than walking from the root: a folder a projection is
  moving is at no path for a moment, and its namespace is always there.
- **Shares** at a fixed root (IAM and lifecycle target one prefix), created exclusively, verified on
  the member that serves them, never minting folder ids.

---

## 7. Conformance

- **Config**: unknown keys refused at every level including frontend and backend objects; roles
  limited to the four spellings and the read order following role then config order; a domain with
  two mains refused; a domain with no main valid only when all its stores are `readOnly`, and then
  read-only; `uplink` fields validated
  per [06](06-backends.md); the mount point defaulting to `$HOME/tsync/<name>`; the size parser
  accepting whatever the size printer emits; http-proxy secrets shorter than 32 characters and a
  plaintext listener off loopback refused; two `file_provider` domains colliding on identifier or
  replica folder refused; a member named `.` or `..` refused; a local `path` that is neither absolute
  nor `~/`-relative refused; secret fields masked in every report, fields not declared non-secret
  included; a known but
  not compiled type refused at use, an unknown type at parse; wrong JSON types refused with the JSON
  path in the message; duplicate domain names and backend names (ignoring case) refused; a domain
  name outside the grammar refused; two presenting frontends or a duplicate frontend refused; a domain with
  an unknown or duplicate extension, or with an unknown key in an extension object refused; a domain
  without `extensions` and one with `[]` accepted alike; role
  validation as §2.1; `link` default and refusal on `local`; `links` merged over `uplink` and an
  unused link refused; sizes parsed as §2.1; `maxChunkBuffers` follows `maxUploads`; zero means the
  default; a lone `readOnly` backend forces read-only; the wizard cannot write a config the parser
  refuses.
- **Read order and capacity** as [replication.md](algorithms/replication.md) and §3.1.
- **Import**: no file is installed before its folder exists locally; entries in full-path order,
  each once; names with newlines and tabs survive; `only` imports only selected entries, with folders
  created only when they hold one; filters apply at any depth; empty folders are imported; `**/.git`
  excludes `.git` directories only; each symlink policy as §4.3 (kept dangling links included; broken
  followed links skipped and counted); planned bytes equal reported bytes and a file's progress sums
  to its size; a restart transfers nothing new; an existing key is skipped even when its content
  differs, and `--force-rehash` installs it with its new content and re-sends missing chunks;
  identical content is deduplicated; an import writes chunks and no other store object, and what it
  imported is on the main after the cycle that commits it; killing an import at any point leaves
  every installed file pending and committed after the owner's next start, and a rerun completes
  the rest.
- **Export**: every file under its own path with the right bytes and mtime, no record left; a rerun
  finds everything already there with zero chunk reads; a refused chunk fails only its file, left at
  full length with a record claiming the landed chunks, and the next run fetches only the missing
  ones; a file changed upstream restarts from scratch; a file with a staged edit exports the version in
  the main's tree and is listed pending; the domain's cache is untouched; collisions, unknown paths, `..`
  names and relative destinations refused.
- **Rsync**: the full decision table including patch indices; a copy within a domain moves no bytes;
  a move of a file a peer committed and this client had not merged yet succeeds; a move within a
  domain is committed as one entry holding the removal and the creation.
- **Mirror**: heals a missing chunk, a wrong-size chunk and a missing manifest on a secondary; a
  present chunk of the right size is never read; an in-sync run copies nothing; a same-size stale manifest or cursor
  is replaced; no destination ever holds a manifest without its chunks, nor a tree
  head above the log entries and records it was copied with; a backfill receives no log entry,
  takeover, tree head or cursor; a `--path` run copies none of them. Local to GCS over in-sync
  manifests issues no request per object on GCS and hashes only local files; http-proxy to GCS
  hashes on the proxy's server; against an S3 destination with `etagIsMd5: false`, each key is
  hashed on the source where the source keeps or computes it, and on S3 by downloading it, never
  copied without a comparison. A destination key written between the comparison and the copy is left as
  written and counted `changed`; a destination without conditional replace is written and counted
  `unguarded`.
- **Sync**: `sync` runs one cycle and reports the entries merged, the keys changed and the entries
  committed; a caught-up client with nothing pending reports zeros. `--full` arrives by state: it
  reports nothing changed for a tree already at the head, changes the local tree in place (cached
  chunks of unchanged files survive), keeps every staged edit and pending change, and turns a
  pending change that clashes into a conflicted copy; moves, recreations and removals of folders
  reach the change feed by id, in lines of at most `FEED_LINE_OPS` ops, with no new resync
  generation. A state read finds a folder whose marker a projection has deleted and not yet
  rewritten. A read failure injected into the walk fails the sync and changes nothing locally. A
  lazy tree refuses `sync`.
- **Deleted files and expiry**: a deleted file is listed from its versions and comes back by a
  revert; `expire` reports and deletes versions, log entries and shares, in that order, per
  [gc.md](algorithms/gc.md#10-conformance), and a dry run deletes nothing.
- **GC**: two sessions for one domain, in one process or two, never run at once; the rest per
  [gc.md](algorithms/gc.md).
- **Integrity**: with the tree head below the head, the tree report makes no finding and says
  why. With it at the head, a planted stale marker is reported DISOWNED, a deleted filed marker
  UNMARKED, and a record overwritten with another value, or deleted, UNACCOUNTED when a retained
  entry names its key. The report writes nothing.
- **Share**: manifest fields for a file and a folder; root share named `<domain>.zip`; refused when no
  member advertises a share URL; a missing path or an empty folder → not found; a read-only domain can share; a backfill-only share store is used
  when it is the only one with a URL, and refused while it lacks the object; a given token that
  exists is refused; revoke removes the link; `clear_cache` removes only cached artifacts, counts
  correctly, and is idempotent.

---

## 8. Parameters

| name | value | rule |
|---|---|---|
| `EXPORT_MTIME_SLACK` | 2 s | |
| `EXPORT_RECORD_GRACE` | 30 days | age past which the owner's daily sweep removes an unlocked export record |
| state-read walk parallelism | CLI `-j`, default 32 | |
| `VERIFY_POLL` / `VERIFY_STALL_POLLS` | 3 s / 5 | |
| `SHARE_DEFAULT_EXPIRY` | 7 days | [security-model.md §6.2](algorithms/security-model.md#62-lifetime) |
| `SHARE_PREVIEW_MAX_BYTES` / `SHARE_PREVIEW_SIZE` / `SHARE_PREVIEW_MIN_SIDE` / `SHARE_PREVIEW_TIMEOUT` | 300 KiB / 800 px / 300 px / 20 s | preview image: size cap, exact longest side, least shortest side (a card's least width), time to make one ([http-proxy §A9.8](frontends/http-proxy.md#a98-preview-image)) |
| default chunk / cache chunk size | 8 MiB / 16 MiB | range: [01 §3.5](01-core.md#35-chunk-size) |
