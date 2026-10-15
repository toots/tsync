# Wifi extension

This file is normative and host-independent. It owns the `wifi` extension: its record, its fold,
the `WIFI:` code, the capabilities a host may offer and what the extension does without each,
the ledger of managed networks, the commands and the options. It is an extension as the
[extensions README](../README.md) defines one, and its records are vault envelopes
([vault §5](../vault.md#5-record-envelope)).

What each host declares, and how it realises it:

| host | spec |
|---|---|
| macOS | [macos](macos.md) |
| Android | [android](android.md) |
| Linux | [linux](linux.md) |

---

## 1. Problem

A wifi password is typed once per device, and again on every device when it changes. With this
extension it is entered once, on any device, and every device of the user installs it.

Hosts guard their saved passwords: some never give them to an application, others ask the user
for each one. So tsync never takes a network from a host by itself. Networks enter through the
user: typed, scanned from a `WIFI:` code, or imported from the host by an explicit command where
the host can read them (§6.1). A network removed from a host stays in the vault.

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
  ([extensions README §4.1](../README.md#41-where-they-live)). Two machines adding one network
  meet at one name, and the store learns nothing of the SSID. A change of SSID is a new record
  and the removal of the old one.

## 3. Fold

A record and its conflicted copies all hold one SSID. The fold
([extensions README §4.2](../README.md#42-the-fold)) keeps the file with the highest `modified`
(on a tie, the bytewise greatest body), moves it to the record id unless it is already there,
and removes the others. A password that loses a concurrent change is superseded: the domain's
versions keep it. The fold reads plaintext, so it waits for an unlocked vault.

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
- Scanning a code is the host app's: it passes the scanned text to `add` as `code`.

## 5. Capabilities and managed networks

### 5.1 Capabilities

Every capability is optional ([extensions README §5](../README.md#5-host-adapters)).

| capability | means | without it |
|---|---|---|
| `install` | add a network the host does not have | records reach this host's list as `missing`; nothing is installed |
| `update` | change the password of a network the host has | a `stale` network stays as it is and is reported; the user forgets it in the host's settings, after which it is `missing` and installed again |
| `remove` | remove a network the host has | a network whose record is gone stays on the host and is reported; its ledger entry is dropped |
| `list` | read which SSIDs the host has saved (names only) | `missing` and `unmanaged` cannot be told apart before an install; an install the host answers "already exists" makes the network `unmanaged`. A network removed from the host by hand stays `managed` |
| `read` | read the security and password of a network the host has saved | `import` is refused |

A host declares each with its interaction (`silent`, `confirm`, `authenticate`). Only `silent`
capabilities run by themselves (§5.2); the others run from a command the user ran, or when the
host's app is in the foreground.

### 5.2 Managed networks

The owner keeps, per domain, a local **ledger** of the networks it installed: record id, SSID,
`HMAC-SHA256(K, security ":" password)`, so it knows what it installed without keeping a
password on disk, and the host's own handle for the network where the host's spec defines one.
A network is in one of these states on a host:

| state | means |
|---|---|
| `managed` | in the ledger, and its digest equals the record's |
| `stale` | in the ledger, the record has changed since |
| `dismissed` | in the ledger, and the host no longer has the SSID: the user removed it (seen only with `list`) |
| `missing` | not in the ledger, and the host does not have the SSID (or cannot say) |
| `unmanaged` | not in the ledger, and the host has the SSID |

- tsync changes on a host only the networks in its ledger. A network the user saved by other
  means (`unmanaged`) is never changed until the user adopts it (§6).
- **When the record set changes** (an arrival, a fold, a local command), with the vault
  unlocked and the `install` option `auto` (§7):
  - `missing` → install; a `dismissed` network is left alone, the user having removed it;
  - `stale` → update;
  - a ledger entry whose record is gone → remove; the entry is dropped either way.

  Each runs if the host declares the capability, at once if it is `silent`, else at the next
  moment §5.1 allows.
- An install, update or remove that fails, or that the user declines, leaves the ledger as it
  was, so the next change or the next foreground retries it. The failure is reported, never
  retried in a loop.
- Removing a network from the host never removes its record.

## 6. Commands

Every verb is of access class **owner**
([07 §2.5](../../07-daemon-cli.md#25-one-shot-commands)) and needs K.

| verb / action | request | does | needs |
|---|---|---|---|
| `add` / `wifi_add` | `code` (a `WIFI:` code), or `ssid`, `security`, `password`, `hidden?` | creates or replaces the network's record; the CLI asks for the password without echo when no code gives it | — |
| `list` / `wifi_list` | — | every record: id, SSID, security, hidden, and this host's state (§5.2); with `list`, also the host's saved SSIDs that have no record; no password | — |
| `code` / `wifi_code` | `id` | the network's `WIFI:` code, for a guest to scan; the CLI also draws it as a QR code on the terminal | — |
| `remove` / `wifi_remove` | `id` | removes the record; hosts that manage it remove it (§5.2) | — |
| `install` / `wifi_install` | `id?` | applies §5.2 now, for one network or all, whatever the `install` option; a `dismissed` network is installed again | `install` or `update` |
| `adopt` / `wifi_adopt` | `id` | puts an `unmanaged` network under management: updates it to the record and adds it to the ledger | `update` |
| `import` / `wifi_import` | `ssids?`, `replace?` | §6.1 | `list`, `read` |

`wifi_code` and nothing else replies with a password. A host that shows it SHOULD keep it out of
screenshots and task-switcher thumbnails.

### 6.1 Import

`import` copies networks the host has saved into the vault. Only the user starts it.

1. It lists the host's saved SSIDs. The CLI without `ssids` shows that list and asks which to
   import; `--all` takes them all. The action takes `ssids`, the app having shown the host's
   networks from `wifi_list`. The choice comes before any password is read, since a `read` that
   is not `silent` costs the user a gesture per network.
2. A chosen SSID that already has a record is skipped, unless `replace`: the vault may hold a
   newer password than this host. With `replace`, the host's network becomes the record, with
   `modified` set to now.
3. For each remaining SSID it reads the network. A network the user declines, an enterprise
   network, or one whose password breaks §2, is skipped and reported by SSID; the rest go on.
4. Each network read becomes a record, and enters this host's ledger as `managed`: the host
   already has that password.

The reply counts the networks imported, skipped as present, declined and refused.

## 7. Options

| option | type | default | rule |
|---|---|---|---|
| `install` | `"auto"` \| `"manual"` | `"auto"` | `manual`: nothing is installed until `install` is run |

## 8. Conformance

Host-independent; each host spec adds its own.

- `WIFI:T:WPA;S:My\;Net;P:pa\:ss;;` reads as SSID `My;Net`, `wpa`, password `pa:ss`, and writes
  back to the same text. `WIFI:S:Cafe;;` reads as an open network. Fields out of order and a
  missing final `;` are read. An enterprise `T`, a 7-character WPA password and a 33-byte SSID
  are refused and write nothing.
- Two machines add one SSID concurrently: one record remains, with the later password, and no
  copy. The store holds no SSID or password in plaintext.
- Against a fake host declaring each subset of §5.1 at each interaction: `auto` calls only
  `silent` capabilities by itself; each missing capability leads to the outcome its row states;
  a command needing an undeclared capability is refused `invalid`; a declined or failed call
  leaves the ledger unchanged.
- A network the host has under the record's SSID, not in the ledger, is `unmanaged` and left
  untouched until `adopt`.
- `remove` removes the network from every host that manages it, and from no other.
- On a host with `list`, a managed network the user deleted is `dismissed` and not installed
  again by `auto`; `install` with its id installs it again.
- `import` reads only the chosen SSIDs; one already in the vault is skipped without a `read`,
  unless `replace`; a declined `read` skips that network only; imported networks are `managed`
  on the importing host.
- `list` replies hold no password. With the vault locked, every verb is refused `locked` and no
  host is changed.
