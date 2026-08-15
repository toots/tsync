<img src="assets/tsync-app.svg" alt="" width="96">

# tsync

Mount storage you control as a folder that only downloads what you open. An S3 or GCS bucket, a disk or NAS, or one machine on your network serving all the others.

```
~/tsync/photos/
├── 2019/            ← listed, no local disk used
│   ├── beach.jpg    ← open → fetched on demand
│   └── hike.jpg
└── 2024/
    └── report.pdf   ← evicted → space freed, still listed
```

**It's a folder.** Open files, save them, copy, move, delete, drag things around in Finder — any application works, and there's nothing to learn. A FUSE mount at `~/tsync/<domain>/` on Linux, a File Provider extension at `~/Library/CloudStorage/<domain>/` on macOS.

Only the files you actually open take local space, and evicting one gives the space back without losing it. Same idea as iCloud Drive or Dropbox Smart Sync, pointed at your own storage.

## Point it at storage

```json
{ "type": "s3", "name": "cloud", "bucket": "my-bucket",
  "accessKeyId": "…", "secretAccessKey": "…", "role": "main" }
```

`s3` (including S3-compatible services), `gcs`, or `local` for a disk or mounted NAS.

## Or make one machine the server

Run tsync on the machine that has the storage and let the others mount *through* it. The server holds the credentials, clients need only a shared secret. Same binary, one extra frontend.

On the server, next to the NAS:

```json
{ "frontends": [{ "type": "http-proxy", "port": 8443, "secret": "…" }],
  "backends":  [{ "type": "local", "name": "disk",
                  "path": "/mnt/pool", "role": "main" }] }
```

On every laptop and desktop:

```json
{ "frontends": ["fuse"],
  "backends":  [{ "type": "http-proxy", "name": "nas",
                  "url": "https://nas.example:8443", "secret": "…",
                  "role": "main" }] }
```

They all see the same folder, pick up each other's changes, and none can leak a bucket key. The server can hand out public download links itself, so nothing has to live in the cloud. It also serves a status page at `/`, where the shared secret gets you the whole picture — resolved config, cache, and each backend's health — without ever leaving the browser.

## Beyond the filesystem

Some things a folder has no verb for:

```bash
tsync versions --revert notes/todo.txt   # undo — versions kept on every change
tsync cache --evict photos/2019       # free the space, keep the files listed
tsync share photos/2024       # public link to a file, or a folder as a zip
tsync import ~/Pictures       # seed a domain from files you already have
```

Files are split into content-addressed chunks, so editing one frame of a video uploads one chunk, and two copies of the same file are stored once. A domain can also have more than one backend — a bucket *and* a NAS copy — each one's role saying whether it gets every write or fills in lazily in the background.

## Install

### macOS

Download [**tsync.pkg**](https://github.com/toots/tsync/releases/download/nightly/tsync.pkg) and open it. It is signed and notarized, installs the app as a login item that runs the background daemon, and puts the `tsync` CLI on your `PATH`. Apple silicon only for now.

```bash
tsync config --edit   # folder name and a storage backend
```

Uninstalling is `tsync fileprovider purge`.

### Linux

Grab a package for your distribution from the [nightly
release](https://github.com/toots/tsync/releases/tag/nightly) — Debian 13,
Ubuntu 26.04 LTS and Fedora 44, each for x86-64 and arm64.

```bash
sudo apt install ./tsync_*.deb     # Debian / Ubuntu
sudo dnf install ./tsync-*.rpm     # Fedora

tsync config --edit                    # folder name and a storage backend
sudo systemctl enable --now tsync@$USER
```

The service is a systemd template instanced on the user to run as, so it starts
at boot without anyone logging in. Uninstall with `apt remove tsync` or
`dnf remove tsync`.

### Building Linux from source

Needs [opam](https://opam.ocaml.org/) and OCaml ≥ 5.5.

```bash
cd linux
make install-deps
make install     # builds, installs, starts the background service
tsync config --edit  # folder name and a storage backend
make install     # re-run to restart with the new config
```

This installs into `~/.local/bin` and runs as a **user** service, which systemd
only keeps alive while you have a session — `make install` therefore enables
lingering for you, so it survives a reboot on a headless machine. `make
uninstall` reverses all of it.

### Building macOS from source

Needs opam, OCaml ≥ 5.5, and `brew install xcodegen dylibbundler`.

```bash
cd macos
make build       # complete TsyncApp.app
make deploy      # ... installed into /Applications and started
```

How the bundle is put together, and how to sign, notarize and release it:
**[macos/RELEASING.md](macos/RELEASING.md)**.

Full walkthrough, from install to multi-machine setups: **[DOCUMENTATION.md](DOCUMENTATION.md)**.

## Good to know

- Two machines editing the **same file** at once resolve last-writer-wins. Concurrent renames and delete/rename races are handled — they leave labeled conflict copies, and nothing is lost.
- No automatic prefetch: files download on first open. `tsync cache --fetch` pulls things down ahead of time, directories included.
- Chunks aren't encrypted by tsync — use your bucket's server-side encryption if you need encryption at rest.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
