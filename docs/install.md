# Install


## macOS

Download [`tsync.pkg`](https://github.com/toots/tsync/releases/download/nightly/tsync.pkg) and open it. It needs Apple silicon and macOS 13 or later. The package is signed and notarized. It installs `TsyncApp.app` into `/Applications`, registers a background service that starts at login, and links the `tsync` command into `/usr/local/bin`.

Approve the extension once in **System Settings → General → Login Items & Extensions → File Provider Extensions**. The first start may also ask once for access to data from other apps; allow it.

Uninstall with `tsync fileprovider purge`. It removes the app, the service and the local data, and keeps your config.

## Linux

Packages exist for Debian 13, Ubuntu 26.04 and Fedora 44, on x86-64 and arm64. Add the repository, then install:

```bash
curl -fsSL https://toots.github.io/tsync/setup.sh | sudo sh

sudo apt install tsync     # Debian, Ubuntu
sudo dnf install tsync     # Fedora
```

[toots.github.io/tsync](https://toots.github.io/tsync/) lists what the script does, for doing it by hand. The same packages are attached to the [nightly release](https://github.com/toots/tsync/releases/tag/nightly) if you would rather install a file. `apt upgrade` and `dnf upgrade` pick up new builds, and an upgrade restarts the running service.

The package installs `/usr/bin/tsync` and a systemd unit, `tsync@.service`, that runs as the user you name. Enable it once you have a config ([start it](getting-started.md#start-it)).

Two optional packages for a desktop, kept apart so that a server does not pull in libraries it cannot use:

| Package | What it adds |
|---|---|
| `tsync-tray` | Sync status in the system tray |
| `tsync-dolphin` | *Copy Share Link*, *Make Available Offline* and *Make Online Only* in Dolphin's context menu |

Both are described under [Linux desktop](desktop.md#linux-desktop).

## Android

Install [`tsync-arm64-v8a.apk`](https://github.com/toots/tsync/releases/download/nightly/tsync-arm64-v8a.apk) from the nightly release. It needs an arm64 phone and Android 8 or later. The app talks to a tsync server, so set one up first: [run tsync as a server](server.md), then [use it from an Android phone](android.md).

## From source

You need [opam](https://opam.ocaml.org/) and OCaml 5.5 or later.

**Linux.** Install the system libraries, then build:

```bash
sudo apt install libfuse3-dev libev-dev libdbus-1-dev   # Debian, Ubuntu
sudo dnf install fuse3-devel libev-devel dbus-devel     # Fedora

cd linux
make install
```

`make install` builds tsync with FUSE and both TLS implementations, links it into `~/.local/bin`, installs shell completion, and installs and starts a *user* service. systemd stops a user service when your last session ends, so the same step enables lingering for your account, which keeps it running and starts it at boot. `make uninstall` removes the service and the binary and leaves lingering on.

**macOS.** Also install `xcodegen` and `dylibbundler` from Homebrew.

```bash
cd macos
make build      # TsyncApp.app
make deploy     # installed into /Applications and started
make package    # signed, notarized dist/tsync.pkg (needs Developer ID credentials)
```

[`macos/RELEASING.md`](../macos/RELEASING.md) covers the bundle, signing and releases.

## Check what you installed

```bash
tsync build-info
```

```
frontends: fuse, http-proxy
drivers: gcs, http-proxy, local, s3
tls: openssl, native
service log: journalctl -t tsync
config: /home/you/.config/tsync/config.json
data: /home/you/.local/share/tsync
cache: /home/you/.cache/tsync
```

`frontends` and `drivers` are what this binary can do. A source build leaves out a frontend whose library was missing at build time, and a config that names it is refused with "not compiled into this build".
