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
  The app's menu shows a row "Turn on AutoFill for tsync in System Settings…" on macOS 14 and
  later, in a build that carries the extension, while the system says the extension is off
  (`ASCredentialIdentityStore.getState`) and a domain uses passwords;
  it opens System Settings, macOS having no stable link to the pane.

## 2. Domains

The extension asks every domain the shared socket serves that uses `passwords`
([extensions README §3](../README.md#3-opting-in)) and merges their answers as
[README §6.1](../README.md#61-several-domains) says: each row names its domain, and a request
for one record goes to the domain that holds it. Each row shows its vault's mark
([vault §8.1](../vault.md#81-appearance)): the vault's icon, or the tsync glyph in the vault's
colour; a passkey's row says so in its detail. A domain that does not answer is shown as an
inert row "`<domain>` did not answer — check that tsync is running", never reported as empty.
Each sheet completes its request once: a pick or an approval replaces the sheet's buttons with a
spinner and **Cancel**, and the request is completed or cancelled at most once.

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
  `ASExtensionError.userInteractionRequired`, and the system then calls
  `prepareInterfaceToProvideCredential(for:)`. The system offers such a request for a credential
  it remembers from an earlier pick, whose record may since be gone: the extension shows the
  sheet of the request's kind for its service (the logins, or the passkeys of its RP ID), never
  completing from the remembered record alone.
- It logs which entry point each request arrived through, and the number of rows it listed,
  under the subsystem `org.feverdreamtv.tsync.credentials`.
- **The identity store** holds one-time code entries (§3.1) and passkey entries (§4.1); no login
  identity leaves the vault for the system's suggestion bar.
- **Save** is not offered: macOS hands no typed password to a credential provider.

### 3.1 Identity entries

Both kinds of entry are written together by the app, as one set (§3.1 "Who saves it" below);
§4.1 says what a passkey entry holds.

#### One-time codes

The system offers a provider's code on a code field only for an entry the provider saved in
`ASCredentialIdentityStore`; without one it never asks the extension for a code.

- **What is saved.** One `ASOneTimeCodeCredentialIdentity` per login that links a code and per
  web site of that login: the site's host as a domain service identifier, the label
  `<title> — <username>` (the title alone when there is no username), and the record identifier
  `<domain>/<id>`. Never a seed or a code. A site with a port is a URL identifier, so its entry
  matches that port only; an `android://` site is skipped.
- **Who saves it.** The app, from `passwords_list` with `use: false` (a refresh does not keep the
  vault from its idle lock) of every domain using passwords, when its
  menu opens and every 60 seconds; it replaces the store's whole set of entries, codes and
  passkeys, and writes only when the set changed. The system empties the store while AutoFill
  is off, so the next refresh after it is turned on writes the whole set again. A locked or unreachable domain contributes nothing, so the entries go once every
  vault is locked. Nothing is written while AutoFill is off for tsync.
- **A code request** for an entry reaches `provideCredentialWithoutUserInteraction`, which
  declines as for a login (§3); `prepareInterfaceToProvideCredential(for:)` of a one-time code
  request shows the code sheet of the entry's site, and the code picked completes with an
  `ASOneTimeCodeCredential`.

## 4. Passkeys

- **Creation** (`passkey`, macOS 14). `prepareInterface(forPasskeyRegistration:)` receives an
  `ASPasskeyCredentialRequest`. The new passkey goes where README §6.1 sends a new record: the
  only domain using passwords, else the default domain when it uses them; with several and none
  the default, the sheet names them and how to set the default, and adds nothing. A locked one
  is shown as §6 says, not passed over for another. The sheet names
  the site (the RP ID), the user name and that domain; on approval it sends
  `passwords_passkey_create` with origin `https://<RP ID>`, the RP ID, the user handle, user name
  and display name, the algorithms the request supports, its excluded credentials as `exclude`
  (macOS 15), the request's `clientDataHash`, and `verified` (§5), and completes with an
  `ASPasskeyRegistrationCredential` from the reply's credential id and attestation object.
- **Assertion** (`passkey`, macOS 14). `prepareCredentialList(for:requestParameters:)` receives
  the RP ID, the client data hash and the allowed credentials. The sheet lists the passkeys
  `passwords_passkey_match` answers; the one picked is signed with `passwords_passkey_assert` and
  completes with an `ASPasskeyAssertionCredential` (user handle, RP ID, signature, client data
  hash, authenticator data, credential id).
- The same call carries the service identifiers of the page when the page also takes a password,
  as a sign-in page asking for a passkey in its autofill does. The sheet then lists that site's
  logins after its passkeys, as §3 does; a login picked completes with an
  `ASPasswordCredential`. A page that asks for a passkey and holds no login field shows the
  passkeys alone.
- **The origin.** macOS gives the extension the RP ID, not the page: the system has already
  checked it, against the browser's origin or the app's associated domains. The extension sends
  `https://<RP ID>` as `origin`, so the owner's check (passwords §7.3) still refuses an RP ID that
  is a public suffix.
- An exclusion the owner refuses `exists` cancels the registration with
  `ASExtensionError.Code.matchedExcludedCredential` where the system has it, else a failure.
- A reply missing a binary member fails the request; nothing completes with empty data.
- A **Cancel** while `passwords_passkey_create` runs removes the passkey it created
  (`passwords_remove`): no site holds its public key.

### 4.1 Passkey entries

Safari names a provider's passkeys in its suggestions only for entries the provider saved;
without them it shows the system's "More from tsync…", which opens the sheet.

- **What is saved.** One `ASPasskeyCredentialIdentity` per passkey: its RP ID, user name,
  credential id and user handle, and the record identifier `<domain>/<id>`. All of them a
  relying party holds; never the private key. Written with the code entries, under the same
  rules (§3.1).
- **Picking one is the pick** (passwords §8). The request reaches
  `provideCredentialWithoutUserInteraction`, which declines with `userInteractionRequired`;
  `prepareInterfaceToProvideCredential(for:)` of a passkey request naming a record signs that
  record with `passwords_passkey_assert`, after LocalAuthentication when verification is asked
  (§5), showing no list. A record that is gone shows the passkey sheet of the RP ID instead; a
  locked vault is shown as §6 says.

## 5. User verification

- When the request's user verification preference is `required` or `preferred`, the extension
  asks LocalAuthentication to verify the device's owner (`deviceOwnerAuthentication`: Touch ID,
  or the account password) before it sends the request, and sends `verified: true` only when that
  succeeded. A cancelled verification sends nothing and cancels the request as the user's; a
  refused one shows why. A passkey an entry names (§4.1) is asked of the owner first, so a locked
  vault or a gone record is told before any verification.
- With `discouraged`, it verifies nothing and sends no `verified`.
- The extension never sends a passphrase for verification: LocalAuthentication is this host's
  means (passwords §7.4).

## 6. A locked vault

The extension never unlocks ([README §5](../README.md#5-host-adapters)). The sheet of any of §3
and §4 on a domain whose vault is locked shows that domain as a row "`<domain>` is locked —
unlock it from the tsync menu", which does nothing when clicked. A passkey entry (§4.1) whose
vault is locked shows the same and signs nothing. The user unlocks from the menu and asks again;
the extension never caches the unlocked state.

## 7. Capabilities

| capability | interaction | realised by | declared |
|---|---|---|---|
| `fill` | `confirm` | §3, the credential sheet | declared |
| `fill` with codes | `confirm` | §3, §3.1, macOS 15 | declared |
| `passkey` | `confirm`, `authenticate` when verification is asked | §4, §5, macOS 14 | declared |
| `save` | — | not offered (§3) | — |
| `suggest` | — | not offered: AutoFill asks a credential provider for credentials to fill, never for a new password; Safari's own suggestion goes to the system's keychain | — |

## 8. Conformance

With the extension turned on in System Settings and the vault unlocked:

- Safari on `https://github.com/login`, a login for `https://github.com` in the vault: the sheet
  lists it by title and username; picking it fills the username and the password. No fill happens
  without a pick.
- A login linking a TOTP record: on macOS 15 the code field offers its current code.
- `https://webauthn.io`: registering creates a passkey record (`tsync passwords list` shows it),
  after Touch ID when the site asks for verification; signing in with it succeeds, the site
  reporting the authenticator's AAGUID and backup flags.
- With the vault locked, the sheet says so and points to the tsync menu; it asks for no
  passphrase. Unlocked from the menu, the next request lists as usual.
- Nothing the extension does leaves a password, code, passphrase or key in a log or a file of its
  container.
