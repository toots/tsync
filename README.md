<img src="assets/tsync-app.svg" alt="" width="96">

# tsync

A folder backed by storage you control, which downloads a file only when you open it. The storage is an S3 or GCS bucket, a disk or NAS, or another machine running tsync.

```
~/tsync/photos/
├── 2019/            ← listed, takes no local space
│   ├── beach.jpg    ← opened: fetched, then cached
│   └── hike.jpg
└── 2024/
    └── report.pdf   ← made online-only: space freed, still listed
```

The idea is the one behind iCloud Drive or Dropbox Smart Sync, pointed at your own storage:

- **It is an ordinary folder.** Any application reads and writes it. It is a FUSE mount on Linux, a File Provider location in Finder on macOS, and an app with a documents provider on Android.
- **Only what you open takes space.** The whole tree is listed; content is cached as it is read, and the cache can be capped.
- **Several machines share it.** Each one publishes its changes and picks up the others'. Work done in two places at once ends as two files, never as a lost one.
- **History is kept.** With versioning on, every change, rename and delete leaves the previous version behind, and a deleted folder goes to a trash.

## Two ways to set it up

**Direct.** Each machine talks to the storage itself. Every machine needs the storage's credentials, or the disk mounted.

```
laptop  ──┐
desktop ──┼──▶  bucket or disk
```

**Through a server.** One machine runs tsync next to the storage and serves it over HTTPS. Every other machine, phones included, connects to that server with one shared secret. Only the server holds the storage credentials, and it is the one place where you set up the storage, its copies and its share links.

```
laptop  ──┐
desktop ──┼──▶  tsync server  ──▶  bucket or disk
phone   ──┘
```

The two are the same program and the same config file: a server is a domain with an `http-proxy` frontend, and its clients use an `http-proxy` backend. Start direct on one machine and put a server in front later without moving any data.

Full walkthrough and reference: **[docs/](docs/README.md)**.

## Install

### macOS

Download [**tsync.pkg**](https://github.com/toots/tsync/releases/download/nightly/tsync.pkg) and open it. Apple silicon, macOS 13 or later. It installs the app, starts the background service at login and puts `tsync` on your `PATH`. Approve the extension once in **System Settings → General → Login Items & Extensions**.

```bash
tsync config --edit   # name a folder and its storage
launchctl kickstart -k gui/$UID/org.feverdreamtv.tsync.daemon   # restart to apply it
```

Uninstall with `tsync fileprovider purge`. It keeps your config.

### Linux

Packages for Debian 13, Ubuntu 26.04 and Fedora 44, on x86-64 and arm64:

```bash
curl -fsSL https://toots.github.io/tsync/setup.sh | sudo sh   # adds the repository

sudo apt install tsync     # Debian, Ubuntu
sudo dnf install tsync     # Fedora

tsync config --edit                        # name a folder and its storage
sudo systemctl enable --now tsync@$USER    # start now and at every boot
```

What the script does, and the steps to do it by hand, are at [toots.github.io/tsync](https://toots.github.io/tsync/).

Two optional packages for a desktop: `tsync-tray` puts sync status in the system tray, and `tsync-dolphin` adds *Copy Share Link*, *Make Available Offline* and *Make Online Only* to Dolphin's context menu.

After a config change, restart with `sudo systemctl restart tsync@$USER`. Uninstall with `apt remove tsync` or `dnf remove tsync`.

### Android

Install [**tsync-arm64-v8a.apk**](https://github.com/toots/tsync/releases/download/nightly/tsync-arm64-v8a.apk) (arm64, Android 8 or later). The app connects to a machine running tsync as a server, described below; it does not talk to a bucket directly.

## Direct: point it at storage

A config is a list of domains. A domain is one folder: a name, where its data lives, and how it is presented.

```json
{
  "domains": [
    {
      "name": "photos",
      "versioning": true,
      "symlinks": "keep",
      "frontends": ["fuse"],
      "backends": [
        { "type": "s3", "name": "cloud", "role": "main", "bucket": "my-bucket",
          "accessKeyId": "…", "secretAccessKey": "…" }
      ]
    }
  ]
}
```

`tsync config --edit` writes this for you through prompts, and picks the frontend for your system: `fuse` on Linux, `file_provider` on macOS.

| `type` | Storage |
|---|---|
| `s3` | An S3 bucket, or an S3-compatible service through `endpoint` |
| `gcs` | A Google Cloud Storage bucket |
| `local` | A directory: another disk, a mounted NAS |
| `http-proxy` | Another machine running tsync as a server |

A domain can have several backends, each with a role: a `main` that every write waits for, a `replica` or `backfill` that catches up in the background, a `readOnly` archive. For S3 and GCS, [terraform/](terraform/README.md) provisions the bucket, its credentials and the functions behind share links and integrity checks.

## Through a server

On the machine that has the storage, add an `http-proxy` frontend to the domain:

```json
{
  "domains": [
    {
      "name": "photos",
      "versioning": true,
      "symlinks": "keep",
      "frontends": [
        { "type": "http-proxy", "port": 8443, "secret": "<at least 32 characters>",
          "ssl_certificate": "/etc/letsencrypt/live/nas.example/fullchain.pem",
          "ssl_certificate_key": "/etc/letsencrypt/live/nas.example/privkey.pem" }
      ],
      "backends": [
        { "type": "local", "name": "disk", "role": "main", "path": "/mnt/pool" }
      ]
    }
  ]
}
```

On every other machine, the backend is that server:

```json
{
  "domains": [
    {
      "name": "photos",
      "versioning": true,
      "symlinks": "keep",
      "frontends": ["fuse"],
      "backends": [
        { "type": "http-proxy", "name": "nas", "role": "main",
          "url": "https://nas.example:8443", "secret": "<the same secret>" }
      ]
    }
  ]
}
```

`openssl rand -hex 32` makes a secret. Clients refuse plain `http://` to anything but localhost, so the server needs a certificate, its own or a reverse proxy's. The server can also serve share links itself (`"shares": true`), and it shows its status at `https://nas.example:8443/` to whoever has the secret.

## What the folder cannot do

Opening, saving, copying, moving and deleting need no command. The CLI is for the rest:

```bash
tsync status                              # what is running, queued, behind or broken
tsync import ~/Pictures                   # upload a folder you already have
tsync rsync ~/Pictures photos:2024        # copy into a domain, sending only what differs
tsync export video/take3.mov /mnt/disk    # a file straight from the store, resumable
tsync versions --revert notes/todo.txt    # put the previous version back
tsync trash --restore old-project         # bring a deleted folder back
tsync share photos/2024                   # a public link to a file, or a folder as a zip
tsync cache --fetch trip-2024             # keep a folder available offline
tsync cache --evict photos/2019           # free its space, keep it listed
tsync pause                               # hold every change until `tsync resume`
```

A path can name its domain, the same way in every command: `media:photos/2024`. Keeping files offline and freeing their space is also in the file manager's context menu: Finder, Dolphin with `tsync-dolphin`, and the Android app.

## Good to know

- **Conflicts make copies.** When two machines want one name, the change published second is kept as `report (conflicted copy from laptop).pdf`. The one case with a winner: two edits of the same file that were both already uploaded. The later one wins and the other stays in the file's version history, if versioning is on.
- **Nothing is fetched ahead of time.** A file downloads when it is first read. Run `tsync cache --fetch` on what you need before you lose the network.
- **tsync does not encrypt what it stores.** Use the bucket's or the disk's own encryption at rest. Transport is HTTPS.
- **Destructive commands ask twice.** `tsync gc`, `tsync expire` and `tsync trash --purge` only report what they would do until you add `--apply`.
- **The config is checked strictly.** A misspelled key is an error naming its place in the file, not a setting silently left at its default.

## Building from source

Needs [opam](https://opam.ocaml.org/) and OCaml 5.5 or later.

**Linux.** System libraries first: `libfuse3-dev libev-dev libdbus-1-dev` on Debian and Ubuntu, `fuse3-devel libev-devel dbus-devel` on Fedora.

```bash
cd linux
make install      # builds, installs into ~/.local/bin, starts a user service
make uninstall
```

A user service only runs while you have a session, so `make install` enables lingering to have it start at boot. Restart it with `systemctl --user restart tsync`.

**macOS.** Also needs `brew install xcodegen dylibbundler`.

```bash
cd macos
make build        # TsyncApp.app
make deploy       # installed into /Applications and started
```

Signing, notarizing and releasing: [macos/RELEASING.md](macos/RELEASING.md).

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).
