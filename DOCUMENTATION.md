# tsync documentation

Everything beyond the [README](README.md): the full command set, the config file format, and how the pieces behave.

- [Commands](#commands)
- [Multiple domains](#multiple-domains)
- [Importing and exporting](#importing-and-exporting)
  - [Glob patterns for `--only` and `--exclude`](#glob-patterns-for---only-and---exclude)
- [Versioning](#versioning)
- [Symlinks](#symlinks)
- [Read-only domains](#read-only-domains)
- [Configuration file](#configuration-file)
- [Backend types](#backend-types)
  - [Reaching a machine instead of a bucket](#reaching-a-machine-instead-of-a-bucket)
- [Backend roles](#backend-roles)
  - [When to use `backfill`](#when-to-use-backfill)
- [Sharing download links](#sharing-download-links)
- [Chunking and the local cache](#chunking-and-the-local-cache)
- [macOS specifics](#macos-specifics)
- [TLS](#tls)

## Commands

```bash
tsync ls <path>       # list files (add --deleted to include deleted ones)
tsync evict <path>…   # drop the local copy of files or whole directories
tsync restore <path>… # pull files or whole directories back down
tsync versions <path> # a file's version history, or all deleted files
tsync revert <path>   # bring back a previous version (or an undeleted file)
tsync trash           # list deleted folders (folder deletes are recoverable)
tsync untrash <path>  # restore a deleted folder, then run `tsync sync`
tsync purge <path>    # drop a trashed folder for good, with all its versions
tsync expire <date>   # drop versions older than a date, then reclaim unused blocks
tsync sync            # apply changes from other machines (incremental)
tsync sync --full     # clear local cache and re-download all manifests
tsync recheck         # verify the remote against the local cache, repair what's possible
tsync resync-remote   # copy missing/damaged objects from one backend to the others
tsync import <dir>    # seed the domain from an existing folder
tsync export <dir>    # write every file of the domain to a plain folder
tsync share <path>    # print a public download URL for a file or folder (as a zip)
tsync status          # show daemon state
tsync stats           # transfer metrics (pending/completed, bandwidth, hashing)
tsync print-config    # show the config as parsed, with secrets masked
tsync paths           # show the config, cache, data and socket paths in use
tsync build-config    # show which optional features this binary was built with
tsync configure       # interactive setup / editor
tsync start           # mount (normally run by the service manager)
tsync stop            # unmount
```

`tsync build-config` matters because some features are optional at build time: the S3
backend and each frontend are only present if their dependencies were available when the
binary was built. A backend or frontend named in the config but not compiled in fails at
startup saying so.

Pass `--verbose` (or `-v`) to any command to print detailed progress as it runs.

`tsync print-config` is the first thing to reach for when something isn't behaving as
configured: it shows the config exactly as the daemon parsed it, including each backend's
resolved role, with secrets masked.

## Multiple domains

A *domain* is one synced folder with its own backends and settings. When the config
defines more than one, pass `--domain <name>` to commands that operate on a specific one
(`ls`, `versions`, `expire`, `sync`, `recheck`, `resync-remote`, `import`, `export`,
`share`). To avoid repeating it:

```bash
tsync set-domain "media"   # persist a default domain for this machine
tsync set-domain --clear   # remove the default (--domain required again)
tsync default-domain       # print the default currently in effect
```

The default lives in the data directory (see `tsync paths`) and is read by every command
that accepts `--domain`. An explicit `--domain` always wins.

## Importing and exporting

`tsync import <dir>` seeds a domain from an existing folder: it hashes and uploads each
file, so nothing is copied into place locally first. It is safe to re-run — files whose
content already matches are skipped.

```bash
tsync import <dir>                # seed the domain
tsync import <dir> --force-rehash # re-hash and re-upload every file
tsync export <dir>                # write every file of the domain to a plain folder
```

`tsync export` is the escape hatch: it reconstructs the whole domain as ordinary files
and directories, symlinks included, with no tsync involved in reading them afterwards.

### Glob patterns for `--only` and `--exclude`

Both accept shell-style globs, matched against each entry's basename **and** its full
relative path — so a bare name like `node_modules` matches that directory anywhere in the
tree.

`--only` selects what to import: with none, everything is imported; with one or more,
only entries that match (or live under a matching directory) are kept. `--exclude` is
then applied on top. Both may be repeated.

| Pattern | Matches |
|---------|---------|
| `*`     | Any sequence of characters, **not** crossing a directory separator |
| `**`    | Any sequence of characters, **including** directory separators |
| `?`     | Any single character, **not** a directory separator |
| anything else | Itself literally — `+`, `.`, `(`, `)`, spaces, … |

```bash
tsync import . --exclude 'lost+found'   # directory named literally lost+found
tsync import . --exclude '*.tmp'        # any .tmp file in any directory
tsync import . --exclude '**/.git'      # .git directories at any depth
tsync import . --exclude 'node_modules' # any directory named node_modules
tsync import . --only 'Music'           # everything under any Music directory
tsync import . --only '*.flac'          # only .flac files, anywhere
tsync import . --only 'Music' --exclude '*.tmp'  # Music tree, minus .tmp files
```

## Versioning

With `"versioning": true` on a domain, every modify, rename or delete keeps the previous
version. History grows until you trim it with `tsync expire`.

```bash
tsync versions                              # list every file that's been deleted
tsync versions notes/todo.txt               # timestamps of each saved version
tsync revert notes/todo.txt                 # restore the most recent version
tsync revert notes/todo.txt --version <ts>  # restore a specific one
tsync expire 2025-01-01                     # drop older versions, GC unused blocks
```

A version is just the file's small manifest — the data blocks are shared — so `revert` is
instant and downloads nothing. The file reappears evicted and fetches its content the
first time you open it.

`tsync expire <date>` removes every version older than the cutoff, then deletes any data
block no longer referenced by a live file or a surviving version. The date only bounds
versions; blocks are collected purely by whether anything still points at them. Run it
while your machines are idle — collecting blocks a client is mid-upload could race the
upload.

Folder deletes go to a trash area instead of being expanded into per-file deletes, which
is what makes them recoverable with `tsync untrash`. `tsync purge` drops a trashed folder
for good.

## Symlinks

Each domain has a required `symlinks` field:

- **`keep`** — symlinks are first-class objects. `tsync import` stores them as-is (broken
  and dangling links round-trip faithfully), and you can create them in the mounted folder
  (`ln -s`, or via Finder on macOS). Once stored, a symlink behaves everywhere: `readlink`
  returns the target, `tsync export` recreates a real symlink, Finder shows it as one.
- **`follow`** — `tsync import` dereferences them: the target's content is uploaded as a
  regular file under the link's name; broken links are skipped. Creating a symlink in the
  mounted folder is rejected.
- **`skip`** — `tsync import` ignores them (they're counted in the summary). Creating a
  symlink in the mounted folder is rejected.

Under `follow` and `skip` the domain never contains symlink objects: creation through the
mount fails with a permission error, so a link can't slip in past the import policy.

## Read-only domains

Set `"readOnly": true` on a domain to make the mount reject all writes — useful for a
machine that should only pull changes, never push them:

```json
{ "name": "media", "symlinks": "keep", "versioning": true, "readOnly": true,
  "frontends": ["fuse"], "backends": [...] }
```

The sync poller still runs and downloads remote changes normally; only local mutations
(create, write, delete, rename) are blocked. On Linux the mount returns `EROFS`; on macOS
the File Provider extension returns an error for any write attempt.

This is about the mount, not the storage: a domain whose backends are all `readOnly` (see
[backend roles](#backend-roles)) is read-only regardless of this flag.

## Configuration file

`tsync configure` writes it and `tsync paths` says where it lives. The format:

```json
{
  "name": "laptop",
  "maxUploads": 4,
  "maxDownloads": 8,
  "domains": [
    {
      "name": "media",
      "symlinks": "keep",
      "versioning": true,
      "frontends": ["fuse"],
      "backends": [
        { "type": "s3", "name": "cloud", "bucket": "…", "role": "main" }
      ]
    }
  ]
}
```

Top level:

| Field | Required | Meaning |
|---|---|---|
| `name` | no | This machine's name, used to label conflict copies. Defaults to the hostname. |
| `domains` | yes | One entry per synced folder. |
| `maxUploads` | no | Concurrent upload operations, default `4`. Also bounds how many chunk reads/uploads run at once across all files. |
| `maxDownloads` | no | Concurrent file downloads, default `8`. |
| `tls` | no | `"openssl"` or `"native"` — see [TLS](#tls). |

Per domain:

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Domain name; also the mount directory name. |
| `backends` | yes | See [backend types](#backend-types) and [roles](#backend-roles). |
| `frontends` | yes | Non-empty. Each entry is a type name (`"fuse"`) or an object `{"type": …, …options}`. Types: `fuse`, `file_provider`, `http-proxy`. |
| `symlinks` | yes | `keep`, `follow` or `skip` — see [symlinks](#symlinks). |
| `versioning` | yes | Keep previous versions on modify/rename/delete. |
| `readOnly` | no | Make the mount refuse writes. Forced on when no backend is writable. |
| `chunkSize` | no | Upload chunk size. Default 8 MiB, or whatever the backend recommends. |
| `cacheChunkSize` | no | Local cache file size. Default 16 MiB. |
| `maxCache` | no | Soft cap on local cache usage. Unbounded when absent. |

Sizes accept a plain byte count or a suffixed string: `512K`, `8M`, `1G` (binary
multiples, so `1K` is 1024). Both `8388608` and `"8M"` work.

A field that isn't recognised is passed through to the backend or frontend rather than
rejected, so check `tsync print-config` after editing by hand — a misplaced field can look
like it was set.

## Backend types

A backend's `type` says what it talks to. `tsync configure` prompts for the fields each
one needs; every backend also needs a `name` (used by `resync-remote --source`) and a
[`role`](#backend-roles).

| `type` | Required fields | Optional | Notes |
|---|---|---|---|
| `s3` | `bucket`, `accessKeyId`, `secretAccessKey` | `region` (default `us-east-1`), `endpoint`, `shareUrl`, `unsignedPayload` | Also works with S3-compatible services (Backblaze B2, MinIO, …) via `endpoint`. |
| `gcs` | `bucket`, `serviceAccountKey` | `endpoint`, `shareUrl` | `serviceAccountKey` is the service-account JSON itself, not a path to it. Leave it blank only to talk to an emulator anonymously, together with `endpoint`. |
| `local` | `path` | — | A directory: another disk, a mounted NAS, anything the filesystem reaches. |
| `http-proxy` | `url`, `secret` | — | Another machine running tsync with the `http-proxy` frontend. That machine owns the credentials; this one just needs the shared `secret`. |

```json
{ "type": "gcs", "name": "archive", "bucket": "my-bucket",
  "serviceAccountKey": "{…}", "role": "main" }
```

### Reaching a machine instead of a bucket

The `http-proxy` frontend makes one machine serve its domain over HTTP, and the
`http-proxy` backend type consumes it. That is how a laptop reads a NAS's storage without
holding any bucket credentials, and it is what to reach for where you might otherwise
have wanted storage over SSH.

On the NAS, serve the domain:

```json
{ "frontends": [{ "type": "http-proxy", "port": 8443, "secret": "…",
                  "ssl_certificate": "/etc/…/fullchain.pem",
                  "ssl_certificate_key": "/etc/…/privkey.pem" }],
  "backends":  [{ "type": "local", "name": "disk", "path": "/mnt/pool",
                  "role": "main" }] }
```

On the laptop, use it:

```json
{ "frontends": ["fuse"],
  "backends":  [{ "type": "http-proxy", "name": "nas",
                  "url": "https://nas.example:8443", "secret": "…",
                  "role": "main" }] }
```

Both TLS options must be set together, or neither (plain HTTP). The serving side can also
answer share links itself (`"shares": true`) and can refuse writes from proxy clients
(`"readOnly": true`) while still accepting them on its own mount. A client behind a proxy
inherits the serving domain's chunk size, so that setting lives in one config rather than
two.

## Backend roles

Every backend carries a required `role` saying what it is for:

| `role` | Written | Read | What it is for |
|---|---|---|---|
| `main` | every write | preferred | The writable source of truth. Several are fine: all get every write, and the first in config order serves reads. |
| `replica` | every write | when no `main` is reachable | A complete second copy, journal and cursor included. Same traffic as a `main`, but never preferred for reads — so it says "this is a copy" rather than "this is another source of truth". |
| `backfill` | lazily, in the background | never | A copy that grows to cover what you write, for when seeding the whole dataset is impractical or not worth it — see [when to use `backfill`](#when-to-use-backfill). Writes never block on it and never fail because of it. No journal, no cursor. |
| `readOnly` | never | when the source of truth misses or is unreachable | An authoritative store worth serving but not worth writing — an old bucket you are migrating off. |

```json
"backends": [
  { "type": "s3",    "name": "cloud",  "bucket": "…", "role": "main" },
  { "type": "local", "name": "backup", "path": "/mnt/backup", "role": "backfill" }
]
```

A domain is either **writable** — at least one `main`, which every `replica` and
`backfill` target is a copy of — or **purely read-only**, served by `readOnly` stores
alone:

```json
"backends": [ { "type": "s3", "name": "old", "bucket": "archive-2019",
                "role": "readOnly" } ]
```

Such a domain mounts read-only whether or not you set `"readOnly": true` on it, since no
write could land anywhere. The combinations rejected at startup, with the reason, are a
`replica` or `backfill` with no `main` (a copy of nothing), and a domain with no `main`
and no `readOnly` (nothing can answer a read).

Reads never fall back to a `backfill` target, and a `readOnly` store is only consulted
once the source of truth has been asked. A miss is only ever reported as "not there" when
every backend that could have held the file was actually reachable — if one was not, you
get its error instead, because "I could not look" must not arrive as "it is not there".

`tsync resync-remote` repairs a backend that was offline or has drifted, copying whatever
it is missing from another; `--source <name>` picks which backend to copy *from*.

### When to use `backfill`

`backfill` is for the case where copying the existing data is something you cannot or
would rather not do: tens of terabytes already sitting in the source of truth, a slow or
metered link to the second store, or an archive tier where insuring everything costs more
than the data is worth. You accept a target that starts out empty and covers only what you
write from then on.

What that buys you is **partial coverage, never partial files**. Every file the target
holds is whole and restorable on its own, because the manifest only lands once every block
it references is confirmed present. What is missing is entire files — never half of one,
and never a manifest pointing at blocks that were never copied. Coverage only ever grows:
the longer it runs, the more of your active data it holds, while cold data that is never
touched again is simply never copied.

So it is the wrong tool when you need a guarantee — that is what `replica` is for, and it
costs you a full copy of every write. It is the right one when full integrity is not the
priority but broadening coverage over time is worth having for free.

If you do decide to close the gap, `tsync resync-remote --source <main-backend-name>`
copies everything that predates the target. That is also the repair path after a target
has been unreachable for a while — the daemon logs what it dropped.

## Sharing download links

`tsync share <path>` prints a public URL that downloads a file — or a whole folder as a
zip — straight from your bucket, with nothing installed on the other end:

```bash
tsync share photos/2024/report.pdf        # a single file
tsync share photos/2024 --expires 30d     # a folder as a zip; default 7d
```

Downloads are served by a small AWS Lambda that assembles the file (or zips the folder) on
the first fetch and caches the result. To enable sharing, give the domain's S3 backend a
`shareUrl` pointing at that Lambda:

```json
{ "type": "s3", "name": "cloud", "bucket": "…",
  "shareUrl": "https://….lambda-url.us-west-1.on.aws", "role": "main" }
```

The Lambda, its bucket, IAM keys and lifecycle are provisioned by the Terraform config
under [`terraform/`](terraform/README.md), and `tsync configure`'s **Sync from Terraform**
fills in `shareUrl` (plus bucket and credentials) for you — no Terraform details are
stored in your config. With several S3 backends, the first one carrying a `shareUrl` serves
shares. Links carry an unguessable token and expire per `--expires`.

A machine running the `http-proxy` frontend with `"shares": true` can serve share links
itself instead, without a Lambda.

## Chunking and the local cache

Files are split into chunks keyed by a hash of their content, so re-uploading a large file
only sends the chunks that changed, and identical data is stored once no matter how many
files or domains reference it. A file's *manifest* is the small object listing its chunk
keys; that is what versions, renames and reverts manipulate, which is why they are instant
and transfer nothing.

Two sizes, deliberately independent:

- **`chunkSize`** (default 8 MiB) is the upload unit — a network knob. Larger favours
  sequential throughput and smaller manifests; lower it for random-access workloads to cut
  read/write amplification.
- **`cacheChunkSize`** (default 16 MiB) groups consecutive stored chunks into local cache
  files — a disk-latency knob.

A file uploaded under one `chunkSize` still reads correctly after you change the setting;
the size is recorded per file.

`maxCache` puts a soft cap on local cache usage. Past it, the cache files fetched longest
ago are dropped until usage is back under the cap — cache files, not whole files, so a
large file can keep the parts you are reading and lose the parts you are not. Nothing is
delisted, and a dropped range is re-fetched on the next read. `tsync evict` and
`tsync restore` do the same by hand, and both accept directories.

## macOS specifics

The File Provider frontend contributes its own command group, present only in a binary
built with it:

```bash
tsync fileprovider reimport   # drop the extension's cached index and re-enumerate
tsync fileprovider purge      # remove everything installed on this machine
```

`reimport` is the one to reach for when Finder's view disagrees with `tsync ls` — it makes
the extension rebuild its index from the domain rather than its cache. `purge` removes the
File Provider domains, launchd agents, app bundle and cache, but keeps `config.json`, so
`make install` puts you back where you were.

Unlike the FUSE mount, the extension hands back whole files rather than deltas, so a large
file edited in place is re-uploaded in full. Chunk-level dedup still means unchanged blocks
are not re-sent.

## TLS

S3 connections use OpenSSL when it's available (install `lwt_ssl` in your switch), because
it is considerably faster. The native OCaml TLS stack is a built-in fallback, and it can
resolve connection problems OpenSSL causes with some endpoints — Backblaze B2 among them.

Force one with `tsync start --tls native` or a `"tls": "native"` line in the config;
`tsync start` logs which backend is active and what's available.
