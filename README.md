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

The idea is the one behind iCloud Drive or Dropbox Smart Sync, pointed at your own storage, with a password manager alongside.

## Files

- **It is an ordinary folder.** Any application reads and writes it. It is a FUSE mount on Linux, a File Provider location in Finder on macOS, and an app with a documents provider on Android.
- **Only what you open takes space.** The whole tree is listed; content is cached as it is read, and the cache can be capped. A folder can be kept offline, or made online-only again.
- **Several machines share it.** Each one publishes its changes and picks up the others'. Work done in two places at once ends as two files, never as a lost one.
- **History is kept.** With versioning on, every change, rename and delete of a file leaves the previous version behind, and a deleted file can be put back.
- **More than one copy.** A domain can write to a main store and keep replicas on others, and hand out public share links to a file or a folder.

## Secrets

A domain can also keep a **vault**: two-factor codes, logins, notes and passkeys, sealed on your machine before they reach the storage and synced to your other machines like the files.

- **Sealed under two secrets.** A passphrase you remember and a secret key your machines keep: whoever reads the storage or runs the server reads nothing.
- **Filled where you sign in.** AutoFill in Safari and apps on macOS, a Chrome extension on Linux and macOS, autofill on Android, and one-time codes from the macOS menu bar and the Linux tray.
- **Passkeys** are made and used inside tsync: a site gets a signature, never the key.
- **Yours to take out.** The whole vault exports to one sealed file, imports back into a new one, and backs itself up on a schedule to a key no machine keeps.

[The vault](docs/vault.md) covers setting it up and what it protects; [passwords, passkeys and codes](docs/passwords.md) covers using it on each platform.

## Two ways to set it up

**Direct.** Each machine talks to the storage itself, an S3 or GCS bucket, a disk or a NAS. Every machine needs the storage's credentials.

```
laptop  ──┐
desktop ──┼──▶  bucket or disk
```

**Through a server.** One machine runs tsync next to the storage and serves it over HTTPS. Every other machine, phones included, connects to it with one shared secret.

```
laptop  ──┐
desktop ──┼──▶  tsync server  ──▶  bucket or disk
phone   ──┘
```

Both are the same program and the same config file, and you can put a server in front later without moving any data. [Getting started](docs/getting-started.md) walks through a first domain; [run tsync as a server](docs/server.md) adds the server.

## Install

- **macOS** (Apple silicon, macOS 13 or later): [**tsync.pkg**](https://github.com/toots/tsync/releases/download/nightly/tsync.pkg).
- **Linux** (Debian 13, Ubuntu 26.04, Fedora 44; x86-64 and arm64): `curl -fsSL https://toots.github.io/tsync/setup.sh | sudo sh` adds the repository, then `apt install tsync` or `dnf install tsync`.
- **Android** (arm64, Android 8 or later): [**tsync-arm64-v8a.apk**](https://github.com/toots/tsync/releases/download/nightly/tsync-arm64-v8a.apk), which connects to a tsync server.

Then `tsync config --edit` names a folder and its storage. [Install](docs/install.md) has the details, the desktop extras and building from source.

## Good to know

- **Conflicts make copies.** When two machines want one name, the change published second is kept as `report (conflicted copy from laptop).pdf`, next to the first. Nothing is merged and nothing is dropped.
- **Nothing is fetched ahead of time.** A file downloads when it is first read. Run `tsync cache --fetch` on what you need before you lose the network.
- **tsync does not encrypt your files.** Use the bucket's or the disk's own encryption at rest. Transport is HTTPS. Only the [vault](docs/vault.md)'s records are encrypted by tsync.
- **Destructive commands ask twice.** `tsync gc` and `tsync expire` only report what they would do until you add `--apply`.
- **The config is checked strictly.** A misspelled key is an error naming its place in the file, not a setting silently left at its default.

## Documentation

Everything else is in **[docs/](docs/README.md)**: second machines, servers, copies, versions and cleanup, share links, tuning, and the config and command references.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).

Generated passphrases draw from the [EFF large word list](https://www.eff.org/dice) by the Electronic Frontier Foundation, under [CC BY 3.0 US](https://creativecommons.org/licenses/by/3.0/us/), less its four hyphenated words (`lib/vault/eff_large_wordlist.txt`).
