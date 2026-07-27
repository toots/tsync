# tsync

**Mount a library bigger than your disk.** tsync gives you an on-demand sync folder backed by storage you already control — S3, Google Cloud Storage, a local disk or NAS, or another machine running tsync. Everything is listed and browsable; only the files you actually open take up local space.

```
~/tsync/photos/
├── 2019/            ← listed, no local disk used
│   ├── beach.jpg    ← open → fetched on demand
│   └── hike.jpg
└── 2024/
    └── report.pdf   ← evicted → space freed, still listed
```

Same idea as iCloud Drive or Dropbox Smart Sync, pointed at your own bucket instead of somebody else's service — no subscription, no hosted intermediary, and the on-disk format is plain enough that you can walk it with `aws s3 ls`.

## Why you might want it

- **Your disk stops being the limit.** A 4 TB photo library on a 256 GB laptop is fine. Open what you need, `tsync evict` it when you're done, and it goes back to costing nothing but a directory entry.
- **Nothing is re-uploaded twice.** Files are split into content-addressed chunks, so editing one frame of a video sends one chunk, and two copies of the same file are stored once.
- **Several machines, one folder.** Mount the same domain on your laptop, desktop and NAS; they pick up each other's changes through a shared journal. Concurrent renames and delete/rename races produce clearly-labeled conflict copies instead of losing data.
- **More than one backend, if you want.** Keep a bucket *and* a NAS copy. Each backend has a role — source of truth, eager replica, lazily-filled copy, or read-only archive — and writes fan out accordingly.
- **Undo built in.** With versioning on, every modify, rename and delete keeps the previous version. `tsync revert` is instant and downloads nothing.
- **Share a link without a server.** `tsync share` prints a public URL that serves a file, or a whole folder as a zip, straight from your bucket.

## How it works

- **Linux** — a FUSE mount at `~/tsync/<domain>/`.
- **macOS** — a File Provider extension under `~/Library/CloudStorage/`, with Finder integration and sync-status badges.

A background daemon handles transfers and keeps machines in sync. Both platforms share the same on-disk and backend format, so a domain written from one reads cleanly on the other.

## Getting started

You'll need [opam](https://opam.ocaml.org/) and OCaml ≥ 5.5.

**Linux:**

```bash
cd linux
make install-deps      # dependencies, including the FUSE bindings
make install           # build, install the binary, set up the user service
tsync configure        # pick a folder name and a storage backend
tsync start            # mount it
```

**macOS:**

```bash
cd macos
make install           # build the daemon + app, install and load them
tsync configure
```

On macOS you'll need to approve the extension once, in **System Settings → General → Login Items & Extensions → File Provider Extensions**. Your folder then shows up in Finder under **Locations → CloudStorage**.

Already have the files somewhere? `tsync import <dir>` seeds a domain from an existing folder without copying the data anywhere first.

## The commands you'll actually use

```bash
tsync ls <path>        # list files (--deleted includes deleted ones)
tsync evict <path>…    # drop local copies, keep the files listed
tsync restore <path>…  # pull files or whole directories back down
tsync revert <path>    # undo — restore a previous version, or an undeleted file
tsync share <path>     # print a public download URL
tsync sync             # apply changes made on other machines
tsync stats            # transfers in flight, bandwidth, hashing rate
```

`--verbose` on any command prints progress as it runs. There are another dozen or so
commands for maintenance, repair and multi-domain setups.

## Learn more

**[Full documentation →](DOCUMENTATION.md)** — every command, the config file format, backend types and roles, versioning, symlink policies, sharing, and multi-machine setup.

## Good to know

tsync is built for personal and small-scale use, and it's honest about its limits:

- Two machines editing the **exact same file** at the same moment resolve last-writer-wins. (Concurrent renames and delete/rename races *are* handled properly — they produce labeled conflict copies, and nothing is lost.)
- Files download on first open; there's no automatic prefetch. Pull things down ahead of time yourself with `tsync restore`, which takes directories.
- Chunks aren't encrypted by tsync itself — turn on your bucket's server-side encryption if you need encryption at rest.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
