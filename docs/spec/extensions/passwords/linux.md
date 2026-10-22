# Passwords on Linux

This file is normative. It owns what the [passwords](../passwords.md) extension, and the vault
under it, are on a Linux desktop: what this host declares, and where each part of the stack is
realised. The parts are owned elsewhere; this file links them and records what has been seen
working.

## 1. Capabilities

Linux has no system autofill: no platform component asks a credential provider for a login, a
code or a passkey. This host declares no capability
([README §5](../README.md#5-host-adapters)), and has no host adapter.

| capability | interaction | realised by | declared |
|---|---|---|---|
| `fill` | — | none; browsers are served by the browser extension (§4) | — |
| `fill` with codes | — | none; the tray copies codes (§3) | — |
| `save` | — | none; the browser extension (§4) | — |
| `passkey` | — | none; the browser extension (§4) | — |

## 2. The keystore

The owner keeps K and the secret key in a Secret Service item, as
[security-model §10.6](../../algorithms/security-model.md#106-vault-keys-and-passphrases) says,
under the rules every keystore follows ([vault §6.1](../vault.md#61-the-keystore)). A desktop
whose provider (KWallet's `ksecretd`, GNOME Keyring) has its collection unlocked at login keeps
the vault unlocked across restarts of the owner; any other keeps K in memory, and status says
`cached: memory`. The owner runs as a system service from boot, before the user's session and
its bus exist: after a reboot the vault is locked until the user logs in, and unlocks from the
keystore at the first look after that.

## 3. The tray

- **Codes.** The tray's `One-time codes` submenu lists each code domain's records with its
  vault's mark, and copies a record's current code on the user's click, marked sensitive for
  clipboard managers ([linux-tray §6.5](../../frontends/linux-tray.md#65-one-time-codes)).
- **Unlock.** A locked domain's row asks for the passphrase in KDE's password dialog, and for the
  secret key on a machine not enrolled. The tray is tsync's own tool: this is not a host adapter
  unlocking ([README §5](../README.md#5-host-adapters)).
- Codes are added, and a vault is created, changed or deleted, with the CLI.

## 4. The browser extension

The [browser extension](browser.md) on Linux comes from the Chrome Web Store, as on every host;
the packages carry none, and loading `browser/` unpacked is for development only.
`tsync passwords browser install` writes the native-messaging host. A passkey request asking for
user verification asks the vault's passphrase in the extension's sheet
([browser §5](browser.md#5-passkeys)), Linux having no platform verifier.

## 5. Later

- **A KRunner runner**: typing a site in KRunner lists its logins and codes, and copies one.

## 6. Conformance

On KDE Plasma (Wayland), with the vault unlocked:

- After `tsync vault unlock`, restarting the owner finds the vault unlocked, `cached: keystore`;
  `tsync vault lock` leaves no tsync item in the provider's collection. With the collection
  locked, unlock succeeds with `cached: memory` and no dialog appears.
- The tray's codes submenu lists the domain's records; clicking one puts its current code on the
  clipboard, and Klipper's history does not keep it.
- With the vault locked, the row asks for the passphrase; the right one unlocks, a wrong one asks
  again with the owner's sentence.
- The browser extension's conformance ([browser §9](browser.md#9-conformance)) in Chrome.
