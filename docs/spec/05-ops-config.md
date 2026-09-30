# 05 — Domain config and whole-domain operations

Scope: `lib/domain/config/{conf,parsing,domain}` + `lib/lwt/domain/config` (the config model, and turning a
parsed config into a live domain), and `lib/domain/ops` + `lib/lwt/domain/ops` (the one-shot jobs over a whole
domain: import, export, rsync/copy, mirror, resync/sync, retention = expire/trash/deleted-listing, gc,
integrity, share).

**Scope correction.** The per-item operations a frontend calls — read, write, rename, delete, list, cache
evict/fetch, versions/revert — are *not* in `lib/domain/ops`. They live in `lib/domain/checkout`
(`ops/file_ops.ml`, `file/`, `content/data.ml`, `manifests/`) and reach users through the daemon's IPC
(`tsync versions --revert` is `Ipc.action "revert"`, not an ops module). This file names them only where an
op here reuses them. Likewise "mirror" is overloaded in the codebase:

| Term | Meaning | Where |
|---|---|---|
| **local manifest mirror** (`Manifests`, "the mirror", "projection") | this client's on-disk copy of every published manifest, filed under real paths; the full source of truth for "does this key exist" | checkout |
| **`Mirror` op / `tsync mirror`** | backend-to-backend copy of a domain's objects ("remote resync") | `ops/mirror.ml` |
| **`Resync` op / `tsync sync`** | bring the *local manifest mirror* up to date with the store (incremental journal replay or full rebuild) | `ops/resync.ml` |

File layout: this file (§1–§9) is the language-neutral specification. The [OCaml notes](ocaml/05-ops-config.md) hold OCaml-specific
implementation notes, each tied to a Part A section.

---


## 1. Problem

tsync mounts storage the user controls as a folder. A **domain** is one such folder: a name, a set of
backends (stores) with roles, a set of frontends that present it, and a handful of per-domain policies. Two
things are needed around the per-file engine:

1. **A config model** that says, per machine, which domains exist, which stores back each and in what role,
   how they are reached and throttled, and where local state lives — validated strictly so a typo cannot
   silently leave a store unconfigured. And one place (`Domain.of_config`) where a configured *role* becomes
   *behaviour* (which store is source of truth, which is filled behind the write, which is only read).
2. **Whole-domain jobs** that must run without a daemon (and often while one runs), over trees and keyspaces
   too large to hold in memory: seeding a domain from a folder (import), writing it out (export), copying
   within/into/out of a domain without moving bytes that are already stored (rsync), repairing one backend
   from another (mirror), rebuilding this client's view (resync), trimming history (expire), reclaiming
   unreferenced chunks (gc), checking/repairing chunk integrity and tree shape (integrity), publishing links
   (share).

Why separate: the ops are "applications of the layers below rather than an abstraction of their own —
nothing depends on this library, which is what lets each of these run without a daemon"
(`lib/domain/ops/dune`). The config is three layers: (a) a pure parser/validator usable by any tool with no
I/O runtime; (b) the **Domain Context** interface (§2.4) that every subsystem above is parameterised by; (c)
the one builder that turns a parsed domain into a live Domain Context with real stores — kept separate "so a
test can build a real domain without linking a daemon" (`lib/domain/config/domain/dune`).

---

## 2. Concepts & data model

### 2.1 Config file

Location (`Runtime.default_paths`, `lib/local/runtime/*_runtime.ml`):

| Platform | config_path | data_dir | cache_root |
|---|---|---|---|
| Linux | `${XDG_CONFIG_HOME:-~/.config}/tsync/config.json` | `${XDG_DATA_HOME:-~/.local/share}/tsync` | `${XDG_CACHE_HOME:-~/.cache}/tsync` |
| macOS | `~/Library/Group Containers/group.org.feverdreamtv.tsync/config.json` | `<group>/tsync` | `<group>/tsync/cache` |

`$TSYNC_CONFIG_JSON`, if set, is the config JSON text itself and overrides the file
(`Conf_parsing.load`). Android builds its config through the same `Conf_parsing.load` / `Domain.of_config`
from JNI (`android_jni.ml`), with paths supplied by the app.

Per-machine sidecar files under `data_dir`:
- `default-domain` — one line, the domain name used when a command names none (`Domain.default_domain_file`).
- `deferred-pending/<domain>/` — the durable queue of replica/backfill jobs (§4.1).
- sockets: Linux `tsync-<domain>.sock` per domain (each FUSE domain is its own child process); macOS a single
  `tsync.sock` shared by every domain. Plus `tsync-http-proxy.sock`, `tsync-sync.sock`.

#### Schema (JSON, strict)

Unknown keys are **refused** at every level where the known set is declared (top, domain, uplink/links, and
backend when its driver's field list is known) with `"<where>: unknown key(s) \"k1\", \"k2\""`
(`refuse_unknown`, commit 5e532514 "config: a key nothing reads is refused").

Top level:

| Key | Type | Default | Validation / meaning |
|---|---|---|---|
| `name` | string | `gethostname()` | client name; labels conflict copies |
| `tls` | string | none | `"native"` \| `"openssl"` (not validated here) |
| `maxUploads` | int > 0 | 4 | concurrent upload *files*; non-positive/absent → default |
| `maxChunkBuffers` | int > 0 | = `maxUploads` | chunk bodies in memory across all uploads; also caps deferred forwards and mirror copy slots |
| `maxDownloads` | int > 0 | 8 | concurrent file downloads; export's worker width |
| `uplink` | object | defaults | see below |
| `links` | object name→uplink-partial | `{}` | per-link overrides merged over `uplink`; a name no backend in any domain uses is refused (`links: no backend names link "x"`) |
| `domains` | array | required | |

`uplink` object (`uplink_of_json`; defaults `Uplink_control.default_settings`):

| Key | Type | Default | Rule |
|---|---|---|---|
| `enabled` | bool | true | |
| `headroom` | float in (0,1] (or int `1`) | 0.8 | |
| `targetDelayMs` | int ≥ 5 | 50 | stored as seconds (0.05) |
| `minRate` | size | 65536 B/s | int > 0 or size string |
| `maxRate` | size | none | must be ≥ `minRate` |

Anything else in a field → `Failure "<where>: \"field\" cannot be <json>"`. `uplink_to_json` round-trips
(`targetDelayMs` rounded to int ms; `maxRate` omitted when none).

Domain object:

| Key | Type | Required | Default / rule |
|---|---|---|---|
| `name` | string | yes | also mount dir leaf and key-space root |
| `backends` | array | yes | each parsed per below; then role validation |
| `frontends` | non-empty array | yes | each `"fuse"` or `{"type":"fuse", ...opts}`; non-string option values stringified (bool→`true`/`false`, int→decimal, list→JSON text, others dropped) |
| `symlinks` | `"keep"`\|`"follow"`\|`"skip"` | **yes** | missing → error; other string → `unknown symlinks policy` |
| `versioning` | bool | **yes** | `to_bool` raises if absent |
| `readOnly` | bool | no | false; **forced true** when no backend has a role other than `readOnly` |
| `chunkSize` | size | no | `None` = unset (resolved later: backend recommendation else 8 MiB) |
| `cacheChunkSize` | size | no | `None` → 16 MiB |
| `maxCache` | size | no | `None` = unbounded |

Size fields: `Int n` with n>0, or a string parsed by `parse_size`; `Null` → None; else error.

Backend object (`parse_backend`):

| Key | Rule |
|---|---|
| `type` | string, required (`s3`, `gcs`, `local`, `http-proxy`, `exec`…) |
| `name` | string, required (`backend config missing required "name" field (type: s3)`) |
| `role` | required, one of `"main"`, `"replica"`, `"backfill"`, `"readOnly"` (exact spelling) |
| `link` | optional non-blank string, trimmed; default `"wan"` (`Uplink.default_link`). **Refused on `type: local`** ("a local store has none") |
| everything else | passed to the driver as `(string*string)` fields: string as-is, bool → `"true"/"false"`, int → decimal, list → JSON text (e.g. exec's `command`), others dropped. Checked against the driver's declared field names when the parser has been told them (the builder layer registers the driver field lists; a bare parser with no registry skips the check) |

Role validation (`validate_roles`), when there is no `main`:
- any `replica` → error ("a replica is a copy of a source of truth");
- any `backfill` → error ("nothing to fill it from");
- no `readOnly` either → error ("nothing here can answer a read").

Not validated: duplicate backend names within a domain (surfaces later as a `named_exn` failure), duplicate
domain names, duplicate frontends.

`parse_size` grammar: trim, lowercase; strip trailing `ib` or `b`; trim; optional trailing `k|m|g|t`
(binary: 1024^n); remaining must parse as a finite float > 0; result rounded; must be > 0. Accepts
`512K`, `8M`, `1G`, `1048576`, `8.0 MB`, `1.5 GiB`. There is deliberately no `format_size`: display uses
`Metrics.human_bytes`, storage uses plain integers.

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

### 2.2 Roles

`type role = Main | Replica | Backfill | ReadOnly` (JSON `main|replica|backfill|readOnly`).

| Role | Written | Read | Journal/cursor | Built as |
|---|---|---|---|---|
| main | every write, synchronously; write returns once **all mains** have it | first main in config order is read primary | yes | composite `mains` |
| replica | every write, deferred (behind the write, durable queue) | when no main reachable | yes | `Deferred` with `reads_reach=true` |
| backfill | every write from now on, deferred; starts empty | never | **no** (content only) | `Deferred` with `reads_reach=false` |
| readOnly | never | when the source of truth misses or is unreachable | — | composite `archives` |

Replica and backfill are the *same* thing differing by one bit ("a resynced backfill is promoted by editing
one word", `domain.ml:41`).

Read order (`order_backends`, stable sort): main(0), replica(1), readOnly(2), backfill(3); config order kept
within a role. "Reads use the head, so config order selects the read primary."

### 2.3 Key space (object naming on a backend)

`root_prefix = "tsync/"`; per domain `D`:

| Function | Key | Holds |
|---|---|---|
| `domain_root` | `tsync/D/` | everything of the domain (drop domain = one prefix delete) |
| `domain_prefix` | `tsync/D/manifests/` | folder namespaces `…/manifests/<folder-id>/<hash(name)>` (manifests, folder markers), `.tsync-index`, anchors |
| `chunk_prefix` | `tsync/D/chunks/` | `…/chunks/<shard3hex>/<chunkkey>`; **per domain: no cross-domain dedup** |
| `versions_prefix` | `tsync/D/versions/` | `…/versions/<folder-id>/<leafhash>/<ts_ns>` |
| `journal_prefix` | `tsync/D/journal/` | journal entries (month-sharded, `<13-digit-ms>-<uuid>`) |
| `cursor_key` | `tsync/D/cursor` | latest published entry key |
| `shares_prefix` | `tsync/shares/` (**not per domain**, fixed for IAM/lifecycle) | `tsync/shares/<token>` share manifests; `tsync/shares/cache/…` assembled artifacts |
| gc marker | `tsync/D/gc-run` | open collection record |
| gc from-space | `tsync/D/chunks.from/<shard>/<key>` | chunks on their way out during gc |
| corruption markers | `tsync/corrupted/D/<shard>/<key>` | sibling of domain roots |
| verify jobs | `tsync/verify-jobs/D/<shard>` | |
| gc jobs | `tsync/gc-jobs/D/<run13ms>/<last-shard>` | delete requests handed to a copy |
| folder ids | `.tsync-root`, `.tsync-trash` | reserved sentinel ids (`Stored_key.root_id/trash_id`) |

Chunk key example: `3ab8997bc73098ac-74d584d55f333769` (dual-seed xxHash hex of the body, owned by the chunk
subsystem). Shards: `fanout=3` hex chars → 4096 shards (`000`…`fff`).
Collision note (in code): a domain named `corrupted`, `verify-jobs` or `gc-jobs` would collide; not checked.

### 2.4 Domain Context — the live domain as seen by everything above

An immutable record handed to every subsystem that works on one domain (the seam; one instance per domain
per process):

| Field | Type | Meaning |
|---|---|---|
| `versioning` | bool | keep previous versions on modify/rename/delete |
| `client_name` | string | top-level `name` |
| `domain_name` | string | |
| `domain_prefix`, `chunk_prefix`, `versions_prefix`, `journal_prefix`, `shares_prefix` | string | §2.3 |
| `cursor_key` | key | §2.3 |
| `cache_root` | path | machine cache root (**not** per domain; per-domain dirs are `cache_root/<domain>/…`) |
| `data_dir` | path | |
| `socket_path` | path | where this domain's daemon answers |
| `max_uploads`, `max_chunk_buffers`, `max_downloads` | int | concurrency budgets |
| `chunk_size`, `cache_chunk_size`, `max_cache` | optional int | unresolved config values |
| `symlink_policy` | Keep \| Follow \| Skip | |
| `read_only` | bool | |
| `store` | Store | the **composite**: reads walk members in role order; writes land on all mains, deferred targets catch up behind |
| `members` | list of Member | the individual stores in role order, each with the same Store interface |

`Store` is the backend abstraction (get / get_opt / get_range / head_opt / list_prefix / put / copy / delete /
delete_multi / capabilities / verify_all / discard / watch / health / local_path; specified in the backends
file). The Domain Context is asynchronous-runtime-agnostic: every Store operation is asynchronous in whatever
concurrency model the host uses.

Rule: *everything that reads or writes a domain key goes through `store`*. `members` is for callers that
need one store rather than the domain: a report, a mirror copying between two, share placement, gc's main,
integrity repair of one bad copy.

`Backend.member` fields used here: `name`, `role`, `readable` (false for backfill), `backend_type`,
`config` (fields with secrets masked by `Field_spec.mask_named`), `link` (None for local), `pending`,
`in_flight`, `degraded` (deferred stats thunks), `traffic` (remote only), `local_path` (store's own
directory if it is a filesystem store), `backend`.

Derived helpers in `Conf`:
- `default_chunk_size = 8 MiB`, `default_cache_chunk_size = 16 MiB`.
- `chunks_per_group ~chunk_size ~cache_chunk_size = if chunk_size<=0 then 1 else max 1 ((cache + chunk/2)/chunk)` (rounded).
- `locality = {cache_root; domain_name; cache_chunk_size}` — for callers outside a Domain Context asking "is every byte local".
- `capacity members`: among non-readOnly members with a `local_path`, the `Fs.disk_space` record with the
  least `avail` (whole record from one disk, not a per-field min); `None` if none is local.

### 2.5 Ops data types (persistent formats)

**Publish batch** (`publish.ml`): journal ops spooled to a file under `<spool dir>/journal*`; published as one
journal entry when `count >= entry_ops (2000)` or `now - published_at >= entry_age (10 s)`, and at end of run.

**Listing spool** (`Listing`, used by import/mirror): records appended to a temp file named
`<dir>/<name><temp-suffix owned by pid>`; each field is `int32_le length ++ bytes` for strings, `int64_le`
for ints; sealed then `mmap`ed and read once or several times. `reap ~dir` unlinks spools whose owner pid is
dead. Spool dirs: `<cache_root>/import`, `<cache_root>/mirror`, `<cache_root>/rsync` (machine-wide, not per
domain).

**Export record** (`<cache_root>/<domain>/exports/<xxh(dst,0)>-<xxh(dst,1)>`):
```
tsync-export 1 <h1> <h2> <size> <chunk_size> <OCaml-escaped dst>\n
3\n
0\n
4\n
```
Header compared byte-for-byte to the expected one (no field parsing). Then one decimal chunk index per line,
appended after the chunk's bytes are `pwrite`+`fsync`ed. The text after the last `\n` is ignored (torn
claim). Parsing stops at the first line that is not an in-range index spelled canonically
(`string_of_int i = line`).

**Share manifest** (`tsync/shares/<token>`, token = 16 random bytes from `/dev/urandom` → 32 hex chars, or
caller-supplied):
```json
{"v":1,"expires":1767225600,"domain":"Files","type":"file","key":"tsync/Files/manifests/<fid>/<hash>","filename":"report.pdf"}
{"v":1,"expires":1767225600,"domain":"Files","type":"dir","folderId":"<fid or .tsync-root>","filename":"2024.zip"}
```
Root share: `folderId = .tsync-root`, `filename = "<domain>.zip"`. URL returned: `<shareUrl>/<token>`.

**GC run marker** (`tsync/D/gc-run`, via `Collection`): `{phase: Opening|Marking|Abandoning|Closing;
started: float; cursor: string}`; cursor = last finished item *by name* (namespace tag or shard), "" = none.
Namespace names in the cursor: `m/<folder-id>` (manifests) or `v/<folder-id>` (versions); sorted, so all
`m/` precede `v/`. Lock file: `<main local_path>/tsync/D/gc-run.lock` (lockf F_TLOCK).

**GC job key**: `tsync/gc-jobs/D/<run>/<last shard of batch>`, `run = sprintf "%013.0f" (started*1000)`.
`shard_of_job key` = basename if it is a 3-hex shard name, else None (e.g. `tsync/gc-jobs/dom/abb` is *not* a
job; `…/1755300000000/abb` is). Body format is the copy's driver's (`Backend.discard`).

---

## 3. Interface

Each op is a component constructed from a Domain Context plus the lower-layer services it names in §5; all
operations are asynchronous. Callers are CLI commands (`lib/app/cli/cmd_<op>.ml`) and, for share, also the
daemon's IPC handler. Signatures below are pseudo-signatures (`?x` = optional, `~x` = named argument).

### 3.1 Config

```
Conf_parsing.load        : path -> t                  (* env TSYNC_CONFIG_JSON overrides; raises Failure *)
Conf_parsing.of_json     : json -> t                  (* same validation; used by `config --edit` before writing *)
Conf_parsing.pick_domain : ?domain -> t -> domain     (* named; else sole; "no domains configured" / "multiple domains configured — use --domain to select" / "domain not found: X" *)
Conf_parsing.order_backends, role_name, role_of_string, parse_size, uplink_of_json, uplink_to_json,
  link_settings (override else uplink), links_to_json
Conf_parsing.mount_point_of d   (* fuse frontend option "mountPoint" if non-empty, else ~/tsync/<domain> *)
Conf_parsing.cloud_storage_dir ~domain_name   (* macOS: entry of ~/Library/CloudStorage whose [a-z0-9] lowercase equals that of "TsyncApp"^domain *)
Conf_parsing.roots_of ~data_dir d  (* [mount point; cloud-storage dir if found; data_dir] — order a user path is resolved to a domain *)

Domain.of_config : ?domain -> ?socket_path -> ?resume:bool -> paths -> config -> DomainContext
Domain.reading_from : name -> conf -> conf       (* reads (get, get_opt, get_range, fast_read, head_opt, list_prefix, watch, get_many, list_many, health) from member [name]; writes unchanged *)
Domain.reading_at_most : n -> conf -> conf       (* max_downloads := n; n<1 fails *)
Domain.target/socket ?domain ~paths cfg          (* (name, socket path) for IPC *)
Domain.default_domain ~paths : string option     (* from data_dir/default-domain; ignored if empty or not configured; if config unreadable, trusted *)
Domain.start_resumed : unit -> unit              (* start deferred queues built with ~resume:true, in the daemon's converging parent *)
Domain.set_on_recorded : (unit -> unit) -> unit  (* hook: this process recorded a deferred job it will not run *)
```
Domain resolution order everywhere: explicit `--domain` → persisted default → sole configured domain.

### 3.1a How hosts repurpose these pieces

| Host | Config use | Builds Domain Context? | Ops used |
|---|---|---|---|
| Linux daemon (one child process per FUSE domain) | full parse | yes, `resume=true`; starts deferred queues in the converging parent after frontends fork | share (IPC); revert etc. are checkout's |
| macOS daemon (one process, all domains, one socket) | full parse from the App Group container | yes per domain, `resume=true` | share (IPC) |
| CLI one-shot command | full parse; domain resolution; `--source` → `reading_from`, `--parallelism` → `reading_at_most` | yes, `resume=false` (records and drains its own deferred jobs; does not run the daemon's) | import, export, rsync, mirror, sync, expire/trash/versions listing, gc, data-integrity, share |
| Android app | config JSON supplied by the app, same parser | yes, paths supplied by the app | none of the ops layer |
| Desktop mounts / tray | parse only (`mount_point_of`, `roots_of`, `cloud_storage_dir`) | no | none |
| `config --edit` | `of_json` to validate before writing | no | none |

A one-shot command and a daemon may run against the same domain at once; the ops are written for that
(journal batching, gc lock + two-space reads, resync draining this process's own queues).

### 3.2 Ops (per `Make(C)`)

| Op | Signature (abridged) | Result / errors |
|---|---|---|
| **Import** | `run ?only ?exclude ?force_rehash ?entry_ops ?entry_age ?on_dir ?on_plan ?on_start ?on_progress ~src ~on_file ()` | `summary {imported; skipped; skipped_symlinks; failed}`; per entry `status = Imported size \| Skipped_exists \| Skipped_symlink \| Failed msg` |
| **Export** | `run ?on_event ~dst ~paths ()` (dst absolute, else `Invalid_argument`) | `summary {exported; already_there; failed; pending : rel list}`; events `Plan{files;bytes;present} / Started{rel;size;present} / Landed(rel,bytes) / Finished(rel, Exported\|Exported_symlink\|Already_there\|Failed msg)`; fails whole run on unknown path, collision, or `..`/`.` segment |
| **Rsync** | `run ?move ?dry_run ?on_entry ~src:(Local p\|Domain rel) ~dst ()`; pure `decide ~move ~src target`, `describe`, `source_disposal` | `summary {copied; skipped; dirs; failed; bytes_moved}` |
| **Mirror** | `resync ?source ?scope:(All\|Manifests\|Path rel) ?on_scan ?on_list ?on_start ?on_entry ()` | `dest_stats list` (`{name; checked; copied; copied_bytes}`) per destination in config order; `Failure` if source name unknown, gc run open (non-Manifests scope), `Path` object missing on source, or write guard refuses |
| **Resync** | `run ?full ?progress ?on_manifest ?on_decision ~parallelism ()`; `bookmark ()`; `client_uuid ()` | `Full{manifests; failed; reason} \| Incremental{applied}`; `Failure` when a rebuild is needed but metadata ops are owed |
| **Retention** | `trashed ()`; `restore path`; `purge_trashed ?on_delete ~path ()`; `deleted_in_folder key`; `deleted_in_domain ()`; `expire ?on_list ?on_scan ?on_delete ~cutoff ()` | `restored = Restored\|Not_in_trash\|Parent_unknown`; purge `Purged n\|Not_in_trash\|Live_elsewhere`; `deleted {path; latest; versions}`; `stats {versions_deleted; journal_deleted}` |
| **Gc** | `start ?concurrency ?delete_batch ?keep ?verify ()`, `step ?units s`, `release`, `phase/done_/total/stats`, `run ?budget ?units ?pause …`, `abort …`, `status ()`, `outstanding ()`, `retry_outstanding ()`, `show_age` | `stats {outcome: Completed\|Suspended{phase;cursor}; roots_marked; chunks_promoted; chunks_verified; chunks_corrupt; chunks_unreadable; chunks_cleared; chunks_reclaimed; bytes_reclaimed}`; exceptions `Unsupported msg`, `Busy msg` |
| **Integrity** | `tree_report ()`, `repair_tree ?dry_run ()`, `verify ~on_answers ~on_progress ~on_done ~on_stalled ()`, `follow …`, `repair ?source ?dry_run ?on_start ?on_chunk ()` | tree findings `Twice\|Disowned\|Unanchored\|Orphan\|Trashed_live`; verify `Watched\|Nothing_queued`; repair `Repaired{from_store}\|Cleared\|Unrepairable` and `repair_stats`; `Failure` on read-only domain (non-dry) |
| **Share** | `create ?token ~expires ~rel ()`; `clear_cache ()` | `(url, msg) result`; `(count, bytes) result`; `Share_unavailable`/`Share_not_found` mapped to `Error` |
| **Publish** (internal to import/rsync) | `Batch.create/add/publish/drop`, `file`, `symlink`, `dir` | manifest / folder id |
| **Batch** | `take n l`, `per_delete = 1000` | |

Progress-callback contracts (acceptance-relevant): `on_plan`/`on_scan` fire once with totals before work;
`on_start` fires when an item is *picked up* (inside the bounding slot), `on_file`/`on_entry` when done; a
caller wanting "what it is on now" uses `on_start`. Byte totals planned equal bytes later reported.

---

## 4. Behaviour / algorithms

### 4.1 `Domain.of_config` — building the live domain

1. Resolve domain (explicit → `default-domain` file → sole), socket path (`Runtime.domain_socket_path`).
2. Configure the process-wide uplink governor with `uplink` defaults and `links` overrides — once per process (a second domain in the
   same process finds it configured and leaves it).
3. `build_backends`, over `order_backends d.backends`, for each backend config `bc`:
   - fresh traffic counters, kept by name;
   - `admission = Uplink.admission (link bc.link) Background` (every store's writes join its link's line);
   - `store = backend factory(type, field lookup, admission, traffic)` (one client per config entry,
     shared by every layer above — building twice would be two clients against one store);
   - if the store has no `local_path`, attach an uplink probe: `head_opt cursor_key` as the small round trip
     the governor times; `held` and `timeouts` from the store's `Health`.
4. Composite store(mains, targets, archives):
   - mains = role Main; archives = role ReadOnly;
   - targets = Replica/Backfill each wrapped in `Deferred.make ~resume ~max_chunk_forwards:cfg.max_chunk_buffers
     ~room_for:(its admission).try_admit ~name ~backend ~source:<composite> ~chunk_prefix ~chunk_from_prefix
     ~chunk_keys ~journal_prefix ~cursor_key ~excluded:is_index_key ~reads_reach:(role=Replica)
     ~root:<data_dir>/deferred-pending/<domain>`.
   - `chunk_keys body` = chunk keys of the body if it parses as a manifest, else `[]` (markers, shares) — lets a
     deferred target forward a manifest only after its chunks.
   - Folder indexes (`.tsync-index`) are excluded from forwarding.
5. Members, one per leaf with name, role, `readable` (deferred: `readable <> None`; others true), type, masked
   config, link (None for local), deferred stats thunks, traffic (remote only), `local_path`.
6. `resume=true` only for the daemon: picks up owed deferred work; a one-shot command records and drains its
   own jobs but must not run jobs the daemon is running. `start_resumed` runs them in the daemon's parent after
   frontends fork.

`reading_from name`: `Backend.named_exn` (fails on none or several). Replaces *all* read entry points, `watch`,
batch reads and `health` with the named store's so reads, wakes and health reports refer to the same store;
writes still go through the composite so deferred targets still fill.

### 4.2 Publish (shared by import and rsync)

- `file ~src_path key`: stat; `chunk_size ← R.chunk_size ()`; `R.upload ~key ~src_path ~mtime ~chunk_size
  ~on_progress` (chunked, deduplicated, promotes chunks for an open gc run, writes manifest to the store);
  then write it into the local manifest mirror (`Mf.write`). No cache entry: imported files read as not cached.
- `symlink ~target ~mtime key`: `Manifest.make_symlink` (chunkless); `put_manifest`; mirror write.
- `dir key`: `Ck.create_dir key`; `St.ensure_claimed key`; returns `St.ensure_folder_id key` (the id the marker
  minted — a peer resolves the folder by it).
- `Batch.add ops` appends **one op at a time, sequentially** (a parallel append could land in a sealed spool);
  after each, publish if `count >= ops || now - published_at >= age`. `publish` swaps in a fresh spool first,
  then seals the full one, writes it as one journal entry body (`Js.write_journal_entry_body`) and
  `bump_cursor entry_key`; the full spool is dropped in a `finally`.

Rationale (comment on `entry_ops/entry_age`): a deferred replica queues an entry behind the objects it names,
so one entry for a whole run hides the whole run from that replica's readers until its backlog drains; a count
alone bounds nothing a reader feels, hence age too.

### 4.3 Import

1. `src` → absolute, `realpath`. `Listing.reap <cache_root>/import`.
2. **Plan** (`walk_source`): recursive readdir from `src`; per name compute `r` (domain-relative path via
   `Logical_key`), skip if any `exclude` glob matches full `r` or basename. `lstat_kind`; entries sorted by key
   where a directory's key carries a trailing `/` — so output order equals a sort of all full paths.
   - Dir: `realpath` into `seen` (cycle guard, one entry per directory); push onto `pending`; with no `only`
     flush immediately (emit into `dirs` listing); recurse; `selected` inherits.
   - File when kept (`only=[] || selected || only-glob matches r`): flush pending dirs, add `(r, size)` to
     `files`.
   - Symlink when kept: flush, add `(r, target, bytes)` where bytes = 0 (`Skip`), `len target` (`Keep`), or
     target's `stat` size or 0 if broken (`Follow`).
   - Under `only`, a directory marker is emitted only once something beneath it is kept (ancestors held in
     `pending`). Dir-symlinks are never descended. Unreadable dirs log a warning and count as empty.
3. `on_plan ~files:(files+symlinks) ~bytes`.
4. Batch created with `entry_ops`/`entry_age`.
5. **Dirs first**: for each planned dir, `P.dir`, `on_dir`, add `Mkdir (rel, Some id)`. Then `publish ()` —
   **every mkdir is published before any put**, since a peer resolves a file's folder by the id its marker
   carries.
6. Files: `exists key` = local mirror has it (`Mf.published`) **or** store `head_manifest_opt`; if exists and
   not `force_rehash` → `Skipped_exists` (import never overwrites). Else `P.file` → `Imported size`, add
   `Put (rel, size)`.
7. Symlinks per policy: `Keep` → `P.symlink` (same exists check); `Follow` → broken target → `Skipped_symlink`,
   else import as file (content of target under the link's name); `Skip` → `Skipped_symlink`.
8. Each entry wrapped: `on_start` then any exception → `Failed msg` (logged); run continues.
9. Final `publish ()`, then `Cursor.flush_cursor ()` (no queue settles behind an import and `Backend.drain`
   doesn't reach the cursor, so a held-back debounced bump would otherwise never be seen). `finally`: drop
   the three listings and the batch.

Memory: tree is spilled to disk (a million paths ≈ 100 MB otherwise); only `seen` grows (per directory).

### 4.4 Export

Reads straight off the stores (no daemon, no local mirror, no cache except the record).

1. Normalize paths (`segments` joined by `/`; `[]` → `[""]` = whole domain).
2. For each path: `Tree.find root_id segments` over the **store's inode tree** →
   `Missing` → fail `"<p>: no such file or folder in <domain>"`; `Folder id` → `Tree.fold_tree ~on_unusable:`Fail`
   collecting every file manifest; `File` → one.
3. `landing ~dst ~asked ~rel`: strips `dirname asked` from `rel`: a file lands by its own name, a folder keeps
   its name, the root's contents land as-is. Examples: asked `docs/deep/b.txt` → `/out/b.txt`; asked
   `docs/deep` holds `docs/deep/b.txt` → `/out/deep/b.txt`; asked `""` → `/out/docs/deep/b.txt`.
4. Dedup by (rel, dst_path); refuse any rel with `.`/`..` segment (names come off a store; dst is somebody's
   disk); refuse two rels landing on one dst path.
5. `pending` = staged (unuploaded) entries on this machine under the paths (`Staged.entries ~deep`), reported not
   exported.
6. Per file decide (`decide`):
   - record present: parse against identity `{h1,h2,size,chunk_size,dst}`; `Claimed` **and** dst exists with
     manifest size → `Resume claimed`; otherwise `Fresh`.
   - no record: dst is a regular file with manifest size and `|mtime - manifest.mtime| <= 2s` → `Already_there`;
     else `Fresh`. (Marked `ponytail:` — hash if ever insufficient.)
   - symlink manifests always `Fresh`.
7. `Plan` event with `present = size(already_there) + claimed bytes`. `Finished Already_there` for those.
8. `mkdir_p dst`; `Pools.each ~width:C.max_downloads cursor`: the cursor walks jobs **in order, chunk by
   chunk**, skipping claimed chunks, so the open files are the few the workers are spread over.
   - Opening (lazily, once per job, memoized promise): `Started` event; ensure parents; if fresh: atomically
     write record header **first**, then `unlink` dst (never write through a symlink), `open O_CREAT|O_EXCL`,
     `Files.reserve ~size` (preallocate; ENOSPC → `not enough space in <dir>: needs X, Y available`, cleanup of
     file and record); if resuming, `open O_WRONLY`. Record opened `O_APPEND`.
   - Chunk: `R.get_verified_chunk` (checked against key), length must equal expected (else fail file),
     `pwrite_all` at offset, **`fsync`**, append claim line (short write fails), `left--`, `Landed`.
   - Zero-left fresh job (e.g. empty file): just open (creates/reserves).
   - `guarded`: exceptions settle the job `Failed` (message from `Failure`/`Backend_error` else printed); never
     propagate (Pools.each would stop all workers). When `left=0`, no outcome yet and no chunk in flight →
     `finish`: close fds, `utimes` to manifest mtime, unlink record, `Exported`. Close fds once failed and
     idle.
   - Symlink: ensure parent, unlink, `symlink target`, `Exported_symlink`.
9. Tally: jobs with no outcome count as failed.

Invariant: record lands before file bytes; a crash leaves nothing or a record claiming ≤ what the disk holds.
A failed file is left at full length under its name with its record in the cache for resume.

### 4.5 Rsync (copy/move)

Pure decision table (`decide ~move ~src target`), where `source = Missing | Dir | File of local | Key of
Manifest` and `target = Absent side | Dir side | File local | Key Manifest`, `local = Link target | Hashed
chunkkeys | Unhashed`:

| src \ target | result |
|---|---|
| Missing, _ | Skip Source_missing |
| Dir, Absent s / Dir s | Make_dir s |
| Dir, File/Key | Skip Target_not_a_dir |
| File/Key, Dir | Skip Target_is_dir |
| Key, Absent Domain, move | Rename_in_domain |
| Key m, Absent Domain | Copy_manifest m |
| Key a, Key b | Identical if `h1,h2` equal else Copy_manifest a |
| File, Absent Domain | Upload Fresh |
| File l, Key d | Identical if `unchanged l d` else Upload Replacing |
| Key m, Absent Local | Assemble m |
| Key m, File l | `differing`: None → (Identical if unchanged else Assemble); Some [] → Identical; Some idx → Patch_local{m, idx} |
| File, Absent Local / File | Skip Not_in_domain |

- `unchanged`: Link a vs symlink b → a=b; Hashed keys vs non-symlink → same count and all keys equal; Unhashed →
  false; kind mismatch → false. **Identity is only ever bytes**, never mtime (a manifest's double mtime cannot
  faithfully hold ns).
- A local file is hashed only when there is a manifest to compare against, and cut at *that manifest's*
  chunk size so index i names the same span (`local_keys`).
- `source_disposal ~move`: Skip/Rename/Make_dir keep the source (rename already consumed it; a dir outlives
  files still moving out); others drop iff move.

Execution (`run`):
- Entries: Local root → a single file/symlink is `[("", File)]`; a dir is a sorted recursive walk; Domain prefix
  → if a manifest exists at prefix it's one file; else recursive `Ck.list_children` (local mirror). Sorted so
  a directory precedes its content. Held as an in-memory list.
- Per entry: fetch src/dst manifests (`manifest_at` = local mirror, falling back to `R.fetch_manifest`), build
  source/target facts, decide, `on_entry`; `dry_run` tallies (non-skip non-dir as `Copied 0`).
- Actions:
  - Copy_manifest: symlink → put body + mirror + `Put` op; file → `R.upload_chunks` with each chunk
    `Chunk_source.Stored key` (inherited, zero bytes moved, and the one path that **promotes chunks before the
    manifest appears**, so an open gc cannot sweep them — commit 96c30ced) → mirror → `Put`.
  - Upload: policy for symlinks (`Skip` → Skipped Source_missing; `Keep` → P.symlink); vanished → Failed; else
    P.file (store dedups, so only differing chunks are sent).
  - Assemble: symlink manifest → local symlink; else `D.assemble_to`.
  - Patch_local: consecutive indices merged into runs, each one `D.fetch_range`; then `utimes` to manifest
    mtime. `bytes = |chunks| * chunk_size`.
  - Rename_in_domain: put manifest at dst, mirror write, delete src manifest + mirror, one `Rename{dst; src;
    size; is_dir=false; id=None}` op.
  - Make_dir: local `mkdir_p`, or `P.dir` + `Mkdir(rel, Some id)`.
  - Drop source (move): local unlink, or delete manifest + mirror + `Delete rel`.
- End: publish batch, drop, `flush_cursor`.
- Both endpoints `Domain` refer to the same domain `C`.

### 4.6 Mirror (backend → backend)

1. Source = named member (`named_exn`) or the first member (a main by role order).
2. Refuse `All`/`Path` while a gc run is open (chunk prefix only partly under its usual name): message names
   phase and age, suggests `tsync gc` or `tsync gc --abort`. `Manifests` scope is allowed.
3. `Listing.reap <cache_root>/mirror`. Build the **source listing** spooled to disk:
   - `All`: list `domain_prefix`; list chunks **a batch of shards at a time** (batch width = `probe_pool`
     width; each shard `list_prefix chunk_prefix/<shard>/`), spilled before the next batch; list journal,
     versions; `head_opt cursor`. `Manifests`: domain_prefix only.
   - Entries whose leaf is internal (e.g. `.tsync-index`) are skipped — an index records store-reported versions
     and duplicates every manifest body.
   - `Path rel`: walk the inode tree (`Tree.children`) descending only into folders on the way to `rel` or
     under it; collect folder marker keys and file manifest keys under `rel`, plus all chunk keys those
     manifests name; `head_opt` each on the source (probe pool) — missing → `Failure "<key> is missing from source
     <name>"`; journal/versions/cursor excluded (would state a history that never happened).
4. `on_scan ~objects ~bytes`.
5. For each other member **sequentially** (`map_s`), in config order:
   - `Write_guard.ensure ~what:"copy to <name>"` (a non-main may be written only while the main is online; a
     main may always be written — that is how one is refilled).
   - For listed scopes, build a **destination view** by listing the destination the same way, into an
     mmap-backed hashtable (`Hashtbl_mmap`) key→size. (A listing answers ~1000 keys/request vs a HEAD each.)
     `Path` scope uses per-object HEAD instead.
   - `Pools.each ~width:min(entries_in_flight, count)` workers pull the next listing record:
     - size there: from view (announce `on_start`), or `head_opt` inside `probe_pool` (announce inside the slot);
     - reason: missing → `Missing`; dir key present → none; size differs → `Wrong_size`; else present;
     - if a reason: inside `copy_pool`: dir key → put empty; else `Src.get` → `Dst.put`.
     - `on_entry` with `Present` or `Copied(reason, bytes)`; counts only (keys are never retained).
6. `finally` drop listing.

Bounds: `copy_pool = max_chunk_buffers` (bodies in memory); `probe_pool = max(8, 4*max_chunk_buffers)` (round
trips, no body); `entries_in_flight = 4*probe_max` (constant, not the listing length). Probe slot and copy slot
are taken **one after the other, never nested** (nesting deadlocks). Additive only: nothing deleted on
destinations. Correct bytes of wrong content are not detected (that's integrity's job; the store checks bodies
against keys). Chunk prefix copied whole even when shared (content-addressed extras only help).

### 4.7 Resync (`tsync sync`)

1. Start this process's upload queue (`Sq.start`) and metadata queue (`Mq.start`).
2. `Rp.reconcile ()` (replay local records) → `Mq.drain ()` (metadata first: a rename names the file an upload
   is for) → `Sq.drain ()` → `Cursor.flush_cursor ()`.
3. Read `last_sync_key` (local bookmark) and all journal keys. Reason for a **full** rebuild:
   `--full` → "--full flag"; no bookmark → "no bookmark (first run)"; `cannot_bridge last keys` (journal empty,
   or oldest entry's ms > bookmark's ms) → "bookmark older than oldest journal entry". Else incremental.
4. `on_decision last keys reason`.
5. Incremental: `Rp.apply_foreign ~on_changed:ignore` (same engine as the daemon poller) → `Incremental{applied}`.
6. Full:
   - Refuse if `W.owed_metadata ()` non-empty ("N metadata operation(s) are not published yet, and a rebuild
     would undo them").
   - `Cache.clear_projection` (applied entries and scratch; **not** the mirror contents or cached chunks).
   - Walk the store's folder tree (`Tree.fold_tree ~on_unusable:(Skip note) ~refresh_index:(not read_only)
     ~slots:(pool of max 1 parallelism)`); for each entry `Ck.record ~parent ~on_other:`Replace` rewrites the
     mirror in place and says `Same | Changed | Replaced old`; report the difference as journal ops: file
     changed → `Put(rel,size)`; dir changed → `Mkdir(rel, Some id)`; dir replaced → `Rmdir(rel, Some old)` then
     `Mkdir`. Unusable children (unreadable, unparseable manifest, disowned marker) are counted with a sample of
     10 logged. Ops flushed as locally-minted journal entries every 64 ops (`Cursor.note_local`) so a reader of
     applied entries sees a delta, not a reset (commit dbbbe079).
   - **Only if failed = 0**: sweep mirror entries not rewritten since walk start (`Ck.sweep_stale ~cutoff`) and
     cache (`Cache.sweep_stale`), report removals, write bookmark = `J.entry_key ()` (now), `Rp.mark_handled
     all_keys`. A partial walk leaves bookmark and mirror sweep alone (otherwise folders never fetched would be
     skipped forever).
   - The mount keeps serving the mirror throughout; unsynced edits are kept.

### 4.8 Retention (expire, trash, deleted files)

- Trash: a removed folder's marker is moved under the trash namespace `domain_prefix/.tsync-trash/`; subtree
  untouched (unreachable from root).
- `trashed ()`: list trash namespace, skip dir keys, GET each body; `Folder.trash_path_of_string` gives path;
  unparsable bodies passed over (a write in flight).
- `restore path`: find entry whose path matches; target key `L.folder_marker_key (Lk.dir path)` (needs parent's
  id locally → else `Parent_unknown`); `put_anchor folder_id parent name`, put marker `{name,id}` at new key,
  delete trash entry (already gone → logged, still `Restored`). O(1). No journal entry: peers learn by resync.
- `still_trashed m`: folder's anchor exists and is not in trash → log error and refuse (would delete a live
  folder); no anchor → trust the entry.
- `purge_trashed`: `collect_namespace id` = every child bkey of the subtree via `Tree.fold_tree` **plus every
  folder index** seen (`on_index`), errors propagate; delete subtree then marker **last**, in batches of 1000
  (`delete_multi`).
- `deleted_in_folder key`: look up (never mint) folder id; list `versions/<fid>/`; per distinct grouping, if the
  live manifest (`domain_prefix ^ grouping`) is absent, read name from a version body (fallback grouping).
- `deleted_in_domain`: one list of `versions_prefix`; per grouping latest ts, count, sample key; then HEAD live
  manifest per grouping.
- `expire ~cutoff` (seconds): through the composite (reaches every store):
  1. Trash markers with `last_modified < cutoff` (cheap `keep` filter before GET) → for each still-trashed marker,
     marker + subtree keys; delete all.
  2. Versions: list; partition by ts (ns) `< cutoff*1e9`; delete expired; then delete version *directories*
     (`versions/<grouping>/`) of groupings with no survivor (no-op on S3).
  3. Journal: entries with `timestamp_ms < cutoff*1000` **except the one the cursor names** (else a quiet domain
     is left with a cursor pointing at nothing). Age is the only safe criterion: cursor says what was published,
     not what every client applied.
  Returns counts of versions and journal entries (trash not counted in stats).
  Consequence: a client offline longer than the window must full-resync.

### 4.9 GC (copying-collector over a local main)

Precondition: `Backend.main members` (first main) has a `local_path`; else `Unsupported` ("Collecting chunks
needs a local main store; X is s3. Versions and the journal can still be trimmed with tsync expire.").

Idea: rename `chunks/` → `chunks.from/`; writers keep writing `chunks/` (unaware); marking **moves** each chunk a
live root names back into `chunks/` (`Space.promote`); what remains in `chunks.from/` is the garbage by name.
Readers look in both spaces (`Collection.head/get/get_range`, surviving space first). The one writer duty:
`Collection.promote_all` before publishing a manifest (done by `Remote.publish`/`upload_chunks`).

State machine (phase recorded **before** the step it names):

```
(none) --start--> Opening: save; rename chunks->chunks.from (skip if from exists; ENOENT ok)
Opening/Marking --> enumerate namespaces = readdir(manifests/) as m/<id> ++ readdir(versions/) as v/<id>, sorted,
                    filter > cursor; save Marking(cursor)
Marking: per namespace ns (sequential): prefix (dir → trailing "/", a single-object namespace → none);
         list; keep is_child_object keys; per root (unit_slots): GET, marker → [], manifest → its chunk keys,
         unparseable → FAIL the collection (nothing discarded); per chunk (item_slots): promote; if verify &&
         moved: verify_promoted. After ns: save Marking(ns).
Mark [] --> begin_closing: shards = union(readdir chunks/, readdir chunks.from/) sorted; save Closing("")
Closing: per shard (sequential scan): candidates = chunk-named entries in chunks.from/<shard>/;
         keep those NOT present by name in chunks/<shard>/ (HEAD, item_slots) → doomed (key, size);
         pool until ready = (no targets) || count >= delete_batch || 5 s since last flush;
         flush: for each deferred member (Write_guard first): discard(keys) → Queued (bucket function will
         delete) | Unsupported → delete_multi; then delete corruption markers of doomed keys on main + direct
         copies; then discard shards locally (unlink entries, rmdir); save Closing(last shard of batch).
Close [] --> rm -rf chunks.from; clear run marker; Done.
keep=true / Abandoning: shards = readdir chunks.from; per shard: carry_over (rename whole shard dir if
         chunks/<shard> absent/empty) else if k+1 < m-k push_down (unlink/move-down the few in chunks/) then
         carry_over, else move_across missing chunks; discard_shard; save Abandoning(shard).
Keep [] --> re-list chunks.from; leftovers → another Keep round; none → rm -rf, clear, Done.
```

- Resume: `Abandoning` always continues abandoning (once called off, stays off); `keep` overrides any phase
  (cursor not reused); `Closing` resumes after cursor; `Opening|Marking` redo the (idempotent) rename and
  resume marking after cursor. Cursors are names, not indices (resume re-lists).
- Namespaces go one at a time so "last finished" is the furthest; cursor saved after each namespace (a
  namespace can be hours of promoting).
- Copies before main: crash between leaves keys to delete again (idempotent), never keys leaked.
- Doomed-key recheck by name in the surviving space: a chunk re-uploaded mid-run under the same name by a writer
  that never saw the outgoing copy must not be deleted off replicas.
- Only names that are chunk keys are counted/deleted (an in-flight temp is discarded with the space but never
  named in a delete).
- Pools: `unit_slots` for things run several at once (roots), `item_slots` for per-object work inside one;
  width = `concurrency` or main's `caps.max_concurrency` (default 8), clamped ≥1. Chosen by nesting depth; one
  shared pool deadlocks.
- `verify_promoted` (only for chunks actually moved, i.e. once per chunk): GET from **the main only**
  (never the composite: a read would fall through to a replica; a write would fan out); hash = key → count
  verified, delete any stale corruption marker (`cleared`); mismatch → write marker `{computed; size; at;
  reason=None}`; unreadable (EIO, vanished) → marker with `reason`. Never discarded (a manifest names it).
- Throttled progress: ≤1 call/s per phase key, last call forced. `budget` checked between units.
- `run`: `start`, set deadline/callbacks, loop `step ~units` (default 256) with optional `pause`; on budget
  exhaustion return `Suspended` leaving the run open; lock released in `finally`.
- `abort`: no-op if no run; else `run ~keep:true`.
- `outstanding ()`: per deferred member list `gc_jobs_prefix`, keep true job keys; `(name, count, max age)`.
  Warned at every `start`. `retry_outstanding ()`: re-PUT each job body onto itself to re-fire the bucket's
  object-created notification (write guard first). Safe to repeat.
- Exclusion: `take_lock` = in-process flag `held` (lockf merges same-process locks) + `lockf F_TLOCK` on
  `<root>/tsync/D/gc-run.lock` (EAGAIN/EACCES/EDEADLK → `Busy`). Kernel drops it on death → a crashed run is
  resumable. Taken before reading the marker so one process decides open-vs-resume.

### 4.10 Integrity

- `tree_report` (read-only walk from root, `refresh_index:false`): per folder, record id→paths; anchor missing →
  `Unanchored{path;id;parent}`; unusable `Disowned anchor` → `Disowned{marker; anchor}`; ids at ≥2 paths →
  `Twice`. Trash entries whose folder id was reached from root → `Trashed_live`. Orphans only if some **main**
  has a `local_path`: readdir `<root>/tsync/D/manifests/`, minus internal leaves; mark everything reachable
  from root and from each trashed id (plus root and trash ids); each unseen namespace → `Orphan{id; objects;
  sample of ≤3 names}`. Findings order: Twice (sorted), Disowned, Trashed_live, Unanchored, Orphan.
- `repair_tree`: refuses on read-only (unless dry run); Disowned/Trashed_live → `delete_raw` (removed or `left`
  if nothing was deleted); Unanchored → `put_anchor id parent basename(path)`; Twice/Orphan untouched → `left`.
- `verify`: per member (write guard), `B.verify_all ~chunk_prefix` → `Queued n` / `Unsupported`; `on_answers`
  once; none queued → `Nothing_queued`; else `follow` each queued member concurrently.
- `follow`: poll every 3 s: count `verify_jobs_prefix` (left) and `corrupted_prefix` (found); left=0 → done;
  unchanged `left` for 5 polls → `on_stalled` (undeployed/misfiltered notification) and stop. List errors count 0.
- `repair`: refuses on read-only (unless dry); `Cor.list ()` markers; per marker (sequential): bad store's own
  copy hashes right → rewrite it over itself (`Cleared`; the store must re-verify to clear the marker —
  nothing here deletes a marker); else first *readable* member ≠ bad store (optionally only `source`) whose body
  hashes to the key → write to the bad store only (`Repaired{from}`); else `Unrepairable` (key in `lost`). Local
  cache is never a source. Writes go directly to the bad member (not the composite). `Cor.invalidate ()` after.

### 4.11 Share

- `share_backend`: first, if any non-main member exists, `Write_guard.ensure` against it (fail fast rather than
  climbing a dead main's retry ladder). Then members ordered readable-first, backfill last; the first whose
  `capabilities.share_url` is `Some url` is chosen (write guard on it). None → `Share_unavailable "Sharing is
  not available for <domain>."`.
- `create`: `L.manifest_key (Lk.file rel)`; GET via the composite; body is a folder marker → treat as dir.
  File (object exists, not a marker) → type file manifest. Else dir: id from marker, else
  `Folder_ids.lookup_id` (never minted); none → `Share_not_found "not found: rel"`; `list_prefix
  namespace ~max_keys:2`, filter child objects (one may be the index); empty → not found. Put JSON at
  `shares/<token>` on the chosen member directly (not the composite: shares are outside every domain root, so a
  read-only domain can share). Returns `<url>/<token>`.
- `clear_cache`: list `tsync/shares/`, delete non-dir keys under `shares/cache/` and legacy loose `*.data`
  siblings; returns count and bytes. Links keep working.

### 4.12 Batching helpers

`Batch.take n l` one-pass split; `per_delete = 1000` (S3 and GCS bulk delete cap) used by expire/purge and as
gc's default `delete_batch`.

---

## 5. Interactions

Depends on (services each op is constructed with):

| Dependency | Used for |
|---|---|
| Backend API (backends subsystem) | `Store` signature (get/put/head_opt/list_prefix/delete_multi/copy/capabilities/verify_all/discard/local_path/health), `member`, `main`, `deferred`, `named_exn`, `make`, `spec_for` |
| Composite domain store + Deferred target | composite store and replica/backfill queues |
| Uplink governor | link admission, probe attach, settings |
| `Write_guard` | refusing writes to non-mains while the main is offline (mirror, share, integrity, gc) |
| `Remote` (`Remote.OVER`) | upload/upload_chunks/fetch_manifest/get_verified_chunk/chunk_size |
| `Store.INODE`, `Layout`, `Inode_tree`, `Folder`, `Folder_ids` | folder markers, anchors, ids, tree walks |
| `Manifests` (local mirror), `Checkout`, `Staged_manifest`, `Data` | mirror writes, list_children, create_dir, record/sweep, staged entries, assemble/fetch_range |
| `File_store` / `Replay.JOURNAL`, `Journal`, `Spool` | journal entries, cursor bump/flush, bookmark, local notes |
| `Sync_queue`, `Meta_queue`, `Replay`, `Wal` | resync drains and replays; owed metadata |
| `Collection` | gc run record, promote, two-space lookups |
| `Corruption`, `Chunk_layout`, `Chunks` | markers, shard layout, chunk hashing/offsets |
| `History` | version key parsing |
| `Listing`, `Hashtbl_mmap`, `Bounded` pools, `Fs`, `Syscalls`, `Clock` | spills, bounds, filesystem |
| `Runtime` | paths, sockets |

Depended on by: every CLI command (`lib/app/cli/common.ml make_conf` → `Domain.of_config`), the daemon
(`resume:true`, `start_resumed`), the Android JNI, desktop mounts (`Conf_parsing.load` for mount points), the
tray (`mount_point_of`), `tsync config --edit` (`of_json`), IPC handler (share). Nothing depends on the ops
library besides CLI and IPC.

Data flows:
- *import*: disk tree → plan spool → `Remote.upload` (chunks dedup'd, manifest) → composite (mains now,
  deferred later) → local mirror → journal entries (mkdirs first) → cursor.
- *rsync domain→domain*: mirror/store manifest → `upload_chunks` with inherited chunk keys → manifest only.
- *mirror*: member A listing → member B listing view → copy missing/wrong-size objects A→B directly.
- *sync*: local WAL → drain queues → journal → mirror (incremental) or tree walk → mirror (full).
- *expire → gc*: expire drops references (versions, trash, journal); gc reclaims chunks nothing references.

---

## 6. Concurrency, durability & failure semantics

- **Config** is read-only after load; uplink configuration is first-writer-wins per process; the driver-field registry is
  set once when the builder layer loads.
- **Deferred targets**: jobs recorded durably under `data_dir/deferred-pending/<domain>/` *before* a write is
  reported done; resumed only by the daemon (`resume`), one-shot commands record/drain their own.
- **Import/rsync**: journal batches spooled on disk; published entries are durable progress; mkdirs before puts;
  cursor flushed at end. A crash mid-run: already-published entries stand; unpublished spool reaped next run
  (dead pid); rerun skips existing keys (import) or finds identical bytes (rsync). Per-entry failures do not
  abort the run.
- **Export**: per-chunk `fsync` + claim line; record header written atomically before the file is created;
  resume from claims; a torn last line ignored. `ponytail:` fsync per chunk (batch if it shows in profiles).
- **Mirror**: stateless; restart re-lists; additive and idempotent. Bounded memory: listings mmapped from disk,
  destination view in `Hashtbl_mmap`, counts not keys (guarded by `tests/unit/mirror_pools`, ~16 live words per
  object vs 140 before).
- **Resync**: queues drained first; full rebuild refused with owed metadata; bookmark/sweep only after a
  complete walk; ops reported in 64-op local entries as found (a walk that dies part-way has still written
  true facts).
- **Retention**: marker deleted last in purge; expire order trash → versions → version dirs → journal; cursor's
  entry never expired. No journal entry for restore.
- **GC**: every phase transition saved before acting; cursor per namespace/shard-batch; copies before main;
  exclusion by kernel lock (crash ⇒ resumable). Unsafe across hosts sharing one main over a network filesystem
  (`ponytail:` noted). Reads during a run consult both spaces; writes unaffected. Mirror refuses while a run is
  open.
- **Integrity repair**: writes only to the bad store; never deletes markers (stores clear by re-verify).
- **Write guard**: every op that writes a named member (mirror dest, share store, verify/repair, gc copies,
  retry_outstanding) calls `Write_guard.ensure`; mains always allowed.
- **Offline**: ops needing the store fail with backend errors; ops are CLI-only, nothing queues them.

### 6.1 Correctness that relies on cooperative single-threaded scheduling

The implementation runs every op on one thread with cooperative tasks: shared mutable state is touched with no
lock, and is safe only because nothing preempts between two yields. A rewrite with preemptive threads or
parallel workers must add synchronisation at each of these points:

| Where | Shared state | What would break under preemption |
|---|---|---|
| Publish batch (`publish.ml`) | spool handle, op count, last-publish time | `add` is sequential by contract; `publish` reads the full spool, *yields* creating a fresh one, then swaps. A concurrent `add` in that window appends to the spool about to be sealed. Callers must serialise `add`/`publish`. |
| Export (`export.ml`) | shared job cursor (`j`, `i`), per-job `left`, `in_flight`, `outcome`, `opening`, `closed` | `next()` must hand each chunk to exactly one worker (atomic pull); `opened` checks-then-sets a memoised "opening" future (two workers must share one open); `left=0 && in_flight=0 && outcome=None → finish` must run once; `settle` first-writer-wins on `outcome`. |
| Mirror (`mirror.ml`) | listing cursor pulled by all workers; `checked`/`copied`/`copied_bytes` counters | atomic pull and atomic counters. The destination view is read-only once built. |
| Resync full rebuild | `pending` op list, `held` count, `count`, `failed`, `sample`, `at` | walk callbacks run concurrently (up to `parallelism`); `report` appends and `flush` swaps the list *before* yielding — must be atomic. |
| GC session | `chunks_promoted`, `roots_marked`, `chunks_verified/…`, `done_`, `at`, progress throttle table | incremented from concurrently running roots/chunks. |
| GC in-process lock flag `held` | boolean | `take_lock` checks `held`, **yields** (ensure parent dir, lockf), then sets it: two sessions started concurrently in one process can both pass the flag and rely on the kernel lock, which merges same-process locks — i.e. this is racy even today. Use a mutex or set the flag before yielding. |
| Import walk | `seen`, `pending`, `bytes` | sequential walk; safe as long as it stays sequential. |

Pools and bounds summary:

| Op | Bound | Value |
|---|---|---|
| export | worker width | `max_downloads` (overridable by `--parallelism` via `reading_at_most`) |
| mirror | copy / probe / in-flight | `max_chunk_buffers` / `max(8, 4*mcb)` / `4*probe` |
| resync | tree walk slots | `parallelism` (CLI) |
| gc | unit_slots, item_slots | `concurrency` or store max_concurrency (8) |
| import | sequential per file (upload internals bounded by `max_uploads`/`max_chunk_buffers` in Remote) | |
| expire/purge | delete batch | 1000 |
| integrity follow | poll | 3 s, stall after 5 unchanged polls |

---

## 7. Design choices & rationale

- **Strict config keys** (5e532514): a renamed/removed/mistyped key would otherwise leave a store run as if it
  weren't there. Backend keys checked only when the driver's field list is known.
- **Role is required, no default**; replica/backfill are one mechanism with a `reads_reach` bit.
- **Read-only forced** when nothing is writable: EROFS at the mount beats a backend error per attempt.
- **Shares at a fixed root** (not per domain) so IAM/lifecycle target a constant prefix; the manifest names its
  domain (ca6ed151) so the proxy serves it from that one. Shares written to a member directly so a read-only
  domain can share.
- **Chunks per domain** (no cross-domain dedup) so a domain is dropped by one prefix delete.
- **Share never mints a folder id** (would create a namespace nothing wrote to, and persisting it re-creates the
  local dir on a read).
- **Publish in batches by count and age** (deferred replicas hide a single terminal entry until their backlog
  drains); **mkdirs published before puts** (peers resolve folders by marker id).
- **Import never overwrites** an existing key unless `force_rehash`.
- **Rsync decides before acting**; identity by bytes only; in-domain copies publish manifests with inherited
  chunks via `upload_chunks` (the path that promotes chunks for gc — hand-rolling would let a collection sweep
  them).
- **Export off the stores, not the cache**: for files too large to pass through a cache; preallocation;
  resume by claims; a record is believed only beside a file of the right length.
- **Mirror**: listing destinations (not HEAD per object); fixed worker set pulling from a cursor rather than a
  fan-out over the listing; never retain keys; never nest pools; don't resize a pool to fix memory (memory note
  mirror-per-object-retention). Chunks listed a shard batch at a time (whole = bucket's object count in one list).
  Folder indexes skipped.
- **Resync rewrites the mirror in place** (1e85630b) rather than clearing it (clearing took minutes and served
  an empty tree, and dropped still-valid cached chunks), and **reports a rebuild as ops** (dbbbe079) rather than
  wiping applied entries (which forced every reader to re-list). Rebuild waits for owed metadata (d68f0ce4,
  f44d8f9f).
- **The local manifest mirror is the source of truth for existence** (memory fuse-enoent-backend-roundtrip):
  nothing below it on a metadata path asks the backend. Note import's `exists` and rsync's `manifest_at` *do*
  fall back to the store — acceptable because they are one-shot writes, not metadata paths, and import must not
  overwrite keys published since the last sync.
- **GC as a copying collector by rename**: garbage is named, not inferred; writers need no cooperation beyond
  `promote_all`; needs a filesystem rename, hence local main only; copies are *told* keys rather than walked
  (cost proportional to garbage, not layout). A parse failure aborts (skipping a root = deleting a file's
  chunks — "a first attempt at this discarded an entire store"). Namespace prefixes need their trailing `/`
  (without it every lookup is empty and gc deletes everything). Job keys carry the run name so a later run
  cannot overwrite an unconsumed request.
- **Expire and gc are separate** because only some stores can gc; expire works everywhere.
- **Journal expiry by age only**, keeping the cursor's entry.
- **Integrity**: verification is the store's own machinery (bucket notification → function); client only
  queues and watches, and reports "nothing checked" distinctly from "nothing found". Repair hashes candidates
  before trusting them; writes only the bad copy.
- **IPC mutation serialisation** (memory ipc-mutation-resolution-race): not in this subsystem, but share/revert
  via IPC run under the daemon's serialized mutating actions; path→ref resolution must happen inside the lock.

Alternatives rejected (from comments): per-field-min capacity (mixes disks); fan-out over mirror entries;
mark-and-sweep with an in-memory live set (gc: "the surviving root is the record of what has been marked");
walking every shard on every copy to find orphans (that's mirror's job).

---

## 8. Invariants the tests pin down

Config (`tests/unit/conf`):
- read order by role main→replica→readOnly→backfill, config order within role; single backend unchanged.
- `role` required; only the four spellings; `role` never passed as a backend field.
- `link` defaults `"wan"`, any name accepted, refused on `local`.
- unknown keys refused at every level; unknown driver type's keys not checked.
- `links` override merged over `uplink`; a link no backend names refused.
- `uplink` absent = defaults; each field validated.
- replica/backfill without main refused; lone readOnly is valid and forced read-only.
- fields pass through whatever their JSON type (arrays as JSON text).
- both frontend forms parse; object extra keys become options.
- sizes: int and suffixed strings; absent stays absent; human_bytes spellings accepted; junk rejected.
- `maxChunkBuffers` follows `maxUploads`; zero falls back to default.
- `roots_of` head is the mount point (`~/tsync/<d>` default).
- `capacity`: only local stores bound it; readOnly never; tightest one's full record.

Import (`import_batching`, `import_listing`, `import_progress`, `scenario/import_export`):
- no put published before the mkdir naming its folder; the last mkdir entry precedes the first put; the cursor
  names the last published entry; an unreachable op cap with `entry_age=0` still splits a run into >1 entries.
- entries in full-path sort order, each once; folders announced before their subfolders; names with `\n`/`\t`
  survive; live words at first entry < files in tree; `only` imports only selected, markers only for holding
  folders.
- planned bytes = reported bytes; `sent=false` for deduplicated chunks (restart transfers nothing new).
- import into empty domain; skip existing key; dedup identical content.

Export (`ops/export`, `unit/export_record`, `unit/export_cli`):
- every file exported under its own path, nothing else in the destination folder, right bytes and mtime, no record
  left; chunk fetches within budget; open files ≤ workers.
- rerun: all `already_there`, zero chunk reads.
- refused chunk mid-file: file failed, left at full length, one record claiming landed chunks; next run fetches
  only the missing ones; record gone after.
- mangled chunk fails only its file; after repair only that chunk is fetched.
- collisions, unknown paths, relative destinations refused.
- record parse table (resume/start over/already there, 2 s mtime slack) and landing table (see §4.4).

Rsync (`unit/rsync_plan`, `live/rsync`): the full decision table of §4.5 including patch-local indices and
"every decision reachable"; live: a copy within a domain moves no bytes.

Mirror (`unit/mirror_pools`, `unit/mirror_probe`, `scenario/resync`):
- pools named (visible in reports); `on_start` announced inside the bound; announced set = finished set;
  bounded live words per object; second pass announces nothing as picked-up-and-copied but reports `Present`.
- heals missing chunk, corrupt (wrong-size) chunk, missing manifest on a secondary; in-sync is a no-op.

Resync (`ops/resync`): no bookmark → rebuild with reason and file reported as applied op; clean rebuild sets
bookmark; caught-up client applies journal and reports nothing; `--full` rebuild reports nothing for unchanged
files; mirror rewritten in place (chunks survive, dropped manifests reported); anchors bridged across a rebuild;
moved folder reported as a move; recreated folder = old id leaves then new arrives; gone folder reported under
its id; a lost batch is retried; a failed walk leaves bookmark and sweep alone; sync publishes owed metadata;
rebuild refused while metadata owed and mirror untouched.

Retention / GC (`scenario/expire`, `scenario/gc`, `backends/gc_cost`, `gc_targets`, `gc_queued`,
`unit/gc_job`, `unit/gc_report`, `content/promote_race`):
- expire drops old versions/deleted-file versions/trashed folders (trash emptied first), leaving chunks;
  cutoff keeps newer versions; cursor entry survives.
- gc reclaims old-version chunk, keeps live; deleted file/trashed folder fully reclaimed; nothing expired →
  everything kept; second gc is a no-op; a write deduplicating onto a doomed chunk mid-run survives; a write
  mid-collection survives.
- stepping: resume does not re-find work; closing asks copies nothing but the deletes; interrupted abandonment
  stays abandonment; many roots with fewer slots than roots does not deadlock; shards the cursor skipped are
  swept; collection uses only rename on the filesystem; a chunk re-uploaded mid-run is not deleted off copies.
- queued copies: main done, copy still holds garbage with a job outstanding; `retry_outstanding` re-sends;
  consumed job deletes the chunk and its marker, live chunk untouched.
- job key shapes (see §2.5 examples), including domains named `chunks`/`gc-jobs`, and non-job keys.
- progress callbacks' final figures equal returned stats; `at` set when picked up.
- reads and writes during a promotion succeed.

Integrity (`ops/integrity_tree`): unanchored tree → TWICE, TRASHED-LIVE, UNANCHORED×n, ORPHAN (with sample),
orphans checked; with anchors → DISOWNED marker under the wrong parent; repair removes disowned + stale trash
entry, anchors the rest, leaves the orphan.

Share (`unit/share`): file manifest fields (`v=1`, domain, type file, key, filename, expires); root share type
dir, `<domain>.zip`, `folderId=.tsync-root`; nonexistent → Error; read-only-only domain can share (composite
refuses writes); share served from a backfill member when it is the only one with a URL; `not found` for an
empty folder; `clear_cache` removes only cache/ and loose `.data` artifacts, count and bytes correct,
idempotent.

Write guard (`backends/write_guard`): a main not yet heard from is probed once then trusted; an absent main
refuses non-main writes while mains stay writable; hold expiry re-probes; a never-answering main is bounded;
no main = OK; an all-members command leaves the replica untouched while the main is gone.

---

## 9. Open questions / inconsistencies

1. **Docs vs code on unknown keys**: DOCUMENTATION.md Troubleshooting says "unrecognised fields pass through,
   so a typo can look set"; code refuses them (5e532514). Docs stale.
2. **Duplicate backend names** are not rejected at parse; `named_exn` fails later, and `Domain.build_backends`
   keys traffic/admission/built tables by name, so duplicates would silently share/overwrite counters.
3. **Duplicate domain names** not rejected; `pick_domain` takes the first.
4. `versioning` absent raises a raw `Yojson.Util.Type_error` rather than a friendly message like `symlinks`.
5. `default_domain` treats an unreadable config as "configured" (returns the recorded name).
6. **Spool dirs are machine-wide** (`<cache_root>/import|mirror|rsync`), not per domain; safe only because
   `reap` removes files of dead pids alone.
7. **Rsync holds its entry list in memory** (unlike import/mirror, which spill); a very large tree costs RAM.
   `Rename_in_domain` does `Option.get` on the mirror's manifest, which fails if the manifest came from the store
   fallback only.
8. **Rsync `Upload` under `Skip` policy** reports `Skipped Source_missing` for a skipped symlink (misleading
   label); under `Follow`, `upload_local` falls through to `P.file` which uploads the target (a dangling one
   fails in `stat`).
9. **GC picks the first main only**: a domain whose first main is remote but a later main is local is refused.
10. **Expire's version-directory filter** is `List.mem` over survivors — O(expired × surviving).
11. **Expire stats omit trash deletions**.
12. `cannot_bridge` returns true on an empty journal, so a bookmark with no journal at all forces a rebuild.
13. `Integrity.tree_report` finds orphans only when a *main* is local; a local replica is ignored.
14. `Share.create` reads through the composite but writes to one member: the link's store may lack what the
    domain read returned (acknowledged for backfill in comments).
15. `mirror.mli` doc refers to `Checkout.resync` in `gc.mli` (stale name for `tsync mirror`).
16. Mirror's `Wrong_size` repair trusts size alone; a same-size wrong body is left for integrity.
17. Brief's per-item operations (read/write/rename/delete/list/versions/revert/cache evict) are not in this
    subsystem — see checkout spec.
18. GC's in-process `held` flag is checked, then set after an await (§6.1): two sessions started concurrently in
    one process are not excluded (the kernel lock merges same-process locks).

---


---

OCaml implementation notes for this subsystem: [ocaml/05-ops-config.md](ocaml/05-ops-config.md).
