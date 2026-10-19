# Passwords on macOS

This file is normative. It owns how the [passwords](../passwords.md) extension reaches macOS's
AutoFill: which capabilities this host declares, the component that realises them, and what the
user sees. Every capability is planned until it has been seen working on a signed build
([README §5](../README.md#5-host-adapters)); §6 lists what is declared.

## 1. The component

- **An AutoFill credential provider extension**, bundle `org.feverdreamtv.tsync.credentials`,
  for macOS 14 and later (the app itself runs on 13, where no extension loads), embedded in the app, sandboxed, in the App Group `group.org.feverdreamtv.tsync`. It is a client
  of the owner over the shared socket, one connection per request, exactly as the File Provider
  extension is ([file-provider §4.2](../../frontends/file-provider.md), §4.3).
- It holds no K and no secret beyond the one request it answers, writes nothing to disk, and
  logs no password, code, passphrase or key.
- The app and the extension both hold the AutoFill credential provider entitlement, each under
  its own profile: the system lists the extension only when its app holds it too.
- Its `Info.plist` declares `ASCredentialProviderExtensionCapabilities`: `ProvidesPasswords`,
  `ProvidesPasskeys` (macOS 14), `ProvidesOneTimeCodes` (macOS 15), `ShowsConfigurationUI`.
- **Enabling it** is the user's: macOS lists tsync under the AutoFill providers of System
  Settings (*General → AutoFill & Passwords* on macOS 15, *Passwords → Password Options* before).
  The app's menu shows a row "Turn on AutoFill for tsync in System Settings…" while the system
  says the extension is off (`ASCredentialIdentityStore.getState`) and a domain uses passwords;
  it opens System Settings, macOS having no stable link to the pane.

## 2. Domains

The extension asks every domain the shared socket serves that uses `passwords`
([extensions README §3](../README.md#3-opting-in)) and merges their answers as
[README §6.1](../README.md#61-several-domains) says: each row names its domain, and a request
for one record goes to the domain that holds it. A domain that does not answer is left out of a
list, never reported as empty.

## 3. Logins

- **Fill** (`fill`, interaction `confirm`). `prepareCredentialList(for:)` receives the service
  identifiers of the site or app asking: a URL identifier gives the origin, a domain identifier
  `https://<domain>`. The extension's sheet lists, per domain, the logins `passwords_list` matches
  for each origin (§4.2 of passwords), by title and username; the user picks one, and the
  extension completes the request with an `ASPasswordCredential` from `passwords_get`.
- **One-time codes** (`fill` with codes, `confirm`, macOS 15).
  `prepareOneTimeCodeCredentialList(for:)` lists the logins matching the site that link a code;
  the one picked completes with an `ASOneTimeCodeCredential` holding its current code from
  `passwords_get`.
- The extension never answers `provideCredentialWithoutUserInteraction`: every fill shows the
  sheet and waits for the user's pick (passwords §8: no fill without a gesture). It cancels with
  `ASExtensionError.userInteractionRequired`, and the system then shows the sheet.
- The system's identity store is not filled: no site or username leaves the vault for the
  system's suggestion bar.
- **Save** is not offered: macOS hands no typed password to a credential provider.

## 4. Passkeys

- **Creation** (`passkey`, macOS 14). `prepareInterface(forPasskeyRegistration:)` receives an
  `ASPasskeyCredentialRequest`. The extension's sheet names the site (the RP ID) and the user
  name; on approval it sends `passwords_passkey_create` with origin `https://<RP ID>`, the RP ID,
  the user handle, user name and display name, the algorithms the request supports, the request's
  `clientDataHash`, and `verified` (§5), and completes with an `ASPasskeyRegistrationCredential`
  from the reply's credential id and attestation object.
- **Assertion** (`passkey`, macOS 14). `prepareCredentialList(for:requestParameters:)` receives
  the RP ID, the client data hash and the allowed credentials. The sheet lists the passkeys
  `passwords_passkey_match` answers; the one picked is signed with `passwords_passkey_assert` and
  completes with an `ASPasskeyAssertionCredential` (user handle, RP ID, signature, client data
  hash, authenticator data, credential id).
- **The origin.** macOS gives the extension the RP ID, not the page: the system has already
  checked it, against the browser's origin or the app's associated domains. The extension sends
  `https://<RP ID>` as `origin`, so the owner's check (passwords §7.3) still refuses an RP ID that
  is a public suffix.
- An exclusion the owner refuses `exists` completes the registration with
  `ASExtensionError.Code.matchedExcludedCredential` where the system has it, else a failure.

## 5. User verification

- When the request's user verification preference is `required` or `preferred`, the extension
  asks LocalAuthentication to verify the device's owner (`deviceOwnerAuthentication`: Touch ID,
  or the account password) before it sends the request, and sends `verified: true` only when that
  succeeded. A refused or cancelled verification sends nothing and cancels the request.
- With `discouraged`, it verifies nothing and sends no `verified`.
- The extension never sends a passphrase for verification: LocalAuthentication is this host's
  means (passwords §7.4).

## 6. A locked vault

The sheet of any of §3 and §4 on a domain whose vault is locked shows that domain as locked with
an **Unlock** button. It opens the unlock form the menu's dialog uses
([file-provider §10.1](../../frontends/file-provider.md)): a secure field for the passphrase and,
when this Mac is not enrolled, one for the secret key, each with its **Show** box, sent as
`vault_unlock`; then the list is asked again. The extension never caches the unlocked state.

## 7. Capabilities

| capability | interaction | realised by | declared |
|---|---|---|---|
| `fill` | `confirm` | §3, the credential sheet | planned |
| `fill` with codes | `confirm` | §3, macOS 15 | planned |
| `passkey` | `confirm`, `authenticate` when verification is asked | §4, §5, macOS 14 | planned |
| `save` | — | not offered (§3) | — |

## 8. Conformance

With the extension turned on in System Settings and the vault unlocked:

- Safari on `https://github.com/login`, a login for `https://github.com` in the vault: the sheet
  lists it by title and username; picking it fills the username and the password. No fill happens
  without a pick.
- A login linking a TOTP record: on macOS 15 the code field offers its current code.
- `https://webauthn.io`: registering creates a passkey record (`tsync passwords list` shows it),
  after Touch ID when the site asks for verification; signing in with it succeeds, the site
  reporting the authenticator's AAGUID and backup flags.
- With the vault locked, the sheet says so and unlocks with the passphrase; the list follows.
- Nothing the extension does leaves a password, code, passphrase or key in a log or a file of its
  container.
