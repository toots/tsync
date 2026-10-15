# Wifi on macOS

This file is normative. It owns what the macOS host declares for the [wifi extension](README.md)
and how it realises each capability. The adapter runs in the macOS owner, the service process
([README §5](../../README.md#5-hosts-one-core-several-compositions)).

---

## 1. Capabilities

| capability | status | interaction | realised by |
|---|---|---|---|
| `install` | planned | `silent` | §2.1 |
| `update` | planned | `silent` for a network tsync saved; not seen for one the system saved | §2.2 |
| `remove` | planned | `silent` | §2.3 |
| `list` | planned | `silent` | §2.4 |
| `read` | planned | `silent` for a network tsync saved; `authenticate` for one the system saved | §2.5 |

`planned` means seen from a command-line probe, not yet from the service process
([extensions README §5](../README.md#5-host-adapters)). Each becomes `declared` once it is seen
there, with the interaction then observed.

## 2. Realisation

All of it goes through CoreWLAN, on the default wifi interface. None of it joins a network, and
none needs root or Location access (Location guards scanning and the current SSID, which wifi
does not use).

### 2.1 install

1. Store the password in the System keychain domain with `CWKeychainSetWiFiPassword`.
2. Add a `CWNetworkProfile` for the SSID (security from the record) to a mutable copy of the
   interface's configuration, and commit it.

A failure at step 2 deletes the item of step 1. `hidden` needs nothing more: macOS probes for the
saved networks it does not see broadcast. (Not yet seen with a hidden network.)

### 2.2 update

`CWKeychainSetWiFiPassword` over the existing item, and a commit of the profile if the security
changed. Over an item tsync created, it was seen silent. Over an item the system created, which
is what `adopt` and an imported network lead to, it is not yet seen: the item's access list
names only the system's wifi daemon, and the write may ask for an administrator or fail. Until
it is seen, `adopt` and `update` of an imported network are refused `invalid` on macOS.

### 2.3 remove

Commit the configuration without the profile, then `CWKeychainDeleteWiFiPassword`.

### 2.4 list

The SSIDs of the interface configuration's network profiles. Re-read when `wifi_list` or
`import` asks and at owner start: nothing notifies a change to the System keychain.

### 2.5 read

`CWKeychainFindWiFiPassword`. An item tsync created is read silently. An item the system created
shows the administrator dialog (name and password, no Touch ID) once per item, every time: no
"always allow" applies, and root does not avoid it. Cancelling the dialog is a declined `read`.

## 3. Showing a code

The macOS app shows `wifi_code` as a QR code in a window whose `sharingType` is `.none`, which
keeps it out of screenshots and screen sharing.

## 4. Seen

macOS 26.3, command-line probes (2026-10): `CWKeychainSetWiFiPassword` in the System domain
stored silently and was read back silently; a profile list read with no dialog and no Location;
profile add and remove committed with no dialog; `CWKeychainFindWiFiPassword` on a
system-created item showed the administrator dialog each time, also as root; no callback fired
for System keychain changes.

## 5. Conformance

- From the service process, with no user present: `install` and `remove` of a network change
  the saved networks and show no dialog; `list` names them.
- `import` of three system-saved networks shows three dialogs; cancelling the second imports
  the first and third.
- A network tsync installed is read and updated with no dialog.
- No step joins a network or asks for Location.
