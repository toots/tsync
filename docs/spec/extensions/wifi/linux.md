# Wifi on Linux

This file is normative. It owns what the Linux host declares for the [wifi extension](README.md)
and how it realises each capability. The adapter runs in the domain's owner, in the user's
session ([README §5](../../README.md#5-hosts-one-core-several-compositions)).

---

## 1. Capabilities

| capability | status | interaction | realised by |
|---|---|---|---|
| `install` | planned | `silent` | §3.1 |
| `update` | planned | `silent` | §3.2 |
| `remove` | planned | `silent` | §3.2 |
| `list` | planned | `silent` | §3.3 |
| `read` | planned | not seen | §3.4 |

Nothing has been seen in a graphical session yet ([extensions README §5](../README.md#5-host-adapters)).

## 2. When the host offers anything

The adapter talks to NetworkManager over the system bus. At owner start it declares every
capability above only when NetworkManager answers and polkit grants the owner
`org.freedesktop.NetworkManager.settings.modify.own` without authentication, which a local
active session normally has. Otherwise it declares nothing: a headless owner, a remote login,
or another network stack (iwd alone, wpa_supplicant, ConnMan).

## 3. Realisation

### 3.1 install

`Settings.AddConnection` of a wifi connection: the SSID and `hidden`; `wpa-psk` with the password
as `psk`, or WEP keys, or no security; `psk-flags` 0, so NetworkManager keeps the secret itself;
`connection.permissions` naming the session user, so the connection is the user's and needs no
system-wide authorisation; autoconnect on. The connection's UUID is the ledger's host handle.

### 3.2 update and remove

`Update` and `Delete` on the connection the handle names. A managed connection deleted by hand
is `dismissed`.

### 3.3 list

`Settings.ListConnections`, keeping the wifi connections' SSIDs.

### 3.4 read

`GetSecrets` for the connection's wireless-security setting. A secret NetworkManager stores is
returned when polkit allows it. A secret owned by an agent (KWallet, GNOME Keyring) comes from
that agent, which may ask to unlock the wallet. Its interaction is settled when it is seen.

## 4. Seen

droppy (Asahi, KDE), over ssh only (2026-10): polkit answered `auth` for
`settings.modify.system`; secrets came back empty; one network's password lived in KWallet.

## 5. Conformance

- In a KDE and a GNOME session: `install` adds a connection owned by the user with no dialog,
  and it joins when in range; `update` and `remove` act on that connection only; `list` names
  every saved wifi connection.
- `read` returns the password of a NetworkManager-stored and of an agent-stored connection,
  with the interaction its declaration states.
- Over ssh, and with NetworkManager stopped, the host declares nothing and every capability
  command is refused `invalid`.
