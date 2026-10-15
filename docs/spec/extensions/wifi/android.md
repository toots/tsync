# Wifi on Android

This file is normative. It owns what the Android host declares for the
[wifi extension](README.md) and how it realises it. The adapter runs in the app, which is the
domain's owner ([README §5](../../README.md#5-hosts-one-core-several-compositions)).

---

## 1. Capabilities

| capability | status | interaction | why |
|---|---|---|---|
| `install` | planned | `confirm` | §2 |
| `update` | not offered | | adding a network the system already has answers "already exists", whatever its password |
| `remove` | not offered | | an app cannot remove a network it added this way: it belongs to the system |
| `list` | not offered | | the saved-networks list is empty for every app since API 29 |
| `read` | not offered | | no API gives an app a saved password. Routes through the shell user (Shizuku and the like) exist and are not used |

`planned` means seen from a probe app, not yet from the tsync app
([extensions README §5](../README.md#5-host-adapters)).

So on Android: networks are installed with one tap; a changed password is reported `stale`, for
the user to forget the network in Settings; a network whose record is removed stays; and
`import` and `adopt` are refused.

## 2. install

- `ACTION_WIFI_ADD_NETWORKS` (API 30 and later), started from the app's activity, with up to
  five networks per intent. The system shows one sheet; the user approves or declines it.
- The per-network results map as: success → `managed`; already exists → `unmanaged`; failed or
  declined → unchanged, reported.
- The network belongs to the system: it stays after the app is uninstalled, and the system may
  try to join it at once.
- Under `auto`, installs wait for the app's next foreground, and the app then offers them in one
  batch. They never start from the background.

## 3. Entering a network

- **Camera.** The app scans `WIFI:` codes and passes the text to `wifi_add`.
- **Image.** The app accepts an image shared to it and decodes a `WIFI:` code from it. This is
  how a network saved on this phone reaches the vault: Settings → the network → Share shows a
  QR code, which is not protected from screenshots; the user shares the screenshot to tsync.
- **Typed**, in the app's form.

## 4. Showing a code

The screen showing `wifi_code` sets `FLAG_SECURE`, which keeps it out of screenshots and the
recent-apps thumbnail.

## 5. Alternative not taken

The network suggestions API would make installs silent after one approval, and let the app
update and remove them. It is not used: a suggestion is not a saved network, the system chooses
when to use it, the user cannot see or edit it in Settings, and it disappears with the app.

## 6. Seen

Pixel 9a, API 37, probe app (2026-10): the saved-networks list was empty; `ACTION_WIFI_ADD_NETWORKS`
added a network after one tap, which survived uninstalling the probe and triggered a join; adding
a network the phone already had answered "already exists" (code 2) with a different password; the
Settings share QR code was captured by screenshot and decoded offline.

## 7. Conformance

- A record added on another machine is offered at the next foreground and installed after one
  tap; nothing happens while the app is in the background.
- Six pending networks take two sheets.
- A network the phone already has comes back `unmanaged`; after a password change on another
  machine, a managed network is reported `stale`.
- `import`, `adopt` and an `update` are refused `invalid`, naming the capability.
- A screenshot of a shared Settings code, shared to the app, adds the network.
