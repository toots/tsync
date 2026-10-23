# Passwords extension

This file is normative. It owns the `passwords` extension: its records (logins and passkeys), its
fold, site matching, password generation, the link to a one-time-password seed, the passkey
authenticator, import and export, the capabilities a host may offer and its commands. It
is an extension as the [README](README.md) defines one, and its records are vault envelopes
([vault §5](vault.md#5-record-envelope)).

---

## 1. Problem

Website and app passwords are kept by each browser, or by a hosted password manager that holds
the user's vault on its servers. With this extension they live in the user's own storage,
encrypted, and every machine of the user reads them.

Without a host capability (§8) or a browser extension (§9) the extension is a command-line
and app password store: the user looks a login up and copies its password. Filling forms in
apps and browsers is where most of the work of this extension lies.

### 1.1 Non-goals

- **Re-authentication on read** (deferred). In this version anyone acting as the user on a
  machine whose vault is unlocked reads every password, and `vault lock` is the control
  ([vault §6](vault.md#6-unlocking-and-the-keystore)). A later version asks the host to verify
  the user before `get` and `fill`, where it can.
- **Passkey attestation and portability.** A passkey made here attests nothing (§7.2) and is not
  exported; moving passkeys between managers (the FIDO Credential Exchange Format) is left to a
  later version.
- **Sharing.** A domain's vault has one passphrase; there are no per-record recipients.
- **Field-level merge.** Two concurrent edits are settled whole (§3), never combined.

## 2. Records

One record per login or passkey, at `/.tsync-ext/passwords/<record id>`, the id drawn from the
CSPRNG ([README §4.1](README.md#41-where-they-live)): a site may hold several of each, so no field
names a record. Its plaintext is one JSON object, UTF-8, whose `kind` says which: `login`, below,
`note` (§2.1) or `passkey` (§7.1). Every rule of this section but the table holds for all three.

```json
{"kind":"login","title":"GitHub","urls":["https://github.com"],"username":"me@example.com",
 "password":"correct horse battery staple","notes":"","totp":"","modified":1760500000}
```

| key | type | rule |
|---|---|---|
| `kind` | string | `login` |
| `title` | string | 1 to 256 bytes |
| `urls` | array of strings | 0 to 32 entries, each a site (§4.1) |
| `username` | string | may be empty |
| `password` | string | 1 to 1024 bytes |
| `notes` | string | may be empty; at most 64 KiB |
| `totp` | string | a TOTP record id (§6), or empty |
| `fields` | array of objects | optional, absent read as `[]`: 0 to 32 custom fields (§2.2) |
| `modified` | int | epoch seconds of the last change a user made |

- Every key is required but `fields`. A plaintext that breaks a rule is CORRUPT: reported by record id, never
  offered, never folded away.
- Readers ignore unknown members, and a rewrite keeps them.
- A writer appends spaces to the JSON until its length is a multiple of 256 bytes. An envelope's
  length is its plaintext's ([vault §5](vault.md#5-record-envelope)); the padding keeps the store
  from reading a password's length from it.
- A client that does not know a `kind` reports the record CORRUPT and leaves it as it is.
- A previous password is not kept in the record. The domain's versions keep every previous body
  ([05 §4.8](../05-ops-config.md#48-deleted-files-and-retention)), readable with K.

### 2.1 Notes

A note is a record with no site: something to keep secret that is not a login (a door code, a
recovery phrase, a licence key).

```json
{"kind":"note","title":"Wi-Fi","notes":"…","fields":[],"modified":1760500000}
```

`title` (1 to 256 bytes), `notes` (at most 64 KiB) and `modified` as a login's, and `fields`
(§2.2). A note matches no request (§4.2): it is never offered to fill, and is read with `list`
and `get`.

### 2.2 Custom fields

`fields` holds what a login or a note carries beyond its fixed keys: a PIN, a security answer,
an account number.

- Each is `{"name", "value", "secret"}`: `name` 1 to 64 bytes, `value` at most 4 KiB, `secret` a
  bool. Names need not be unique; the order is the user's.
- A `secret` field is masked wherever it is shown and is copied like a password; it is never
  filled into a form by this version.
- `get` answers the fields; `list` names neither fields nor their values.

## 3. Fold

The format merge `passwords-records` ([format-merge](../algorithms/format-merge.md)): the grouped
fold ([README §4.3](README.md#43-the-grouped-fold)), with the kind and, for a login, `password`,
for a passkey `credentialId` and `privateKey`, as key fields. Two machines that change one login's password concurrently leave two records, since only
one of the passwords works at the site and no clock can say which. Two concurrent edits that
agree on the password keep the newest whole record; the other one's labels are superseded.

A removal on one machine and an edit on another keep the edited record, as the merge keeps any
edited file ([conflict-resolution §8.1](../algorithms/conflict-resolution.md#81-where-every-byte-ends-up)).

## 4. Sites

### 4.1 Form

A site is one of:

- `https://<host>[:<port>]` or `http://<host>[:<port>]`, written in lower case without a path.
  Input may carry a path, query or fragment, which are dropped, and an IDN host, which is
  converted to its A-label form.
- `android://<package>`: an Android application, by package name.

Anything else is refused `invalid`.

### 4.2 Matching

A record matches a request when one of its `urls` matches it:

- A web request, for origin `<scheme>://<host>[:<port>]`, matches a web site whose port is equal
  (each scheme's default when absent), and whose host equals the request's host or shares its
  registrable domain: its longest public suffix and the label before it, by the bundled Public
  Suffix List (§7.3). `idmsa.apple.com` matches `iforgot.apple.com`; `alice.github.io` does not
  match `bob.github.io`, nor `alice.s3.amazonaws.com` `bob.s3.amazonaws.com` though
  `amazonaws.com` is no public suffix, and `co.uk` matches no host but itself. An IP address has no
  registrable domain. An `https` site does not match an `http` request.
- An app request matches the `android://` site of its package, and the `https` sites the app is
  verified for (§4.3).

A list for a site shows first the records with a site on the request's own host, as a browser
does, since one domain often holds several sign-in hosts with distinct accounts.

### 4.3 An app's websites

An app and its website usually share one login. An Android app is verified for an `https` site
when the site's Digital Asset Links statements (`https://<host>/.well-known/assetlinks.json`)
grant `delegate_permission/common.get_login_creds` to the app's package with the SHA-256 of a
certificate the app is signed with, as the platform reports it.

- **Which sites are checked:** only the `https` sites of the domain's logins whose host, its
  labels reversed, is a prefix of the package name's labels (`github.com` for
  `com.github.android`, `amazon.com` for `com.amazon.mShop.android.shopping`). The owner never
  fetches statements for every saved site.
- **Fetching:** the owner fetches each over `https`, following no redirect to another host, at
  most 256 KiB, within 5 s. A verdict, granted or not, is kept per host and package for
  24 hours; a fetch that fails keeps nothing and is tried again at the next
  request. A request answers from what is kept and fetches what is missing behind it, so a newly
  verified site is offered from the next request on.
- **The certificate** comes from the host's platform, never from the app: on Android the autofill
  service reads it from the package manager for the package the framework names.
- **A login the user links.** Picking, for an app, a login no rule matches (the host's own
  search) asks once whether to use it for that app; yes adds the app's `android://` site to the
  login's `urls`. The user's choice needs no statement.

## 5. Generating a password

`add` and `edit` take `generate` instead of `password`, either of:

- **Characters:** `length` 8 to 128, default 20, and `symbols`, bool, default true. Each character
  is drawn uniformly from the CSPRNG ([01 §2.10](../01-core.md#210-random-identifiers)) by
  rejection sampling, from `A`–`Z`, `a`–`z`, `0`–`9` and, with `symbols`, from `!#%+-.=?@_~`.
- **Words:** `words` 4 to 12, as [vault §2.3](vault.md#23-generated-passphrases) draws them: a
  password the user can read out and type.

A site with other rules is served by `edit` with a password the user types.
`passwords_generate` (`generate` as above) answers a password without saving it, for a CLI that
prints one (`tsync passwords generate`).

### 5.1 Suggesting a password

On a form that creates an account or changes a password, a host or the browser extension offers
*Use a strong password*. The pick fills a generated password, and the login is saved at once.

- **A new-password field** is one the page marks so (`autocomplete="new-password"`, Android's
  `AUTOFILL_HINT_NEW_PASSWORD`), or one whose name, id or label reads as a new or confirmed
  password. Among the password fields marked neither so nor as the current one
  (`current-password`, or a name reading as the current or old password), both of a form of two
  are new, and every one but the first of a form of three or more, a change form whose first
  asks for the current password. Its confirmation field, when the form has one, is filled with
  the same password; a current-password field never is, and a save sends the new password.
- **On the pick** the host asks `passwords_suggest` with the site and the username the form holds,
  possibly empty: the owner draws a password (characters, the defaults of §5), adds a login for
  the site with it, and answers the password and the record's id. The pick is the approval; no
  save sheet follows. Saving before the form is submitted means an account created with that
  password never has a password nobody kept.
- **On the form's submit** the host sends `passwords_save` with `suggested` naming that id, and
  no password: the owner sets the record's username to the one submitted, when the record is a
  login with that site among its sites, and adds nothing; any other record is refused
  `invalid`. A form abandoned leaves the login, which the user removes.
- The suggestion is offered only on a gesture, as a fill is, and only for a site (an app's
  `android://` site included); a locked vault refuses it `locked`.


## 6. One-time passwords

A login's one-time-password seed is a record of the [totp](totp.md) extension, which alone holds
seeds and computes codes ([totp §4](totp.md#4-code-generation)). The login names it by id in
`totp`.

- A login links a TOTP record of its own domain
  ([README §6.1](README.md#61-several-domains)). Linking needs this client to use `totp` on that
  domain; elsewhere a non-empty `totp`, or an `otpauth`
  request member, is refused `invalid`.
- `add` and `edit` take `otpauth`, an `otpauth://totp/` URI: it adds a TOTP record
  ([totp §5.1](totp.md#51-otpauth-uris)) and links it. They also take `totp`, an existing TOTP
  record id, or empty to unlink.
- A link is not a key field (§3): the seed it names survives a concurrent change of link as its
  own TOTP record.
- Removing a login leaves its TOTP record. Removing a TOTP record leaves the logins naming it
  with a **dangling link**: they have no code, and `list` reports them.
- One TOTP record may be linked from several logins.

## 7. Passkeys

A passkey is a WebAuthn credential: a key pair a site (the **relying party**, named by its **RP
ID**, a domain) registers, and later asks to sign a challenge. The owner is the authenticator. It
makes the key pair, keeps the private key in a record, and signs; hosts and browsers carry the
requests between the site and the owner and never receive the private key, as no client receives
a seed ([totp §5](totp.md#5-commands)).

### 7.1 Record

```json
{"kind":"passkey","rpId":"github.com","credentialId":"<b64url>","userHandle":"<b64url>",
 "userName":"me@example.com","userDisplayName":"Me","algorithm":-7,"privateKey":"<b64url>",
 "login":"","created":1760500000,"modified":1760500000}
```

| key | type | rule |
|---|---|---|
| `kind` | string | `passkey` |
| `rpId` | string | a domain in lower case, its A-label form, no port |
| `credentialId` | string | base64url without padding of 32 bytes drawn from the CSPRNG at creation |
| `userHandle` | string | base64url without padding of the relying party's user handle, 1 to 64 bytes |
| `userName` | string | the relying party's `user.name`, may be empty, at most 256 bytes |
| `userDisplayName` | string | its `user.displayName`, may be empty, at most 256 bytes |
| `algorithm` | int | `-7` (ES256: ECDSA on P-256 with SHA-256) |
| `privateKey` | string | base64url without padding of the 32-byte P-256 private scalar |
| `login` | string | the record id of a login of this site this passkey belongs with, or empty |
| `created`, `modified` | int | epoch seconds |

- A passkey's `login` is shown with the login and filled with it; it is not a key field, and a
  dangling one is reported as a login's `totp` is (§6).
- `get` never answers `privateKey`, and no reply of any request carries it.

### 7.2 The authenticator

tsync is one WebAuthn authenticator ([WebAuthn Level 3](https://www.w3.org/TR/webauthn-3/)) for
every domain:

- **AAGUID** `9fa7c19f-b0fa-444f-854b-34c0b4520b66`, the same on every machine and build.
- **Attestation** `none`: the attestation object is `{"fmt":"none","attStmt":{},"authData":…}`,
  CBOR in its deterministic encoding.
- **Authenticator data** (§6.1 of WebAuthn): the SHA-256 of the RP ID; the flags UP (always: a
  host only asks on the user's gesture), UV (§7.4), BE and BS (the credential is backed up and
  synced, as every vault record is), AT on creation; the signature counter `0`, which tells the
  relying party not to count, as synced passkeys do; on creation the attested credential data
  (AAGUID, credential id, and the public key as a COSE_Key, kty 2, alg −7, crv 1, x, y).
- **Algorithms.** A creation names the relying party's acceptable algorithms in order; the first
  of them this authenticator supports is used, and a creation naming none it supports is refused
  `invalid`. This version supports ES256 only, which every relying party accepts.
- **Discoverable.** Every passkey is discoverable (a resident key): an assertion without an
  allow-list offers every passkey of the RP ID.
- **Signature.** ES256 over `authenticatorData ‖ clientDataHash`, DER-encoded, as WebAuthn §6.3.3
  says. The client data and its hash are the host's: the host knows the origin and the
  challenge; the owner never sees the page.

### 7.3 Which passkeys answer a request

- **The RP ID belongs to the origin.** The request's `origin` must be `https://` (or
  `http://localhost`), written with or without one trailing `/` (a URL's serialisation, as
  Android's `CallingAppInfo.getOrigin` gives it), and its `rpId` the origin's host or a suffix of it at a label boundary
  that is not a public suffix and is within the origin's registrable domain (§4.2), by the
  [Public Suffix List](https://publicsuffix.org/) snapshot each release carries:
  `login.example.com` may name `example.com`, `evil.github.io` may not name `github.io`, nor
  `evil.s3.amazonaws.com` `amazonaws.com`. A browser checks this for its own authenticators; a browser extension that
  stands in for them is not trusted to, so the owner checks it on every request.
- **Related origins** (WebAuthn's related origin requests): an RP ID that is a domain name, not an IP
  address and not a public suffix may also vouch for other origins, as `accounts.meta.com` does for
  `https://www.facebook.com`. The owner fetches `https://<RP ID>/.well-known/webauthn` (a 200 of
  at most 256 KiB within 5 s, no redirect, asked with a `User-Agent`, without which Meta's
  server redirects), and accepts the origin when its `origins` list names
  it among the first five distinct registrable labels, as browsers count them. A document is
  kept 24 hours; a failed fetch keeps nothing. Anything else is refused `invalid`.
- **Matching.** A passkey answers a request whose RP ID equals its `rpId`. An assertion with an
  allow-list answers only the passkeys whose `credentialId` it lists. An empty allow-list is
  none, as WebAuthn's empty `allowCredentials` is: a discoverable request.
- **Exclusion.** A creation whose exclude-list names a passkey this vault holds for the RP ID is
  refused `exists` (WebAuthn's InvalidStateError): the site already knows this authenticator.

### 7.4 User verification

The UV flag says the user was verified for this request, not merely present. It is set only when
the request carries one of:

- `passphrase`, checked against the keyring as `totp export` checks it
  ([totp §5](totp.md#5-commands)): a browser extension, which cannot verify the user itself, asks
  for the passphrase when the relying party requires verification;
- `verified: true` from a host adapter whose spec says its platform verified the user for this
  request (a biometric or device-code prompt of the system's credential sheet), or from the
  browser bridge after its own platform verification (§9.2, `verify`).

Otherwise UV is clear, and a relying party that requires verification refuses the passkey. Any
process of the user can reach the owner and say `verified` ([security-model §7](../algorithms/security-model.md)):
the flag is as trustworthy as the user's account on this machine, which is what a platform
authenticator's flag also rests on.

### 7.5 Requests

| action | request | answer |
|---|---|---|
| `passwords_passkey_create` | `origin`, `rpId`, `userHandle`, `userName`, `userDisplayName`, `algorithms`, `exclude?`, `clientDataHash`, `passphrase?`, `verified?`, `login?` | the new record's id, `credentialId`, `attestationObject`, `authenticatorData`, the public key as SPKI DER (`publicKey`) and `algorithm` |
| `passwords_passkey_match` | `origin`, `rpId`, `allow?` | the passkeys answering (§7.3): domain, id, `credentialId`, `userName`, `userDisplayName`, and the linked login's title |
| `passwords_passkey_assert` | `origin`, `rpId`, `domain`, `id`, `clientDataHash`, `passphrase?`, `verified?` | `credentialId`, `authenticatorData`, `signature`, `userHandle` |

Binary members are base64url without padding. `passwords_passkey_assert` of a passkey that does
not answer the request (§7.3) is refused `invalid`. Creation picks the domain as `add` does
(README §6.1). A host asks the user before a creation, and lets them pick the passkey of an
assertion, as for `fill` (§8, §9.3).

## 8. Capabilities

Every capability is optional ([README §5](README.md#5-host-adapters)).

| capability | means | without it |
|---|---|---|
| `fill` | the host's autofill asks for the logins matching a site or app (§4.2) and fills the one the user picks | the user finds the login with `list` and copies its password from `get` |
| `fill` with codes | the host's autofill also asks for a site's one-time code, and fills the current code of the login the user picks (§6) | the user reads the code from `get` |
| `save` | the host's autofill hands over a username and password the user just typed, and the user approves saving them | the user runs `add` |
| `suggest` | the host's autofill offers a generated password on a new-password field, fills it and saves the login (§5.1) | the user runs `add --generate` and pastes the password |
| `passkey` | the host's credential API asks to create a passkey or to sign with one, and the user approves the creation or picks the passkey (§7) | none: a passkey is used only through a host or a browser extension |

- Each is `confirm` or `authenticate` on every host: the user picks the login, or approves the
  save. The extension never calls either by itself.
- A `fill` request on a locked vault answers that it is locked, and the host says so and where to
  unlock ([README §5](README.md#5-host-adapters)); it never fills from a cache.
- A `save` whose site, username and password equal those of a record adds nothing. A `save`
  whose site and username equal one record's, with another password, asks whether to update it;
  otherwise it adds a record. The site is compared exactly, not by §4.2's suffix rule: a page on
  `login.example.com` never updates a login saved for `example.com`.

| action | request | answer |
|---|---|---|
| `passwords_fill` | `site`, `id`, `pull?` | the login's username, password, `exact` (whether it is a login of `site` itself rather than by suffix), and current code with seconds left when one is linked; refused `invalid` when the login does not match `site` (§4.2) |
| `passwords_save` | `site`, `username`, `password` (absent with `suggested`), `update?`, `suggested?` | as a `save` above: `saved`, with the record's `id` when one was added or updated, or `update` naming the record to update; a request carrying `update` with that id updates it; one carrying `suggested` sets that record's username (§5.1) |
| `passwords_suggest` | `site`, `username` | §5.1: the generated password and the new record's `id` |
| `passwords_generate` | `generate` | a password (§5), saved nowhere |

A host's `fill` and `save` are these requests, the browser bridge's (§9.2) as every platform
host's, so the rules above hold in one place. A read (`passwords_list`, `passwords_fill`,
`passwords_passkey_match`, `passwords_passkey_assert`) takes `pull` as a listing does
([README §4.1](README.md#41-where-they-live)).

Each host has `extensions/passwords/<host>.md` ([README §5](README.md#5-host-adapters)), which
lists what it declares: [macOS](passwords/macos.md) (`fill`, codes, `passkey`),
[Android](passwords/android.md) (`fill`, codes, `save`, `suggest`, `passkey`). Linux has no system autofill: browsers are served by
§9.

## 9. Browser extensions

A browser extension fills and saves logins in that browser, on any host the browser runs on. It
is a client of the owner, not a host adapter: it reaches the owner through a **bridge**, and
declares nothing. The extension itself is [browser](passwords/browser.md); this section owns the
bridge it talks to.

### 9.1 The bridge

- The bridge is `tsync passwords browser-host`, started by the browser through native messaging:
  each message, both ways, is a 32-bit length in the host's byte order followed by that many
  bytes of UTF-8 JSON. A message the bridge sends is at most 1 MiB.
- The browser starts it only for the extensions its native-messaging manifest names (Chromium
  `allowed_origins`, Firefox `allowed_extensions`). `tsync passwords browser install` writes that
  manifest for each browser it finds on the host, naming tsync's published extension ids and any
  `--extension-id` given.
- The bridge is a one-shot client of the owner of access class **owner**
  ([07 §2.5](../07-daemon-cli.md#25-one-shot-commands)). It forwards only the requests of §8.2;
  anything else is refused `invalid`. It holds no K and keeps nothing.

### 9.2 Requests

The bridge serves every domain that uses `passwords` on this client, merged as
[README §6.1](README.md#61-several-domains) says. Every request but `status` carries `origin`:
the origin (§4.2) of the frame that holds the form, as the browser reports it to the extension.
`fill` carries the `domain` its `match` row named; `save` carries a `domain` only to pick one.

| request | carries | answer |
|---|---|---|
| `status` | — | per domain: locked or unlocked, whether it uses `totp`, and its `appearance` (`color`, and `icon` in base64 when it has one; vault §8.1); `verifier`, the platform's verifier `verify` uses, or null |
| `match` | `origin` | the logins matching `origin` (§4.2) in every domain: domain, id, title, username, whether a code is linked, and `exact`, whether one of its sites is `origin` itself rather than a suffix match; no password |
| `fill` | `origin`, `domain`, `id` | `passwords_fill` (§8), with `origin` as the site |
| `save` | `origin`, `username`, `password` (absent with `suggested`), `domain?`, `update?`, `suggested?` | `passwords_save` (§8), with `origin` as the site |
| `suggest` | `origin`, `username`, `domain?` | `passwords_suggest` (§8), with `origin` as the site |
| `passkey_match`, `passkey_create`, `passkey_assert` | as §7.5, `origin` the frame's | as §7.5; `passkey_match` also names the locked domains, as `match` does |
| `verify` | `origin` | verifies the user by the platform's own means before a passkey request ([browser §5](passwords/browser.md#5-passkeys)): on macOS LocalAuthentication, answering `verified`; elsewhere refused `invalid` (the extension then asks the passphrase) |

- A `fill` whose login does not match `origin` is refused `invalid`. A page never receives a
  login of another site, whatever the extension asks.
- No request lists every login, returns a login by id alone, or carries a seed or notes. The
  passphrase travels only in `passkey_create` and `passkey_assert`, to verify the user where the
  platform has no verifier (§7.4); unlocking is done in the app or the CLI.
- A passkey request carries `verified: true` only after the bridge's own `verify` succeeded in the
  same session: the bridge sets it, not the extension, and drops a `verified` the extension sends.
- A locked vault is named in a `match` reply; a `fill` or `save` on it is refused `locked`.

### 9.3 What the extension does

- It fills only on a gesture of the user in the page or the extension's own UI, never when a page
  loads, so a page cannot collect logins by drawing forms the user never touches.
- It sends the origin of the frame holding the form, not the top-level page's. A login is filled
  into a cross-origin frame only when it matches that frame's origin.
- It asks the user before every `save`, but for the username a suggested password's submit sets
  (§5.1): the pick of the suggestion was the approval.
- It never stores a password, a code or a match result beyond the fill that asked for it.

## 10. Commands

Every verb is of access class **owner**
([07 §2.5](../07-daemon-cli.md#25-one-shot-commands)) and needs K.

| verb / action | request | does |
|---|---|---|
| `add` / `passwords_add` | `kind?` (`login`, else `note`), `title`, `urls?`, `username?`, `password` or `generate`, `notes?`, `fields?`, `otpauth` or `totp`? | adds a record; replies with its id. The CLI asks for the password without echo unless `--generate`; `--note` adds a note (§2.1), with no site or password; `--field NAME=VALUE` adds a field, and `--secret-field NAME` one whose value it asks without echo |
| `list` / `passwords_list` | `filter?`, `site?`, `use?` | every login whose title, username or urls contain `filter` (case-insensitive), or that matches `site` (§4.2): id, title, username, urls, whether a code is linked or its link dangles, and the ids of its passkeys; then every passkey whose RP ID or user name contains `filter`, or whose RP ID is `site`'s host or a suffix of it: id, RP ID, user name, `credentialId` and `userHandle` (base64url, public as a relying party holds them), and its login; ordered by title (a passkey's: its RP ID), then username, then id; with `use: false`, a host's refresh in the background, which is no use of the vault for its idle limit ([vault §6.2](vault.md#62-auto-lock)) |
| `get` / `passwords_get` | `id` | the record's password, notes and fields, and the linked TOTP record's current code and seconds left; a note's title, notes and fields. The CLI's `--field NAME` prints that field's value alone. The CLI prints the password alone, newline-terminated, for a pipe to a clipboard tool |
| `edit` / `passwords_edit` | `id`, any of `title`, `urls`, `username`, `password` or `generate`, `notes`, `fields`, `otpauth` or `totp` | replaces those fields and sets `modified`; `fields` replaces the whole list |
| `generate` / `passwords_generate` | `generate` | prints a password (§5) and saves nothing; `--words N` for words |
| `remove` / `passwords_remove` | `id` | removes the record, a login or a passkey; removing a login leaves its passkeys, whose link then dangles |
| `import` (CLI only) | a CSV file | §10.1 |
| `export` (CLI only) | the passphrase, asked as `tsync totp export` asks it | prints every record as CSV with the columns `name,url,username,password,note,otpauth`, the last empty for a login with no code, one row per login, its first site in `url`; passkeys are not exported (§1.1), and their count is said on stderr |

- `get` is the only action that replies with a password, and no action replies with a passkey's
  private key: `get` of a passkey answers its RP ID, user name and display name, credential id and
  login. No action but `totp_export` replies
  with a seed ([totp §5](totp.md#5-commands)): the CLI's `export` fills the `otpauth` column from
  it, so the passphrase guards both. A host that shows one SHOULD keep it
  out of screenshots and task-switcher thumbnails.
- An `id` names a record of this extension or is refused `invalid`; a well-formed id with no
  record is `not_found`.

### 10.1 Import

`import` reads a CSV file (RFC 4180, UTF-8, a header row) as exported by a browser or another
password manager, and adds one record per row.

- Columns are found by header name, case-insensitive; other columns are ignored:

  | field | header names |
  |---|---|
  | `title` | `name`, `title` |
  | `urls` | `url`, `login_uri`, `website` |
  | `username` | `username`, `login_username` |
  | `password` | `password`, `login_password` |
  | `notes` | `note`, `notes` |
  | one-time-password seed | `otpauth`, `login_totp` |

- A file with no password column is refused before anything is added. A row with an empty
  password, or one that breaks §2 or §4.1, is skipped and reported by line number; the rest go on.
  A row without a title takes its first site's host as title.
- A one-time-password seed that is an `otpauth://totp/` URI is added as a TOTP record and linked
  to the row's login (§6) when the domain lists `totp`, and counted as dropped otherwise.
- Import adds; it never matches a row against an existing record. Importing a file twice gives
  each login twice.
- The reply counts the records added, the rows skipped and the seeds added and dropped.

The file is plaintext. tsync neither copies nor removes it.

## 11. Conformance

- A note is listed by its title, answers its notes and fields to `get`, and is offered for no site.
  A login with a `secret` field answers it to `get` and names no field in `list`; a client that
  does not know `kind: "note"` reports it CORRUPT and leaves it unchanged.
- `--words 6` answers six words of the list joined by `-`; `--length 8` without symbols answers
  eight letters and digits.
- A suggestion on a sign-up form fills the password and its confirmation, and `list` shows the new
  login before the form is submitted; the submit sets its username and adds no second login.
- An app `com.example.app` signed with certificate C, and a login for `https://example.com` whose
  `assetlinks.json` grants C: the first request offers only the app's own logins and fetches the
  statement; the next offers the site's login too. A statement granting another certificate, a
  redirect to another host, or a login for `https://other.com` is never offered. Linking a login
  to the app by hand adds `android://com.example.app` to its sites.

- The store holds no title, username, site or password in plaintext after `add`. Two records
  whose plaintexts differ in length by less than 256 bytes before padding may have envelopes of
  one length.
- Two machines change one record's password concurrently: after both fold, two records remain,
  one per password, and no copy. Two machines change its title concurrently: one record remains,
  with the newer title.
- A record for `https://example.com` matches `https://login.example.com`, not
  `http://example.com`, `https://badexample.com` or `https://example.com:8443`. A record for
  `https://router` matches only `https://router`. A record for `android://com.example.app`
  matches that app only.
- `generate` with length 8 and no symbols yields 8 characters of `A`–`Z`, `a`–`z`, `0`–`9`;
  length 7 or 129 is refused.
- `export` then `import` of the result reproduces every record's title, first site, username,
  password, notes and linked seed.
- An import of a Bitwarden CSV export with a `login_totp` URI adds a password record and, on a
  domain listing `totp`, a TOTP record it links to. A row with an empty password is skipped and named by line.
- `list` replies hold no password. With the vault locked, every verb is refused `locked` and
  changes nothing.
- `add` with an `otpauth` URI adds one TOTP record and one login linked to it; `get` on the login
  gives the code `totp list` gives for that record. After `totp remove` of it, the login's link
  is reported dangling and `get` gives no code. Removing the login leaves the TOTP record.
- A non-empty `totp` or an `otpauth` on a domain that does not list `totp` is refused and writes
  nothing.
- Through the bridge: `match` for `https://login.example.com` lists a login for
  `https://example.com` and no password; `fill` of a login for `https://other.com` with that
  origin is refused `invalid`; any request other than `status`, `match`, `fill` or `save` is
  refused `invalid`; a `match` names a locked domain and still lists the other domains' logins;
  one login present in two domains is matched twice, each row naming its domain. A message from an extension
  the manifest does not name never reaches the bridge.
- Passkeys: a creation for `https://login.example.com` with RP ID `example.com` makes a record
  whose public key verifies the assertions it signs; the attestation object is CBOR with `fmt`
  `none`, its authenticator data carries the AAGUID of §7.2, flags UP, BE and BS, counter 0, and
  a COSE ES256 key; an assertion's signature verifies over `authenticatorData ‖ clientDataHash`
  with that key.
- RP ID `github.io` from `https://evil.github.io`, RP ID `example.com` from `http://example.com`,
  and RP ID `other.com` from `https://example.com` are refused `invalid`.
- UV is set when the request carries the correct passphrase or `verified: true`, clear otherwise;
  a wrong passphrase is refused `denied`.
- A creation whose exclude-list names a held passkey is refused `exists`; an assertion with an
  allow-list answers only those credentials; without one, every passkey of the RP ID.
- No reply holds a private key; the store holds no RP ID, user name or key in plaintext.
- Two machines' passkeys for one RP ID stay two records; a rename of one passkey's user name on
  two machines leaves one record.

## 12. Later

- **More hosts and clients**: an iOS host; a git credential helper (`git-credential-tsync`) and an
  SSH agent holding keys in the vault.
- **Imports** of Bitwarden's JSON, KeePass `.kdbx` and 1Password's `.1pux`, which carry seeds and
  notes a CSV drops.
- **Password health**: reused and short passwords listed locally, and an opt-in breach check
  (Have I Been Pwned's range API).
- **History**: earlier passwords of a login, read from the domain's versions.
- **Filling custom fields** (§2.2), and records for cards and identities.
- **Re-authentication on read** (§1.1).
