# tsync

**Your files in the cloud, on demand — without giving up your local filesystem.**

tsync gives you a folder that lives in cloud storage (S3, or a local disk/NAS) but behaves like an ordinary directory. Every file is visible and browsable, but only the files you actually open take up space on your machine. Open a file and it downloads transparently; evict it and it frees local space while staying available. It's the same idea as iCloud Drive or Dropbox Smart Sync — but pointed at *your* storage bucket, with no third-party service in the middle.

```
~/tsync/photos/
├── 2019/            ← browsable, costs nothing locally
│   ├── beach.jpg    ← open it → downloads on the fly
│   └── hike.jpg
└── 2024/
    └── report.pdf   ← evicted after use → frees space, still listed
```

## Why you might want it

- **Terabytes of files, gigabytes of disk.** Keep a huge library — photos, audio, video, backups — mounted locally while only caching what you touch.
- **Your storage, your rules.** Point it at your own S3 bucket or a local drive. No subscription, no vendor lock-in, no one else holding your data.
- **Mirror to more than one place.** Configure several backends per folder and every write fans out to all of them — e.g. S3 *and* a local NAS at the same time. Reads come from a primary backend (a local one by default), so a mirrored local copy also makes reads fast. If a mirror was down or drifted, `tsync resync-remote` copies whatever it's missing from another backend.
- **Use it from several machines.** Multiple computers can mount the same folder; each picks up the others' changes automatically, with sensible handling when two people touch the same file at once.
- **Efficient by design.** Files are split into content-addressed chunks, so re-uploading a large file only sends the parts that changed, and identical data is stored once.

## How it works, briefly

- **Linux** mounts a FUSE filesystem at `~/tsync/<folder>/`.
- **macOS** uses a File Provider extension, so your folder shows up under `~/Library/CloudStorage/` right alongside iCloud Drive and Dropbox — with native Finder integration and sync-status badges.

Behind the scenes a small background daemon talks to your storage backend, handles uploads/downloads, and keeps multiple machines in sync through a shared change journal. Both platforms share the same on-disk format, so a folder written from Linux reads cleanly on macOS and vice versa.

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
tsync expire <date>   # drop versions older than a date, then reclaim unused blocks
tsync sync            # apply changes made from other machines
tsync recheck         # verify the remote against the local cache, repair what's possible
tsync resync-remote   # copy missing/damaged objects from one backend to the others
tsync import <dir>    # seed the domain from an existing folder (uploads, no data copied)
tsync import <dir> --exclude "*.tmp" --exclude node_modules  # skip files/directories by glob
tsync export <dir>    # write every file of the domain to a plain folder
tsync status          # show daemon state
tsync stats           # transfer metrics (pending/completed, bandwidth, hashing)
tsync stop            # unmount
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

Run `tsync configure` any time to add folders or change backends. See the [configuration reference](IMPLEMENTATION.md#config) for the full config-file format, including how to set up S3 credentials and multiple backends.

## Good to know

tsync is built for personal and small-scale use, and it's honest about its limits:

- Two machines editing the **exact same file** at the same moment resolve last-writer-wins (concurrent renames and delete/rename races *are* handled — they produce clearly-labeled conflict copies, and nothing is lost).
- Files download on first open; there's no bulk prefetch yet.
- Cloud chunks aren't encrypted by tsync itself — turn on your bucket's server-side encryption if you need encryption at rest.
- S3 connections use OpenSSL by default when it is available (install `lwt_ssl` in your switch), because it is much faster in general. The native OCaml TLS stack is a built-in fallback that can resolve connection issues OpenSSL causes with some endpoints (e.g. Backblaze B2). Force it with `tsync start --tls native` or a `"tls": "native"` line in your config. See the [TLS backend](IMPLEMENTATION.md#tls-backend) reference.

For the complete list, plus the design and internals, see **[IMPLEMENTATION.md](IMPLEMENTATION.md)**.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
