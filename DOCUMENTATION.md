# tsync documentation

A walkthrough in order: follow it from the top for a working setup, then read on as needed.

**Getting there**
1. [Install](#1-install)
2. [Create your first domain](#2-create-your-first-domain)
3. [Mount it](#3-mount-it)
4. [Put your files in](#4-put-your-files-in)
5. [Using it](#5-using-it)

**Going further**

6. [Add a second machine](#6-add-a-second-machine)
7. [Run tsync as a server for your network](#7-run-tsync-as-a-server-for-your-network)
8. [Add a second backend](#8-add-a-second-backend)
9. [Versions, trash and cleanup](#9-versions-trash-and-cleanup)
10. [Share public download links](#10-share-public-download-links)
11. [Tuning](#11-tuning)

**Reference** — [config file](#config-file-reference) · [all commands](#command-reference) ·
[backend types](#backend-type-reference) · [backend roles](#backend-role-reference) ·
[symlink policies](#symlink-policies) · [TLS](#tls) · [macOS](#macos-specifics) ·
[troubleshooting](#troubleshooting)

---

## 1. Install

On **macOS**, download [`tsync.pkg`](https://github.com/toots/tsync/releases/download/nightly/tsync.pkg) — signed, notarized, Apple silicon — and open it. It installs `TsyncApp.app`, registers it as a login item, and starts the `tsync` daemon (shipped inside the bundle at `Contents/MacOS/tsync`) as a launchd agent. The same binary is the CLI, so the installer also symlinks it to `/usr/local/bin/tsync`. Uninstall with `tsync fileprovider purge`.

Approve the extension once in **System Settings → General → Login Items & Extensions → File Provider Extensions**.

To build it yourself instead, you need [opam](https://opam.ocaml.org/), OCaml ≥ 5.5 and `brew install xcodegen dylibbundler`:

```bash
cd macos
make build          # complete TsyncApp.app
make deploy         # ... installed into /Applications and started
make package        # signed, notarized dist/tsync.pkg (needs Developer ID credentials)
```

[`macos/RELEASING.md`](macos/RELEASING.md) covers the bundle layout, the signing
credentials and the release workflow.

On **Linux**, install a package from the [nightly
release](https://github.com/toots/tsync/releases/tag/nightly) — Debian 13,
Ubuntu 26.04 LTS and Fedora 44, for x86-64 and arm64. It puts `tsync` in
`/usr/bin` and ships a systemd template unit instanced on the user to run as,
so it starts at boot with nobody logged in:

```bash
sudo apt install ./tsync_*.deb     # Debian / Ubuntu
sudo dnf install ./tsync_*.rpm     # Fedora
sudo systemctl enable --now tsync@$USER
```

On a desktop, `tsync-tray` is a separate package that puts sync status in the
notification area — see [Linux specifics](#linux-specifics). It is kept apart so
a server does not pull a tray it cannot show, or the D-Bus library it needs:

```bash
sudo apt install ./tsync-tray_*.deb
sudo dnf install ./tsync-tray_*.rpm
```

To build it yourself instead, you need [opam](https://opam.ocaml.org/) and
OCaml ≥ 5.5:

System libraries first — the FUSE headers, libev, and libdbus for the tray:

```bash
sudo apt install libfuse3-dev libev-dev libdbus-1-dev   # Debian / Ubuntu
sudo dnf install fuse3-devel libev-devel dbus-devel      # Fedora
```

```bash
cd linux
make install-deps   # includes the FUSE bindings
make install
```

That variant installs into `~/.local/bin` and runs as a *user* service, which
systemd only keeps alive while you have a session, so `make install` also
enables lingering. `make uninstall` reverses it.

```bash
tsync build-info   # compiled-in features, and where config, cache, data and socket live
```

`build-info` matters: the S3 backend and each frontend are only compiled in if their
dependencies were available at build time. Naming one that isn't fails at startup, saying so.

## 2. Create your first domain

A *domain* is one synced folder with its own storage and settings. `tsync config --edit` asks,
in this order:

| Prompt | What to say |
|---|---|
| Client name | This machine's name. Labels conflict copies. Defaults to the hostname. |
| Max concurrent uploads / downloads | Defaults (4 and 8). |
| Domain name | The folder name, e.g. `media`. |
| Enable versioning? | Defaults to yes, for undo — [step 9](#9-versions-trash-and-cleanup). |
| Symlinks policy | `keep` unless you have a reason. See [symlink policies](#symlink-policies). |
| Read-only mount? | No, for now — [step 6](#6-add-a-second-machine). |
| Chunk size / cache chunk size / max local cache | `default` / `none` — [tuning](#11-tuning). |
| Backend type | `s3`, `gcs`, `local` or `http-proxy`; defaults to `local`, the one type that needs no bucket or credentials. See [backend types](#backend-type-reference). |
| Backend name | A label, used by `mirror --source`. |
| *(s3/gcs)* Fill from Terraform? | Only with the [bundled Terraform](terraform/README.md), applied with either `terraform` or `tofu`; otherwise `n` and type the bucket and keys. |
| Role | `main` for the first backend; a cloud backend added after one defaults to `replica`. The others in [step 8](#8-add-a-second-backend). |
| Add another backend? | No, for now. |
| Frontend type | `fuse` on Linux, `file_provider` on macOS — both offered as the default. `headless` is for a domain driven over IPC with nothing to mount. |
| Add another frontend? | No — skip `http-proxy` until [step 7](#7-run-tsync-as-a-server-for-your-network). Only the types not already configured are offered. |

The simplest result — a folder backed by another disk:

```json
{
  "name": "laptop",
  "domains": [
    {
      "name": "media",
      "symlinks": "keep",
      "versioning": true,
      "frontends": ["fuse"],
      "backends": [
        { "type": "local", "name": "disk", "path": "/mnt/pool", "role": "main" }
      ]
    }
  ]
}
```

Edit the file by hand any time; re-running `tsync config --edit` on an existing config becomes
an editor. Then check it:

```bash
tsync config   # what the daemon parsed, secrets masked
```

Reach for that whenever behaviour doesn't match what you configured: unrecognised fields
pass through rather than being rejected, so a typo can look like it was set.

## 3. Mount it

You don't run `tsync start` yourself. A background service does — on Linux a systemd
unit, `tsync@<user>` from the package or a user unit if you built from source
([step 1](#1-install)), and on macOS a launchd agent the installer sets up.

After configuring, restart the service so it picks up the new config:

```bash
tsync restart
tsync status
```

Your folder is `~/tsync/<domain>/` on Linux and `~/Library/CloudStorage/<domain>/` on macOS,
where Finder also shows it under **Locations → CloudStorage**.

From there on you interact with your files as if they were local files on your hard drive:
open, save, copy, move, delete, from any application or command-line tool.

`tsync stop` unmounts; running `tsync start` by hand runs the daemon in the foreground instead.

## 4. Put your files in

Either copy files into the mounted folder, or import what you already have. Import hashes
and uploads each file — no local copy first — and is safe to re-run, since files whose
content already matches are skipped.

```bash
tsync import ~/Pictures
tsync import ~/Pictures --exclude '*.tmp' --exclude '**/.git'
tsync import ~/Music --only '*.flac'
```

`--only` picks what to include (everything, if you pass none); `--exclude` then removes from
that. Both may be repeated, and both match each entry's basename **and** its full relative
path, so a bare `node_modules` matches at any depth.

| Pattern | Matches |
|---------|---------|
| `*` | Any characters, **not** crossing a directory separator |
| `**` | Any characters, **including** directory separators |
| `?` | A single character, **not** a directory separator |
| anything else | Itself literally — `+`, `.`, `(`, `)`, spaces, … |

The way out is `tsync export <dir>`: the whole domain as ordinary files and directories,
symlinks included, nothing tsync-specific left behind.

## 5. Using it

**The interface is the folder.** Open files, save them, copy, move, rename, delete, drag
things around in Finder or your file manager, point any application at it. Opening a file
fetches it; nothing needs to be told in advance. This is how you'll use tsync almost all of
the time, and none of it involves the CLI.

The commands exist to inspect what's there, and for the few things a filesystem has no verb
for — freeing space without deleting, reaching a previous version, handing out a link:

```bash
tsync ls <path>              # inspect, --deleted included
tsync cache --evict <path>…  # drop local copies; files stay listed
tsync cache --fetch <path>…  # pull files or whole directories back down
tsync status                 # transfers in flight, bandwidth, hashing rate
```

Both `evict` and `restore` take directories, so `tsync cache --fetch trip-2024/` is how you prepare
for a flight. `--verbose` (or `-v`) works on any command.

## 6. Add a second machine

Install tsync there and give it a domain with **the same backend**. The two find each
other's changes through a journal kept alongside the data.

```bash
tsync sync          # apply changes made elsewhere, incrementally
tsync sync --full   # clear the local cache, re-read everything from the backend
```

The daemon polls on its own; `tsync sync` is for when you want it now.

A machine that should only pull, never push, gets a read-only domain. The poller still
downloads normally; only local writes are refused (`EROFS` on Linux, an error from the
extension on macOS):

```json
{ "name": "media", "symlinks": "keep", "versioning": true, "readOnly": true,
  "frontends": ["fuse"], "backends": [...] }
```

Two machines editing the *same file* at once resolve last-writer-wins. Concurrent renames
and delete/rename races leave a copy beside the original, named after the machine that
lost — `report (conflicted copy from laptop).pdf`, extension kept so it still opens. That
name is the `Client name` from step 2.

## 7. Run tsync as a server for your network

Rather than give every machine your bucket credentials, run tsync on one machine and let the
others mount through it. The `http-proxy` frontend serves a domain over HTTP; the
`http-proxy` backend type consumes it. This is what to reach for where you might otherwise
have wanted storage over SSH.

**On the server** — the machine with the disk or the bucket keys:

```json
{ "frontends": [{ "type": "http-proxy", "port": 8443, "secret": "a-long-random-string",
                  "ssl_certificate": "/etc/letsencrypt/live/nas/fullchain.pem",
                  "ssl_certificate_key": "/etc/letsencrypt/live/nas/privkey.pem" }],
  "backends":  [{ "type": "local", "name": "disk", "path": "/mnt/pool",
                  "role": "main" }] }
```

Both TLS options must be set together, or neither — with neither it serves plain HTTP, only
reasonable on a network you trust.

Or leave TLS to a reverse proxy. If you already run nginx, Caddy or Traefik, that is usually
easier: certificate renewal, HTTP/2, access logs and external exposure are all things it
already does. Drop the two `ssl_*` lines, give the frontend a plain port, and let the proxy
terminate TLS:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    client_max_body_size 64m;   # must exceed the domain's chunkSize
    proxy_request_buffering off;
    proxy_read_timeout 300s;
}
```

`client_max_body_size` is the one that bites: nginx defaults to 1 MB, a chunk upload is up to
`chunkSize` (8 MiB by default), so uploads fail until you raise it. Clients then point `url`
at the proxy. tsync's listener has no bind-address option — it accepts on all interfaces —
so firewall the plain port if the machine is reachable from elsewhere.

**On every client:**

```json
{ "frontends": ["fuse"],
  "backends":  [{ "type": "http-proxy", "name": "nas",
                  "url": "https://nas.example:8443", "secret": "a-long-random-string",
                  "role": "main" }] }
```

Clients hold no storage credentials, only the shared secret, and inherit the serving
domain's chunk size — so that setting lives in one config instead of every one.

Two server-side options:

- `"shares": true` serves public download links itself — [step 10](#10-share-public-download-links).
- `"readOnly": true` refuses writes *from proxy clients* while the server still accepts them
  on its own mount.

A server can front several domains, and can mount a domain it serves: frontends are per
domain, so `["fuse", {"type": "http-proxy", …}]` does both.

### Checking on the server

A server has no IPC socket, so `tsync status` cannot reach it. It reports on itself over HTTP
instead, on the same port and behind the same signature as the object API:

| Route | Returns |
|---|---|
| `/` | A page that asks for the shared secret and shows the report |
| `/stats` | The report as plain text — the same thing `tsync status` prints for a mount |
| `/api/v1/stats` | The same data as JSON |
| `/domains` | The domains this server serves to holders of the signing secret, as JSON |

`/domains` is what a client asks before it has a config — the Android app's setup form fills
its domain list from it. It answers with the domains that secret is good for, not everything
the listener fronts:

```json
{ "domains": [ { "name": "Family Photos", "readOnly": false } ] }
```

Open `/` in a browser and type the shared secret. It stays in that browser: the page signs
each request with it and sends only the signature, exactly as a proxy client does. Note that
browsers only expose the signing primitive over HTTPS or on `localhost` — over plain HTTP to
another machine the page falls back to a signer built into it, which works but signs in the
clear like every other request on that connection.

The report opens with the process answering it, named as the frontend it is. A listener serves
every domain configured on it, so its cpu, its bytes and its request counts cover all of them
at once — it says which domains those are rather than filing the numbers under one.

Then each domain, with the config as the daemon actually resolved it, its local chunk cache
against `maxCache`, unpublished journal entries, and two lists:

- **Frontends** — everything serving that domain. The listener appears with the settings that
  are this domain's (`readOnly`, `shares`); a fuse mount is a process of its own, so it
  reports its own cpu, its own transfer figures, what it has read and written through the
  mount, open handles, and its queues. A mount that should be there and isn't says so, with
  the socket it was asked on.
- **Backends** — every store behind it, by name, type and role, each saying what it points at
  (bucket, URL or path, secrets masked), whether it answers and how fast, its journal backlog,
  free space for a `local` store, and for a `replica` or `backfill` target how far behind it is.

It ends with the last warnings and errors from every subsystem, which is usually where the
answer is.

For scripts, `/api/v1/stats` is the same data with raw byte counts:

```bash
secret=a-long-random-string
path=/api/v1/stats
ts=$(date +%s)
body_hash=$(printf '' | openssl dgst -sha256 -r | cut -d' ' -f1)
sig=$(printf 'GET\n%s\n%s\n%s' "$path" "$ts" "$body_hash" \
      | openssl dgst -sha256 -hmac "$secret" -r | cut -d' ' -f1)
curl -sS "https://nas.example:8443$path" \
  -H "x-tsync-timestamp: $ts" -H "x-tsync-signature: $sig"
```

Add `?totals=1` (to either route) to also count what each backend holds. That enumerates the
manifest and chunk namespaces, so it costs a full listing per backend and is never done
otherwise — every other figure is fixed-cost however large the domain. The query string is
part of what gets signed.

## 8. Add a second backend

A domain can have several backends, each with a **role**:

| `role` | Written | Read | What it is for |
|---|---|---|---|
| `main` | every write, and the write waits for it | preferred | The writable source of truth. Several are fine: all get every write, the first in config order serves reads. |
| `replica` | every write, in the background | when no `main` is reachable | A complete second copy, journal and cursor included. A write returns as soon as the mains have it, so a slow or unreachable replica never sets the pace of a copy — it catches up afterwards. |
| `backfill` | lazily, in the background | never | A copy that grows to cover what you write. Writes never block on it and never fail because of it. No journal, no cursor. |
| `readOnly` | never | when the source of truth misses or is unreachable | An authoritative store worth serving but not writing — an old bucket you're migrating off. |

A bucket plus a local copy that fills in over time:

```json
"backends": [
  { "type": "s3",    "name": "cloud",  "bucket": "…", "role": "main" },
  { "type": "local", "name": "backup", "path": "/mnt/backup", "role": "backfill" }
]
```

Repairing a backend that was offline or has drifted:

```bash
tsync mirror                    # copy what's missing between backends
tsync mirror --source cloud     # ...copying *from* the named one
```

### Chunks that are not what their names say

A chunk's name *is* the hash of its bytes. So a store can check every chunk it takes with
nothing but the chunk itself: hash what landed, compare it to the name it arrived under. What
fails is recorded as an object under `tsync/corrupted/<domain>/`, and reading the list is just
a listing of that prefix.

This catches what a size comparison cannot. A chunk that is the right length but holds the
wrong bytes — a whole chunk written under another one's name — passes every check that only
looks at metadata.

Who does the checking depends on the store:

- **`local`** checks each chunk as it writes it (`verifyWrites`, on by default). It costs one
  read back per chunk written, usually from the page cache; turn it off for a store where
  throughput matters more than finding out early.
- **`s3` and `gcs`** check in a function the bucket itself triggers on each new object, so the
  chunks are never downloaded to be checked. It comes with the Terraform module — nothing to
  name, nothing to set on the client. The same function also carries out the deletes a `gc`
  hands it — see [§9](#9-versions-trash-and-cleanup).

```bash
tsync data-integrity              # what each store found, and which stores nothing is checking
tsync data-integrity --detail     # ...and what each bad chunk hashed to instead
tsync data-integrity --verify     # ask every store that can to check all of its chunks
tsync data-integrity --repair     # rewrite them from a copy that hashes to the right key
tsync data-integrity --repair --dry-run   # ...say what would be rewritten, write nothing
```

`tsync data-integrity` distinguishes a store that looked and found nothing from a store nothing
is checking. Both would otherwise report zero, and only one of those is good news.

`--verify` is the stores' own work: an s3 or gcs bucket queues one request per shard into
itself, and its object-created notification hands each to the same function that checks a fresh
upload — so a whole-store pass needs no queue service and runs the same per-chunk check. It then
follows the sweep, reporting how many shard requests are left as the store works through
them; interrupting stops the watching, not the checking. A store with nothing on its side to run a check says so and the
command fails, rather than reporting one that never happened.

On a `local` store, `tsync gc --verify` sweeps the whole thing: a collection already walks every
chunk a file still references, so checking them as it goes costs one pass instead of two. It is
opt-in because it reads every live byte where a collection otherwise touches only metadata —
minutes become hours on a large store. A chunk that fails is kept where it belongs and marked,
never reclaimed: a file still names it, so discarding it would take that file's only copy too.
This is also the pass that finds bit rot, which arrives as an unreadable chunk rather than a
wrong one and is recorded the same way.

`--repair` hashes a candidate copy before trusting it — a second copy can be wrong too, and
writing one bad chunk over another would spread the damage while reporting a repair. It writes
only to the damaged store. Where no store holds good bytes, it names the chunks rather than
reporting success: re-upload the files that use them, or fill this backend from one that still
has them (`tsync mirror`).

Nothing deletes a marker directly. It is cleared by the store re-checking the object as it
takes the next write — which is also why simply saving the file again repairs it, and why a
chunk known to be bad is re-uploaded instead of being deduplicated against.

### Catching up

Neither a `replica` nor a `backfill` target is written on the path of your copy. A write lands
on the mains and returns; each target then works through what it owes on its own. So writing a
file into the mount runs at the speed of the fastest `main` — a local disk stays a local disk —
and a cloud copy behind it costs nothing but time it spends on its own.

What each target still owes is kept on disk, under `<data dir>/deferred-pending/<domain>/`, and is
recorded before the write is reported done. Losing the network, or the machine, does not lose
it: a failure that can clear (a dropped link, a throttling store) is waited out and retried,
and anything still queued when the daemon stops is picked up when it next starts. `tsync status`
shows how far behind each target is.

Two things are not waited out. A failure that cannot clear — a wrong credential, a bucket that
refuses writes — drops the job rather than blocking everything queued behind it, and the target
is reported `DEGRADED` from then on. So is a queue that has grown absurd. Both mean the target
is missing data that patience will not supply: `tsync mirror --source <main>`.

Between a write and its target catching up, that write exists only on the mains. With a single
local `main`, that means only on that machine — which is the trade being made.

### Choosing between `replica` and `backfill`

`replica` is a guarantee, and costs a full copy of every write.

`backfill` is for when copying the existing data is something you cannot or would rather not
do: tens of terabytes already in the source of truth, a slow or metered link, an archive tier
where insuring everything costs more than the data is worth. The target starts empty and
covers only what you write from then on.

What that buys is **partial coverage, never partial files**. Everything the target holds is
whole and restorable, because a manifest only lands once every block it references is
confirmed present. What's missing is entire files — never half of one, never a manifest
pointing at blocks that were never copied. Coverage only grows; cold data nothing touches
again is never copied.

`tsync mirror --source <main>` is how a target added to an existing domain gets filled,
and the repair path after one has been reported `DEGRADED`. A target that is merely behind
needs no help.

### Rules

A domain is either **writable** — at least one `main`, which every `replica` and `backfill`
is a copy of — or **purely read-only**, served by `readOnly` stores alone:

```json
"backends": [ { "type": "s3", "name": "old", "bucket": "archive-2019",
                "role": "readOnly" } ]
```

That domain mounts read-only whether or not you set `"readOnly": true`, since no write could
land. Rejected at startup, with the reason: a `replica` or `backfill` with no `main` (a copy
of nothing), and no `main` and no `readOnly` (nothing can answer a read).

Reads never fall back to a `backfill` target, and a `readOnly` store is consulted only after
the source of truth has been asked. A miss is reported as "not there" only when every
backend that could have held the file was reachable — otherwise you get its error, because
"I could not look" must not arrive as "it is not there".

## 9. Versions, trash and cleanup

With `"versioning": true`, every modify, rename and delete keeps the previous version.

```bash
tsync versions                                         # every file that's been deleted
tsync versions notes/todo.txt                          # timestamps for one file
tsync versions --revert notes/todo.txt                 # restore the most recent version
tsync versions --revert notes/todo.txt --version <ts>  # restore a specific one
```

A version is just the file's small manifest — blocks are shared — so `revert` is instant and
downloads nothing. The file reappears evicted and fetches content on first open.

Deleting a *folder* goes to a trash area instead of expanding into per-file deletes, which is
what makes it recoverable:

```bash
tsync trash                  # list trashed folders
tsync trash --restore <path> # bring one back, then run tsync sync
tsync trash --purge <path>   # drop one for good, with all its versions
```

History grows until you trim it, in two steps:

```bash
tsync expire 2025-01-01   # drop the old versions
tsync gc                  # reclaim the blocks that leaves unreferenced
```

`expire` drops every version, trashed folder and journal entry older than the cutoff. That
is what stops old blocks being referenced, but it does not remove them — `gc` does, and it
goes purely by whether anything still points at a block, with no notion of a date.

They are separate commands because only some stores can do the second. `gc` reclaims by
renaming the block directory aside and moving every block a live file still names back under
the original name; what is left behind is the garbage, named rather than worked out, and
deleting it is the last step. That needs a rename inside the store, which a filesystem has
and an object store does not — so `gc` runs on a **local main store** and says so plainly
otherwise. `expire` works on every backend.

Unlike the older single-command version, this is safe to run while machines are working. A
client uploading a file whose blocks already exist promotes them before publishing, so a
block cannot be reclaimed out from under an upload that deduplicated onto it. Replicas and
backfill targets are never renamed and never walked: each is simply sent the same keys the
main is discarding, so a remote store on cold storage sees deletes and nothing else, and the
cost is the garbage's rather than the layout's. Filling a copy that has fallen behind is
`tsync mirror`'s job, not this one's.

An `s3` or `gcs` copy takes those deletes rather than performing them: `gc` writes the batch
as a small request object, the bucket's own notification hands it to the same function that
checks blocks, and the collection moves on without waiting. Nothing to configure — the
function comes with the bucket, the same terraform deploying both halves of it.

A request only clears when the function runs. If one does not — a bucket whose stack predates
this, a notification you wire yourself and have not — the copy keeps blocks nothing
references: wasted space, not lost data. `tsync gc` says so when it starts and `tsync gc
--status` lists what is outstanding, which is the only thing that will, since those keys are
already gone from the main and no later collection meets them again.

The notification fires once, when the request is written, so fixing the function afterwards
does not make it pick up what it missed. `tsync gc --retry-jobs` hands those requests over
again; it is safe to repeat, and `tsync mirror` remains the way to reconcile a copy whose
requests are long gone.

A collection over a large store takes a while, and can be spread over several sittings or
paced to stay out of the way:

```bash
tsync gc --budget 30m        # stop after about half an hour, resume next time
tsync gc --pause 1s          # idle between batches
tsync gc --concurrency 1     # one operation at a time
tsync gc --status            # is one open, how far along, what is outstanding
tsync gc --retry-jobs        # hand outstanding delete requests over again
tsync gc --abort             # abandon an open one, keeping every block
```

Leaving a collection open is safe indefinitely: reads look in both places and writes were
never redirected. While one is open the block prefix holds only part of the store, so
`tsync status` says so and `tsync mirror` refuses until it finishes.

## 10. Share public download links

```bash
tsync share photos/2024/report.pdf      # one file
tsync share photos/2024 --expires 30d   # a folder, as a zip (default 7d)
```

Links carry an unguessable token and expire. Two ways to serve them.

**From a server you already run.** With [step 7](#7-run-tsync-as-a-server-for-your-network),
set `"shares": true` on the `http-proxy` frontend and it serves links itself, zipping folders
on the fly. Nothing in the cloud.

**From AWS Lambda,** for a bucket with no machine in front of it. Give the S3 backend a
`shareUrl`:

```json
{ "type": "s3", "name": "cloud", "bucket": "…",
  "shareUrl": "https://….lambda-url.us-west-1.on.aws", "role": "main" }
```

The Lambda assembles the file (or zips the folder) on first fetch and caches it. It, its
bucket, IAM keys and lifecycle come from the Terraform config under
[`terraform/`](terraform/README.md), and `tsync config --edit`'s **Sync from Terraform** fills in
`shareUrl`, bucket and credentials — no Terraform details are stored in your config. With
several S3 backends, the first with a `shareUrl` serves shares.

Those assembled copies pile up under `shares/cache/` in the bucket, and nothing expires them.
To reclaim the space:

```
tsync share --clear-cache
```

Published links are untouched and keep working — the next download assembles again.

## 11. Tuning

All optional; the defaults are reasonable.

**`chunkSize`** (default 8 MiB) is the unit of upload, download and dedup. It trades writes
against reads:

- **Smaller** — an edit dirties one small chunk, so re-uploads send less. But a read spans
  more chunks, each its own request, so reads cost more round trips. Manifests hold more keys.
- **Larger** — an edit re-uploads a whole large chunk, so edits cost more. But reads are
  fewer, bigger requests, better for streaming, and manifests are smaller.

Small for data edited in place (disk images, databases, documents you keep saving); large for
write-once media you mostly stream.

**`cacheChunkSize`** (default 16 MiB) is how many consecutive chunks share one local cache
file. It trades disk work against how much is transferred to serve the first byte:

- **Larger** — fewer, bigger files, so less per-file overhead and better disk throughput once
  the data is local.
- **Smaller** — less to fetch before the first byte can be served.

Reading any byte of a group materializes the whole group: the file is sized on disk up front
and its chunks are fetched concurrently, each writing its own range, so a cold read costs
about one round trip whatever the value. What a larger value costs is bytes — the whole group
is transferred to serve the first byte of it — and coarser eviction, since a cache file is
dropped whole.

Keep it a small multiple of `chunkSize`. Raise it for sequential streaming off a fast link;
lower it when opening a file promptly matters more than throughput.

Changing `chunkSize` doesn't break existing files — the size is recorded per file, and
grouping derives from the file's own value.

**`maxCache`** is a soft cap on cache usage. Past it, the cache files fetched longest ago are
dropped until usage is back under — cache files, not whole files, so a large file can keep
the parts you're reading and lose the parts you aren't. Nothing is delisted; a dropped range
is re-fetched on next read.

**Concurrency.** `maxUploads` (default 4) bounds upload operations — how many files the
upload workers process at once. `maxChunkBuffers` (default: `maxUploads`) bounds how many
chunk bodies are held in memory at once across all of them, so the upload path costs about
`maxChunkBuffers` × the domain's chunk size. Lower it on a memory-tight host to raise
`maxUploads` without raising the ceiling: the extra uploads then overlap the round trips that
carry no chunk — dedup checks, manifest writes, TLS setup. `maxDownloads` (default 8) bounds
concurrent file downloads.

Sizes accept a byte count or a suffixed string — `512K`, `8M`, `1G`, binary multiples — so
both `8388608` and `"8M"` work.

---

# Reference

## Config file reference

`tsync build-info` says where it lives.

Top level:

| Field | Required | Meaning |
|---|---|---|
| `name` | no | This machine's name, used to label conflict copies. Defaults to the hostname. |
| `domains` | yes | One entry per synced folder. |
| `maxUploads` | no | Concurrent upload operations, default `4`. |
| `maxChunkBuffers` | no | Chunk bodies held in memory at once, default `maxUploads`. |
| `maxDownloads` | no | Concurrent file downloads, default `8`. |
| `tls` | no | `"openssl"` or `"native"` — see [TLS](#tls). |

Per domain:

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Domain name; also the mount directory name. |
| `backends` | yes | See [backend types](#backend-type-reference) and [roles](#backend-role-reference). |
| `frontends` | yes | Non-empty. A type name (`"fuse"`) or an object `{"type": …, …options}`. Types: `fuse`, `file_provider`, `http-proxy`. |
| `symlinks` | yes | `keep`, `follow` or `skip` — see [symlink policies](#symlink-policies). |
| `versioning` | yes | Keep previous versions on modify/rename/delete. |
| `readOnly` | no | Make the mount refuse writes. Forced on when no backend is writable. |
| `chunkSize` | no | Upload chunk size. Default 8 MiB, or what the backend recommends. |
| `cacheChunkSize` | no | Local cache file size. Default 16 MiB. |
| `maxCache` | no | Soft cap on local cache usage. Unbounded when absent. |

## Command reference

```bash
tsync ls <path>                # list files (add --deleted to include deleted ones)
tsync cache --evict <path>…    # drop the local copy of files or whole directories
tsync cache --fetch <path>…    # pull files or whole directories back down
tsync versions <path>          # a file's version history, or all deleted files
tsync versions --revert <path> # bring back a previous version (or an undeleted file)
tsync trash                    # list deleted folders
tsync trash --restore <path>   # restore a deleted folder, then run tsync sync
tsync trash --purge <path>     # drop a trashed folder for good, with all its versions
tsync expire <date>            # drop versions, trashed folders and journal entries older than a date
tsync gc                       # reclaim unreferenced blocks (local main stores only)
tsync gc --verify              # ...and check each chunk it keeps against its own name
tsync sync                     # apply changes from other machines (incremental)
tsync sync --full              # clear local cache and re-download all manifests
tsync data-integrity           # list chunks a store found were not what their names say
                               # --verify asks the stores to check everything; --repair fixes it
tsync mirror                   # copy missing/damaged objects from one backend to the others
tsync import <dir>             # seed the domain from an existing folder
tsync export <dir>             # write every file of the domain to a plain folder
tsync share <path>             # print a public download URL for a file or folder (as a zip)
tsync share --clear-cache      # drop what the share server has assembled and cached
tsync status                   # full report: metrics, running commands, config, cache, backends
tsync status --totals          # also count what each backend holds (a full listing per backend)
tsync logs                     # show the daemon log (-f to follow, -n N for how far back)
tsync config                   # show the config as parsed, with secrets masked
tsync config --edit            # interactive setup / editor
tsync build-info               # compiled-in features, and the paths this binary uses
tsync default-domain           # print the default currently in effect
tsync default-domain <name>    # persist it for this machine (--clear to forget)
tsync pause-uploads            # stop uploading; queued work is kept
tsync resume-uploads           # start again
tsync restart                  # restart the service so it re-reads the config
tsync start                    # mount in the foreground (the installed service runs this)
tsync stop                     # unmount
```

`--verbose` / `-v` works on all of them.

### Reading the log

The daemon keeps no log file of its own: it logs through `syslog(3)` and lets the platform
store the result. `tsync logs` is a thin wrapper over whichever reader that platform
provides, so it inherits that platform's requirements:

| Platform | Reads | Requires |
|---|---|---|
| Linux | the systemd journal, via `journalctl -t tsync` | **systemd-journald**. On a system without it there is nothing to read, and `tsync logs` says so. Use your syslog daemon's own files instead. |
| macOS | `~/Library/Logs/tsync-daemon.log`, via `tail` | the LaunchAgent installed by `install-agent.sh`, which is what points the daemon's output at that file. |

On Linux the journal is matched by syslog identity (`tsync`), not by unit name, so renaming
the unit or switching between the user unit and the packaged system instance does not affect
it. Nothing rotates the macOS log file.

Only the daemon's log. On macOS the File Provider extension is started by the OS, so its
output goes to the unified log — `log show --predicate 'subsystem == "org.feverdreamtv.tsync"'`.
Separately, the daemon keeps its last 50 warnings and errors in memory and reports them as
`recentErrors` in `tsync status`, which is how an http-proxy server — no journal of its own to
point at — explains itself.

### Multiple domains

With more than one domain, pass `--domain <name>` to commands that act on a specific one
(`ls`, `versions`, `expire`, `gc`, `sync`, `mirror`, `import`, `export`,
`share`). `tsync default-domain <name>` persists a default; an explicit `--domain` always wins.

`tsync status` is the exception: it always reports on every configured domain, and takes no
`--domain`. A report answers for the machine, so narrowing it — by the flag or by the default
— would leave the rest of what runs here unaccounted for. Each domain that has a daemon of its
own gets its own report, and a domain whose daemon is not answering is named on stderr without
costing the others theirs.

### Running commands

`gc`, `mirror`, `import`, `export`, `sync` and `data-integrity` can run for hours, and a
one-shot command is otherwise invisible to everything else on the machine: its own stdout is
the only account of it, and only whoever started it is reading that. Each pushes a summary to
its domain's daemon every ten seconds, and `tsync status` grows a `Jobs` block:

```
Jobs
  import  pid 979109  running 0m 10s  /media/files/stage
    current          Music Production/…/freedia0272.MXF
    counted          2499 files, 6000 planned, 0 skipped, 0 symlinks, 0 failed
    traffic          up 1.6 GB (159.1 MB/s), down 0 B (0 B/s), 2500 chunks hashed
    memory           108.0 MB rss + 40.0 MB swapped, 75.0 MB heap, 41.0 MB live
    deferred         207 queued, 3 in flight
                     DEGRADED, run tsync mirror
    slots            chunk buffers 4/4 (12 waiting)
    backend          91 retries (87 timeouts), 0 failed
```

`current` is what the command is on right now — the file being imported, the folder being
marked, the object being copied — rather than the last one it finished, which for a large file
is a name from hours ago. `slots` above zero waiting is the difference between work that is
slow and work that is queued behind a bound; `backend` appears only when something was retried.
`memory` reads resident beside live words, which is what separates something retained from an
allocator that has not given anything back.

Reporting is advisory. A command run with no daemon — the ordinary case — reports nothing and
runs exactly the same; nothing here can fail a command. A row disappears once its process is
gone, so a killed command leaves none, and a finished one lingers a few minutes marked `done`
or `failed`.

The daemon reports the same `traffic`, `slots`, `memory` and `backend` figures for itself, at
the top of `tsync status`.

## Backend type reference

Every backend needs a `type`, a `name` (used by `mirror --source`) and a
[`role`](#backend-role-reference).

| `type` | Required fields | Optional | Notes |
|---|---|---|---|
| `s3` | `bucket`, `accessKeyId`, `secretAccessKey` | `region` (default `us-east-1`), `endpoint`, `shareUrl`, `unsignedPayload` | Also works with S3-compatible services (Backblaze B2, MinIO, …) via `endpoint`. |
| `gcs` | `bucket`, `serviceAccountKey` | `endpoint`, `shareUrl` | `serviceAccountKey` is the service-account JSON itself, not a path to it. Blank only to reach an emulator anonymously, with `endpoint`. |
| `local` | `path` | `verifyWrites` (default on) | A directory: another disk, a mounted NAS, anything the filesystem reaches. |
| `http-proxy` | `url`, `secret` | — | Another machine running tsync with the `http-proxy` frontend — [step 7](#7-run-tsync-as-a-server-for-your-network). |

## Backend role reference

See [step 8](#8-add-a-second-backend) for the table and rules. In short: `main` is the source
of truth and the only role a write waits for, `replica` a complete copy that catches up behind
it, `backfill` a converging copy that starts empty, `readOnly` an archive read but never
written. At least one `main`, or `readOnly` stores alone.

## Symlink policies

The domain's `symlinks` field:

- **`keep`** — symlinks are first-class objects. `tsync import` stores them as-is (broken and
  dangling links round-trip faithfully), and you can create them in the mount (`ln -s`, or
  via Finder). `readlink` returns the target, `tsync export` recreates a real symlink, Finder
  shows it as one.
- **`follow`** — `tsync import` dereferences them: the target's content is uploaded as a
  regular file under the link's name, broken links skipped. Creating one in the mount is
  rejected.
- **`skip`** — `tsync import` ignores them (counted in the summary). Creating one in the mount
  is rejected.

Under `follow` and `skip` the domain never holds symlink objects, so one can't slip in past
the import policy.

## TLS

Conduit compiles its TLS backend in from an optional dependency, so which ones a build has
is settled in the switch, by two virtual packages:

| Package | Pulls | Backend |
| --- | --- | --- |
| `tsync-tls` | `tls-lwt` | `native` — the pure OCaml stack, builds anywhere |
| `tsync-ssl` | `lwt_ssl` | `openssl` — considerably faster, wants a system libssl |

`tsync` depends on `tsync-tls | tsync-ssl`, so a plain `opam install tsync` picks up the
native one and https works out of the box. Install both to have the choice at runtime;
opam rebuilds conduit when either appears in the switch.

OpenSSL is preferred when compiled in. Native is worth forcing on endpoints that trip
OpenSSL's per-connection error queue — Backblaze B2 among them — with `tsync start --tls
native` or `"tls": "native"`. `tsync start` logs which is active and what's available.

## macOS specifics

The File Provider frontend contributes its own commands:

```bash
tsync fileprovider reimport   # drop the extension's cached index and re-enumerate
tsync fileprovider purge      # remove everything installed on this machine
```

`reimport` is for when Finder disagrees with `tsync ls` — it rebuilds the index from the
domain instead of the cache. `purge` unregisters the File Provider domains and the launchd
agent, then removes the app bundle and cache; it keeps `config.json`, so reinstalling the
app puts you back.

Unlike the FUSE mount, the extension hands back whole files rather than deltas, so a large
file edited in place is re-uploaded in full. Chunk dedup still keeps unchanged blocks off the
wire.

## Linux specifics

`tsync-tray` shows what each domain is doing in the notification area, next to
bluetooth and wifi: an icon whose glyph says idle, transferring, paused or
unreachable, and a menu listing the files currently in flight. Clicking a domain
opens its folder, clicking a file selects it in the file manager, and *Pause
uploads* is the same switch as `tsync pause-uploads` — it applies to every domain, and
the checkmark shows what the daemon actually did rather than what it was asked.

Under each domain sit the files moving right now, uploads and downloads alike
and drawn the same way. A download appears when something reads a file whose
content is not cached and has to come from a backend; the ones too small or too
brief to notice are left out, so a thumbnailer walking a folder does not fill
the menu. `tsync status` lists them all, unfiltered.

*Stats* opens a submenu with the short version of `tsync status`: the daemon's
pid and uptime, its cpu and memory, what it has moved and how fast, then per
domain the mount, the cache, what is queued, what has been read and written,
anything the journal still owes, and each backend's role, reachability and
backlog. Figures the daemon does not report are left out rather than drawn as
zero. It is read when the menu opens rather than on the tray's poll — answering
it means reaching every backend — so it is current as of the moment you opened
it, not live. `tsync status` remains the full report, and the only one carrying
recent warnings.

The `tsync-tray` package installs an autostart entry, so it comes up with the
desktop. Turn it off in your desktop's Startup Applications, or:

```bash
cp /etc/xdg/autostart/tsync-tray.desktop ~/.config/autostart/
echo 'Hidden=true' >> ~/.config/autostart/tsync-tray.desktop
```

Run it by hand with `tsync-tray -v` to see what it makes of your session.

It draws nothing itself — it publishes a
[StatusNotifierItem](https://freedesktop.org/wiki/Specifications/StatusNotifierItem/)
over D-Bus and the desktop's panel draws it, so it behaves the same under X11
and Wayland. KDE Plasma, XFCE, Cinnamon and LXQt host those out of the box.
**GNOME Shell does not**: it dropped the status area in 3.26 and needs the
*AppIndicator and KStatusNotifierItem Support* extension
(`gnome-shell-extension-appindicator`, packaged under that name on Debian,
Ubuntu and Fedora). Without it the tray starts, registers, and simply has nobody
to draw it.

Quitting from the menu stops only the tray. The daemon is a separate service,
and `systemctl --user stop tsync` — or `tsync@$USER` for the system unit — is
what stops syncing.

## Troubleshooting

| Symptom | Try |
|---|---|
| Behaviour doesn't match the config | `tsync config` — unrecognised fields pass through, so a typo can look set. |
| "frontend X is configured but not compiled into this binary" | `tsync build-info`; rebuild with the dependency available. |
| Config rejected at startup | The message names the domain, backend and reason. Roles are checked at parse time, so `tsync config` catches them too. |
| Finder disagrees with `tsync ls` (macOS) | `tsync fileprovider reimport`. |
| A backend was offline and has fallen behind | `tsync mirror --source <name>`. |
| Local cache and remote disagree | `tsync sync --full`. |
| Daemon state unclear | `tsync status`, `tsync status`, and `tsync logs -f` — [reading the log](#reading-the-log). |
| One backend of several is misbehaving | `tsync status` — each backend reports its own reachability, journal backlog and how far behind it is. |
| A `replica` or `backfill` target is behind | Normal: it catches up on its own, and what it owes survives a restart. `tsync status` says by how much. |
| A target says `DEGRADED` | Writes were dropped — refused, or queued past all reason: `tsync mirror --source <main>`. |
| No tray icon on GNOME | Install `gnome-shell-extension-appindicator` and log back in — GNOME has no built-in host. |
| No tray icon elsewhere | Run `tsync-tray -v` in a terminal; it says whether it found a host, and stays running if it did not. |
| A domain served over http-proxy misbehaves | Open the server's `/` page, or `curl` its `/stats` — [step 7](#checking-on-the-server). The server has no IPC socket, so `tsync status` cannot reach it. |
