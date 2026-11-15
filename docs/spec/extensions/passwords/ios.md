# Passwords on iOS

This file is normative. It owns how the [passwords](../passwords.md) extension reaches iOS's
AutoFill: which capabilities this host declares, the component that realises them, and what the
user sees. Every capability is planned until it has been seen working on a signed build
([README §5](../README.md#5-host-adapters)); §8 lists what is declared.

This page is a delta on [macos.md](macos.md), whose §2 to §6 apply as written, with "the tsync
menu" read as the tsync app, unless this page says otherwise. The framework is the same
(AuthenticationServices); what differs is the process that answers, the OS versions and how the
user turns it on.

## 1. The component

- **An AutoFill credential provider extension**, bundle `$(TSYNC_APP_ID).credentials`
  ([ios.md §3.1](../../frontends/ios.md#31-identifiers)), embedded in the app, in the App Group.
  It owns no domain: every request goes to the domain's owner through the File Provider
  extension's service ([ios.md §5.4](../../frontends/ios.md#54-the-service)), one connection per
  domain, in place of macOS's socket.
- It holds no K and no secret beyond the one request it answers, writes nothing to disk, and
  logs no password, code, passphrase or key. It is not in the keychain access group.
- The app and the extension both hold the AutoFill credential provider entitlement
  (`com.apple.developer.authentication-services.autofill-credential-provider`), each under its own
  profile.
- Its `Info.plist` declares `ASCredentialProviderExtensionCapabilities`: `ProvidesPasswords`,
  `ProvidesPasskeys` (iOS 17), `ProvidesOneTimeCodes` (iOS 18). It shows no configuration UI.
- **Turning it on** is the user's. While the system says the extension is off
  (`ASCredentialIdentityStore.getState`) and a domain uses passwords, the app's Settings shows a
  row under Domains, "Turn on AutoFill for tsync", which on iOS 18 asks the system to turn it on
  (`ASSettingsHelper.requestToTurnOnCredentialProviderExtension`), on iOS 17 opens its settings
  (`openCredentialProviderAppSettings`), and on iOS 16 says where: Settings, Passwords, Password
  Options.

## 2. Domains

macOS §2, over the vault domains the app keeps in the App Group's shared defaults
([ios-app §6](../../frontends/ios-app.md#6-vault)), in config order; a domain among them that
refuses `invalid` uses no passwords and is left out. A domain the service does not reach is the
inert row "`<domain>` did not answer — open tsync"; one turned off in Files, "`<domain>` is turned
off in Files".

- **A new passkey** goes to the first of them, in config order, that uses passwords, as on Android
  ([android-app §10.8](../../frontends/android-app.md#108-vault)): the phone has no default domain.
  A locked one is shown as §6 says, not passed over for another.

## 3. Versions

| What | From |
|---|---|
| logins (macOS §3) | iOS 16, the app's oldest |
| passkeys (macOS §4), and the passkey entries (§4.1) | iOS 17 |
| one-time codes (macOS §3, §3.1) | iOS 18 |
| a registration's excluded credentials (`exclude`) | iOS 18 |

Below a capability's version the extension's `Info.plist` key is inert and the app writes no entry
of that kind.

## 4. The identity store

macOS §3.1's set, written by the app: at launch, each time it comes to the foreground, after an
unlock or a lock from the Vault screen, and after a record is removed from the Passwords tab
(§7). Each writes only when the set changed. A domain the service does not reach contributes
nothing, as a locked one does. The background runs of
[ios.md §5.2](../../frontends/ios.md#52-in-the-background) do not write it: they call no service.

## 5. User verification

macOS §5, with LocalAuthentication's `deviceOwnerAuthentication`: Face ID or Touch ID, else the
device passcode.

## 6. A locked vault

macOS §6, the row reading "`<domain>` is locked — unlock it in the tsync app". An extension cannot
open its app, so the row does nothing when tapped.

## 7. In the app

The Vault screen ([ios-app §6](../../frontends/ios-app.md#6-vault)) gets a **Passwords** tab when a
domain uses `passwords`: [android.md §8](android.md#8-in-the-app) as written, copying as ios-app
§6 says.

## 8. Capabilities

| capability | interaction | realised by | declared |
|---|---|---|---|
| `fill` | `confirm` | macOS §3 | planned |
| `fill` with codes | `confirm` | macOS §3, §3.1, iOS 18 | planned |
| `passkey` | `confirm`, `authenticate` when verification is asked | macOS §4, §5, iOS 17 | planned |
| `save` | — | not offered: iOS hands no typed password to a credential provider | — |
| `suggest` | — | not offered, as on macOS | — |

## 9. Conformance

On a device, with AutoFill turned on for tsync and the vault unlocked from the app:

- Safari on `https://github.com/login`, a login for `https://github.com` in the vault: the sheet
  lists it by title and username; picking it fills both. No fill happens without a pick.
- A login linking a TOTP record: on iOS 18 the code field offers its current code.
- `https://webauthn.io` on iOS 17: registering creates a passkey record (`tsync passwords list` on
  a computer shows it) after Face ID when the site asks for verification; signing in with it
  succeeds.
- With the vault locked, the sheet says so and points to the tsync app; it asks for no passphrase.
- With two domains using passwords, one turned off in Files, the sheet lists the other's logins
  and names the one turned off.
- The extension's container holds no file after a fill, and its log no password, code, passphrase
  or key.
