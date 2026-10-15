# Wifi extension

This file is normative. It owns the `wifi` extension: its record, its fold, the `WIFI:` code,
what each host does with a record, and the commands. It is an extension as the
[README](README.md) defines one, and its records are vault envelopes
([vault §5](vault.md#5-record-envelope)).

---

## 1. Problem

A wifi password is typed once per device, and again on every device when it changes. With this
extension it is entered once, on any device (typed, or scanned from a `WIFI:` QR code), and
every device of the user installs it.

No host lets an application read the passwords it has saved, so tsync never takes a network
from a host. Networks enter only through the user: typed, or scanned from a code the host or
the router shows. A network removed from a host stays in the vault.

## 2. Record

One record per network, at `/.tsync-ext/wifi/<record id>`. Its plaintext is one JSON object,
UTF-8:

```json
{"ssid":"Home","security":"wpa","password":"correct horse","hidden":false,"modified":1760500000}
```

| key | type | rule |
|---|---|---|
| `ssid` | string | 1 to 32 bytes once UTF-8 encoded |
| `security` | `"wpa"` \| `"wep"` \| `"open"` | `wpa` is WPA, WPA2 and WPA3 personal: the host picks the protocol |
| `password` | string | `wpa`: 8 to 63 printable ASCII characters, or 64 hex digits; `wep`: 5 or 13 ASCII characters, or 10 or 26 hex digits; `open`: empty |
| `hidden` | bool | the network does not broadcast its SSID |
| `modified` | int | epoch seconds of the last change a user made |

- Every key is required. A plaintext that breaks a rule is CORRUPT: reported by record id,
  never installed, never folded away.
- Readers ignore unknown members, and a rewrite keeps them.
- Enterprise (802.1X) networks are not records: their credentials are certificates and
  identities, not a password.
- The record id is the first 16 bytes of `HMAC-SHA256(K, "tsync-wifi/" ssid)`, in lowercase hex
  ([README §4.1](README.md#41-where-they-live)). Two machines adding one network meet at one name,
  and the store learns nothing of the SSID. A change of SSID is a new record and the removal of
  the old one.

## 3. Fold

A record and its conflicted copies all hold one SSID. The fold
([README §4.2](README.md#42-the-fold)) keeps the file with the highest `modified` (on a tie, the
bytewise greatest body), moves it to the record id unless it is already there, and removes the
others. A password that loses a concurrent change is superseded: the domain's versions keep it.
The fold reads plaintext, so it waits for an unlocked vault.

## 4. `WIFI:` codes

The text a wifi QR code holds:

```
code   = "WIFI:" *( field ";" ) [ ";" ]
field  = key ":" value
key    = "T" | "S" | "P" | "H" | other
value  = *( char | "\" char )          ; "\" escapes \ ; , : "
```

- **Reading.** Fields are accepted in any order, unknown keys ignored, and a missing final `;`
  tolerated. `S` is the SSID. `T` is `WPA`, `WPA2`, `WPA3` or `SAE` (→ `wpa`), `WEP` (→ `wep`),
  or `nopass` or absent (→ `open`). `P` is the password. `H:true` (any case) sets `hidden`. A
  `T` naming an enterprise type (`WPA2-EAP` and the like), or a result that breaks §2, is
  refused `invalid`.
- **Writing.** `WIFI:T:<T>;S:<ssid>;P:<password>;` then `H:true;` when hidden, then `;`, with
  every value escaped. `<T>` is `WPA`, `WEP` or `nopass`, and `P` is left out for `nopass`.

## 5. Hosts

### 5.1 Capabilities

| capability | means |
|---|---|
| `install` | add a network this host does not have |
| `update` | change the password of a network this host has |
| `remove` | remove a network this host has |
| `list` | read which SSIDs this host has saved (names only) |

| host | declares | how |
|---|---|---|
| macOS (`file_provider`) | install, update, remove, list | CoreWLAN: the password stored with `CWKeychainSetWiFiPassword` in the System domain, the profile saved through the interface configuration. No join, no dialog, no root. |
| Android (`android`) | install | `ACTION_WIFI_ADD_NETWORKS`, which the user confirms with one tap, for up to five networks at a time. The network belongs to the system and survives uninstalling the app. |
| Linux (`fuse`) | install, update, remove, list | NetworkManager over D-Bus: a connection owned by the session user (`connection.permissions`), with the password stored in the connection. With no session bus, or polkit refusing, it declares nothing. |

### 5.2 Managed networks

The owner keeps, per domain, a local **ledger** of the networks it installed: record id, SSID,
and `HMAC-SHA256(K, security ":" password)`, so it knows what it installed without keeping a
password on disk. A network is in one of these states on a host:

| state | means |
|---|---|
| `managed` | in the ledger, and its digest equals the record's |
| `stale` | in the ledger, the record has changed since |
| `missing` | not in the ledger, and the host does not have the SSID (or cannot say) |
| `unmanaged` | not in the ledger, and the host has the SSID |

- tsync changes on a host only the networks in its ledger. A network the user saved by other
  means (`unmanaged`) is never changed until the user adopts it (§6).
- **When the record set changes**, after an arrival, a fold or a local command, with the vault
  unlocked and the `install` option `auto` (§7):
  - `missing` → install, when the host declares `install`;
  - `stale` → update, when the host declares `update`;
  - a ledger entry whose record is gone → remove, when the host declares `remove`; the entry is
    dropped either way.
- On a host without `update` (Android), a `stale` network stays as it is and is reported: the
  user forgets it in the system settings, after which tsync installs it again.
- A host without `list` cannot tell `missing` from `unmanaged`. Android learns it from the
  install: an answer that the network already exists makes it `unmanaged`.
- An install, update or remove that fails leaves the ledger as it was, so the next change
  retries it. The failure is reported, never retried in a loop.
- Removing a network from the host is not seen by tsync on hosts without `list`, and does not
  remove the record on any host.

## 6. Commands

Every verb is of access class **owner**
([07 §2.5](../07-daemon-cli.md#25-one-shot-commands)) and needs K.

| verb / action | request | does |
|---|---|---|
| `add` / `wifi_add` | `code` (a `WIFI:` code), or `ssid`, `security`, `password`, `hidden?` | creates or replaces the network's record; the CLI asks for the password without echo when it is not given by a code |
| `list` / `wifi_list` | — | every record: id, SSID, security, hidden, and this host's state (§5.2); no password |
| `code` / `wifi_code` | `id` | the network's `WIFI:` code, for a guest to scan; the CLI also draws it as a QR code on the terminal |
| `remove` / `wifi_remove` | `id` | removes the record; hosts that manage it remove it (§5.2) |
| `install` / `wifi_install` | `id?` | applies §5.2 now, for one network or all, whatever the `install` option |
| `adopt` / `wifi_adopt` | `id` | puts an `unmanaged` network under management: updates it to the record and adds it to the ledger; needs `update` |

- `wifi_code` is the only reply that carries a password. A host that shows it SHOULD keep it out
  of screenshots and recent-apps thumbnails (Android `FLAG_SECURE`).
- Scanning a code is the host app's business: it passes the scanned text as `code`.

## 7. Options

| option | type | default | rule |
|---|---|---|---|
| `install` | `"auto"` \| `"manual"` | `"auto"` | `manual`: nothing is installed until `install` is run. On Android, `auto` asks for the tap when the app is next in the foreground. |

## 8. Verified and not

The capabilities of §5.1 rest on probes (2026-10): on macOS 26.3, a silent store and readback of
tsync's own password item and a silent profile save; on Android API 37, the add-networks intent
and its already-exists answer. Not yet observed: macOS `update` of a network the system
created rather than tsync, and the Linux path from inside a graphical session. Each MUST be
confirmed before its host declares the capability.

## 9. Conformance

- `WIFI:T:WPA;S:My\;Net;P:pa\:ss;;` reads as SSID `My;Net`, `wpa`, password `pa:ss`, and writes
  back to the same text. `WIFI:S:Cafe;;` reads as an open network. Fields out of order and a
  missing final `;` are read. An enterprise `T`, a 7-character WPA password and a 33-byte SSID
  are refused and write nothing.
- Two machines add one SSID concurrently: one record remains, with the later password, and no
  copy. The store holds no SSID or password in plaintext.
- After `add` on one machine, a macOS and a Linux host with `auto` install it with no dialog; an
  Android host asks for one tap. After a password change, macOS and Linux update it, and Android
  reports it `stale`.
- A network the user saved by hand with the record's SSID is reported `unmanaged` and left
  untouched until `adopt`.
- `remove` removes the network from every host that manages it, and from no other.
- `list` replies hold no password. With the vault locked, every verb is refused `locked` and no
  host is changed.
