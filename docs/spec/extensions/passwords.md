# Passwords extension

This file is normative. It owns the `passwords` extension: its record, its fold, site matching,
password generation, the link to a one-time-password seed, import and export, the capabilities a host may offer and its commands. It
is an extension as the [README](README.md) defines one, and its records are vault envelopes
([vault §5](vault.md#5-record-envelope)).

---

## 1. Problem

Website and app passwords are kept by each browser, or by a hosted password manager that holds
the user's vault on its servers. With this extension they live in the user's own storage,
encrypted, and every machine of the user reads them.

Without a host capability (§7) or a browser extension (§8) the extension is a command-line
and app password store: the user looks a login up and copies its password. Filling forms in
apps and browsers is where most of the work of this extension lies.

### 1.1 Non-goals

- **Re-authentication on read** (deferred). In this version anyone acting as the user on a
  machine whose vault is unlocked reads every password, and `vault lock` is the control
  ([vault §6](vault.md#6-unlocking-and-the-keystore)). A later version asks the host to verify
  the user before `get` and `fill`, where it can.
- **Passkeys.** A passkey is a private key the platform's credential APIs create and use, not a
  string the user types; it is not a record of this version.
- **Sharing.** A domain's vault has one passphrase; there are no per-record recipients.
- **Field-level merge.** Two concurrent edits are settled whole (§3), never combined.

## 2. Record

One record per login, at `/.tsync-ext/passwords/<record id>`, the id drawn from the CSPRNG
([README §4.1](README.md#41-where-they-live)): a site may hold several logins, so no field names
a record. Its plaintext is one JSON object, UTF-8:

```json
{"title":"GitHub","urls":["https://github.com"],"username":"me@example.com",
 "password":"correct horse battery staple","notes":"","totp":"","modified":1760500000}
```

| key | type | rule |
|---|---|---|
| `title` | string | 1 to 256 bytes |
| `urls` | array of strings | 0 to 32 entries, each a site (§4.1) |
| `username` | string | may be empty |
| `password` | string | 1 to 1024 bytes |
| `notes` | string | may be empty; at most 64 KiB |
| `totp` | string | a TOTP record id (§6), or empty |
| `modified` | int | epoch seconds of the last change a user made |

- Every key is required. A plaintext that breaks a rule is CORRUPT: reported by record id, never
  offered, never folded away.
- Readers ignore unknown members, and a rewrite keeps them.
- A writer appends spaces to the JSON until its length is a multiple of 256 bytes. An envelope's
  length is its plaintext's ([vault §5](vault.md#5-record-envelope)); the padding keeps the store
  from reading a password's length from it.
- A previous password is not kept in the record. The domain's versions keep every previous body
  ([05 §4.8](../05-ops-config.md#48-deleted-files-and-retention)), readable with K.

## 3. Fold

The grouped fold ([README §4.3](README.md#43-the-grouped-fold)), with `password` as the only key
field. Two machines that change one login's password concurrently leave two records, since only
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
  (each scheme's default when absent), and whose host equals the request's host or, when the
  site's host contains a `.`, is a suffix of it at a label boundary (`example.com` matches
  `login.example.com`, not `badexample.com`). An `https` site does not match an `http` request.
- An app request matches the `android://` site of its package, and nothing else. An app's
  associated websites are not followed.

The suffix rule has no public-suffix list: a site written as `co.uk` matches every host under
it. The user wrote it.

## 5. Generating a password

`add` and `edit` take `generate` instead of `password`:

- `length`: 8 to 128, default 20.
- `symbols`: bool, default true.

Each character is drawn uniformly from the CSPRNG ([01 §2.10](../01-core.md#210-random-identifiers))
by rejection sampling, from `A`–`Z`, `a`–`z`, `0`–`9` and, with `symbols`, from
`!#%+-.=?@_~`. A site with other rules is served by `edit` with a password the user types.

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

## 7. Capabilities

Every capability is optional ([README §5](README.md#5-host-adapters)).

| capability | means | without it |
|---|---|---|
| `fill` | the host's autofill asks for the logins matching a site or app (§4.2) and fills the one the user picks | the user finds the login with `list` and copies its password from `get` |
| `fill` with codes | the host's autofill also asks for a site's one-time code, and fills the current code of the login the user picks (§6) | the user reads the code from `get` |
| `save` | the host's autofill hands over a username and password the user just typed, and the user approves saving them | the user runs `add` |

- Each is `confirm` or `authenticate` on every host: the user picks the login, or approves the
  save. The extension never calls either by itself.
- A `fill` request on a locked vault answers that it is locked, and the host's app offers to
  unlock; it never fills from a cache.
- A `save` whose site, username and password equal those of a matching record adds nothing. A
  `save` whose site and username match one record with another password asks whether to update
  it; otherwise it adds a record.

No host declares a capability yet. Each gets `extensions/passwords/<host>.md` once one is seen
([README §5](README.md#5-host-adapters)). Planned, not declared:

| host | `fill` | `save` |
|---|---|---|
| macOS | an AutoFill credential provider extension (`ASCredentialProviderViewController`), which also serves one-time codes | not offered to credential providers |
| Android | an `AutofillService`, for apps and for browsers that use it | the same `AutofillService` |
| Linux | none: no system autofill; browsers are served by §8 | none |

## 8. Browser extensions

A browser extension fills and saves logins in that browser, on any host the browser runs on. It
is a client of the owner, not a host adapter: it reaches the owner through a **bridge**, and
declares nothing.

### 8.1 The bridge

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

### 8.2 Requests

The bridge serves every domain that uses `passwords` on this client, merged as
[README §6.1](README.md#61-several-domains) says. Every request but `status` carries `origin`:
the origin (§4.2) of the frame that holds the form, as the browser reports it to the extension.
`fill` carries the `domain` its `match` row named; `save` carries a `domain` only to pick one.

| request | carries | answer |
|---|---|---|
| `status` | — | per domain: locked or unlocked, and whether it uses `totp` |
| `match` | `origin` | the logins matching `origin` (§4.2) in every domain: domain, id, title, username, and whether a code is linked; no password |
| `fill` | `origin`, `domain`, `id` | the login's username, password, and current code with seconds left when one is linked |
| `save` | `origin`, `username`, `password`, `domain?` | as a `save` (§7), with `origin` as the site |

- A `fill` whose login does not match `origin` is refused `invalid`. A page never receives a
  login of another site, whatever the extension asks.
- No request lists every login, returns a login by id alone, or carries a seed, notes or the
  passphrase. Unlocking is done in the app or the CLI.
- A locked vault is named in a `match` reply; a `fill` or `save` on it is refused `locked`.

### 8.3 What the extension does

- It fills only on a gesture of the user in the page or the extension's own UI, never when a page
  loads, so a page cannot collect logins by drawing forms the user never touches.
- It sends the origin of the frame holding the form, not the top-level page's. A login is filled
  into a cross-origin frame only when it matches that frame's origin.
- It asks the user before every `save`.
- It never stores a password, a code or a match result beyond the fill that asked for it.

## 9. Commands

Every verb is of access class **owner**
([07 §2.5](../07-daemon-cli.md#25-one-shot-commands)) and needs K.

| verb / action | request | does |
|---|---|---|
| `add` / `passwords_add` | `title`, `urls?`, `username?`, `password` or `generate`, `notes?`, `otpauth` or `totp`? | adds a record; replies with its id. The CLI asks for the password without echo unless `--generate` |
| `list` / `passwords_list` | `filter?`, `site?` | every record whose title, username or urls contain `filter` (case-insensitive), or that matches `site` (§4.2): id, title, username, urls, and whether a code is linked or its link dangles; ordered by title, then username, then id |
| `get` / `passwords_get` | `id` | the record's password and notes, and the linked TOTP record's current code and seconds left. The CLI prints the password alone, newline-terminated, for a pipe to a clipboard tool |
| `edit` / `passwords_edit` | `id`, any of `title`, `urls`, `username`, `password` or `generate`, `notes`, `otpauth` or `totp` | replaces those fields and sets `modified` |
| `remove` / `passwords_remove` | `id` | removes the record |
| `import` (CLI only) | a CSV file | §9.1 |
| `export` (CLI only) | — | prints every record as CSV with the columns `name,url,username,password,note,otpauth`, the last empty for a login with no code, one row per record, its first site in `url` |

- `get` is the only action that replies with a password. No action replies with a seed
  ([totp §5](totp.md#5-commands)). A host that shows one SHOULD keep it
  out of screenshots and task-switcher thumbnails.
- An `id` names a record of this extension or is refused `invalid`; a well-formed id with no
  record is `not_found`.

### 9.1 Import

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

## 10. Conformance

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
