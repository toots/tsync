# tsync

An on-demand sync filesystem backed by storage you control — S3, a local disk/NAS, or a remote host over SSH. Files are listed and browsable, but only the ones you open occupy local disk: opening a file fetches it, evicting it frees the space while keeping it listed. Same model as iCloud Drive / Dropbox Smart Sync, pointed at your own backend rather than a hosted service.

```
~/tsync/photos/
├── 2019/            ← listed, no local disk used
│   ├── beach.jpg    ← open → fetched on demand
│   └── hike.jpg
└── 2024/
    └── report.pdf   ← evicted → space freed, still listed
```

## What it does

- **On-demand caching.** Mount a library larger than local disk; only touched files are cached, and eviction reclaims space without losing the file.
- **Bring your own storage.** S3, a local drive, or a remote machine over SSH — no subscription and no hosted intermediary.
- **Multiple backends per domain.** Writes fan out to every configured backend (e.g. S3 *and* a local NAS); reads come from a primary (a local one by default). `tsync resync-remote` repairs a backend that was offline or has drifted by copying what it's missing from another.
- **Multi-machine.** Several machines can mount the same domain and pick up each other's changes through a shared change journal. Concurrent edits resolve last-writer-wins; concurrent renames and delete/rename races produce labeled conflict copies rather than losing data.
- **Content-addressed chunks.** Files are split into chunks keyed by content hash, so re-uploading a large file only sends the changed chunks and identical data is stored once.

## How it works

- **Linux:** FUSE mount at `~/tsync/<domain>/`.
- **macOS:** File Provider extension under `~/Library/CloudStorage/`, with Finder integration and sync-status badges.

A background daemon handles uploads/downloads and keeps machines in sync through the change journal. Both platforms share the same on-disk and backend format, so a domain written from one reads cleanly on the other.

## Getting started

You'll need [opam](https://opam.ocaml.org/) and OCaml ≥ 5.5.

**Linux:**

```bash
cd linux
make install-deps      # install dependencies (includes FUSE bindings)
make install           # build, install the binary, set up the systemd user service
tsync configure        # interactive setup: pick a folder name and a storage backend
tsync start            # mount your folder
```

**macOS:**

```bash
cd macos
make install           # build the daemon + app, install and load them
tsync configure        # interactive setup
```

On macOS, the first time you'll need to approve the extension in **System Settings → General → Login Items & Extensions → File Provider Extensions**. Your folder then appears in Finder under **Locations → CloudStorage**.

## Everyday commands

```bash
tsync ls <path>       # list files (add --deleted to include deleted ones)
tsync evict <path>    # drop a file's local copy (stays in the cloud)
tsync restore <path>  # pull a file back down
tsync versions <path> # a file's version history, or all deleted files
tsync revert <path>   # bring back a previous version (or an undeleted file)
tsync trash           # list deleted folders (folder deletes are recoverable)
tsync untrash <path>  # restore a deleted folder, then run `tsync sync`
tsync expire <date>   # drop versions older than a date, then reclaim unused blocks
tsync sync            # apply changes from other machines (incremental)
tsync sync --full     # clear local cache and re-download all manifests from the backend
tsync recheck         # verify the remote against the local cache, repair what's possible
tsync resync-remote   # copy missing/damaged objects from one backend to the others
tsync import <dir>    # seed the domain from an existing folder (uploads, no data copied)
tsync import <dir> --exclude "*.tmp" --exclude node_modules  # skip by glob (see below)
tsync import <dir> --force-rehash  # re-hash and re-upload every file
tsync export <dir>    # write every file of the domain to a plain folder
tsync share <path>    # print a public download URL for a file or folder (as a zip)
tsync status          # show daemon state
tsync stats           # transfer metrics (pending/completed, bandwidth, hashing)
tsync stop            # unmount
```

Pass `--verbose` (or `-v`) to any command to print detailed progress as it runs.

### Multiple domains

When the config defines more than one domain, pass `--domain <name>` to commands that operate on a specific domain (`ls`, `versions`, `expire`, `sync`, `recheck`, `resync-remote`, `import`, `export`, `share`). To avoid repeating `--domain` on every invocation, set a default:

```bash
tsync set-domain "media"   # persist a default domain for the current machine
tsync set-domain --clear   # remove the default (--domain required again)
```

The default is stored in the data directory and read by every command that accepts `--domain`. An explicit `--domain` flag always overrides it.

### Glob patterns for `--exclude`

`--exclude` accepts shell-style glob patterns matched against each entry's basename **and** its full relative path, so a bare name like `node_modules` prunes that directory anywhere in the tree.

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
```

### Versioning

With versioning enabled (`tsync configure`), every time you modify, rename or delete a file, tsync keeps the previous version. History grows until you trim it with `tsync expire`.

```bash
tsync versions                              # list every file that's been deleted
tsync versions notes/todo.txt               # timestamps of each saved version of a file
tsync revert notes/todo.txt                 # restore the most recent version
tsync revert notes/todo.txt --version <ts>  # restore a specific one
tsync expire 2025-01-01                     # drop versions older than a date, GC unused blocks
```

Because a version is just the file's small manifest (the actual data blocks are shared), `revert` is instant and downloads nothing: the file reappears evicted and only fetches its content the first time you open it.

`tsync expire <date>` removes every version older than the cutoff, then deletes any data block no longer referenced by a live file or a surviving version. The date only bounds versions — blocks are collected purely by whether anything still points at them. Run it while your machines are idle, since collecting blocks a client is mid-upload could race the upload.

Run `tsync configure` any time to add folders or change backends. See the [configuration reference](IMPLEMENTATION.md#config) for the full config-file format, including S3 credentials, SSH backends, and multiple backends per domain.

### Symlinks

Each domain has a required `symlinks` config field:

- **`keep`** — symlinks are first-class objects. `tsync import` stores them as-is (broken/dangling links round-trip faithfully), and you can create them directly in the mounted folder (`ln -s` on the FUSE mount, or via Finder/FileProvider on macOS). Once stored, a symlink works transparently everywhere: `readlink` returns the target, `tsync export` recreates it as a real symlink, and it appears as a symlink in Finder.
- **`follow`** — `tsync import` dereferences symlinks: the target's content is uploaded as a regular file under the link's name; broken links are skipped. Creating a symlink in the mounted folder is rejected.
- **`skip`** — `tsync import` ignores symlinks (they are counted in the import summary). Creating a symlink in the mounted folder is rejected.

Under `follow` and `skip` the domain never contains symlink objects — creation through the mount fails with a permission error, so a link can't slip in past the import policy.

```json
{ "name": "media", "prefix": "tsync", "symlinks": "keep", "backends": [...] }
```

### Read-only domains

Set `"readOnly": true` on a domain to make the mount reject all writes — useful for a machine that should only pull changes, never push them:

```json
{ "name": "media", "prefix": "tsync", "symlinks": "keep", "readOnly": true, "backends": [...] }
```

The sync poller still runs and downloads remote changes normally; only local mutations (create, write, delete, rename) are blocked. On Linux the mount returns `EROFS`; on macOS the FileProvider extension returns an error for any write attempt.

### Sharing download links

`tsync share <path>` prints a public URL that downloads a file — or a whole folder as a zip — straight from your bucket, with nothing installed on the other end:

```bash
tsync share photos/2024/report.pdf        # a single file
tsync share photos/2024 --expires 30d     # a folder, delivered as a zip; link valid 30 days (default 7d)
```

Downloads are served by a small AWS Lambda that assembles the file (or zips the folder) on the first fetch and caches the result. To enable sharing, give the domain's S3 backend a `shareUrl` field pointing at that Lambda:

```json
{ "type": "s3", "bucket": "...", "shareUrl": "https://….lambda-url.us-west-1.on.aws", "main": true }
```

The Lambda, its bucket, IAM keys and lifecycle are all provisioned by the Terraform config under [`terraform/`](terraform/README.md), and `tsync configure`'s **Sync from Terraform** fills the `shareUrl` (plus bucket and credentials) in for you — no Terraform details are stored in your config. With several S3 backends, the first one carrying a `shareUrl` serves shares. Links carry an unguessable token and expire per `--expires`.

## Good to know

tsync is built for personal and small-scale use, and it's honest about its limits:

- Two machines editing the **exact same file** at the same moment resolve last-writer-wins (concurrent renames and delete/rename races *are* handled — they produce clearly-labeled conflict copies, and nothing is lost).
- Files download on first open; there's no bulk prefetch yet.
- Cloud chunks aren't encrypted by tsync itself — turn on your bucket's server-side encryption if you need encryption at rest.
- S3 connections use OpenSSL by default when it is available (install `lwt_ssl` in your switch), because it is much faster in general. The native OCaml TLS stack is a built-in fallback that can resolve connection issues OpenSSL causes with some endpoints. Force it with `tsync start --tls native` or a `"tls": "native"` line in your config.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
