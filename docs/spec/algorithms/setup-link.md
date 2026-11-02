# Setup links

A setup link hands a new machine what it needs to reach one or more domains, so that installing
tsync elsewhere takes one link or one QR code instead of a URL and a secret typed per domain. This
file owns the link, its payload and sealed manifest, the operations that create, revoke and join
one, and the page a listener serves for it. The share space, tokens, expiry and revocation it builds
on are [shares](security-model.md#6-share-capabilities).

---

## 1. Problem

Setting a machine up by hand means copying, per domain, a server URL and a 64-character secret,
then choosing a frontend and its options. That is fine for the person who runs the server and
error-prone for anyone else, and on a phone it means typing a secret.

A setup link carries those values from a machine that already reaches or serves the domains. The secrets in
it never reach a server or a store in clear, the link expires, and it can be revoked.

---

## 2. The link

```
https://tsync.example.org/join/<token>#<key>
```

- `https://tsync.example.org` is the `url` of the shared backend of the link's first domain (§4),
  as the creating machine has it configured, with no trailing `/`.
- `token` follows [security §6.1](security-model.md#61-token): 16 random bytes, 32 lowercase hex
  characters, generated, never caller-chosen.
- `key` is 32 bytes from the platform CSPRNG, base64url without padding (43 characters). It is in the
  fragment, which an HTTP client never sends: no server, store, proxy or log sees it.
- The link MUST use `https://` unless its host is a loopback address.

---

## 3. Payload

The plaintext the link seals, UTF-8 JSON:

```json
{"v":1,"from":"laptop",
 "domains":[{"name":"Family Photos",
             "backends":[{"type":"http-proxy","name":"server",
                          "url":"https://tsync.example.org","secret":"…"}]}]}
```

- `from`: the creating machine's client name, shown to the person joining.
- `domains`: one entry per shared domain, in the order the command named them, each with its name
  and the backends a joining machine configures, the first of which becomes its `main`.
- A backend carries `type`, `name` and the fields of its driver's option spec that describe the
  store rather than the machine reaching it. For `http-proxy` that is `url` and `secret`; `link` is
  left out, being a property of the joining machine's network.
- **Creators** include one `http-proxy` backend per domain (§5) and nothing else.
- **Readers**: `v` MUST be `1`; each name MUST be a valid domain name
  ([01 §2.2](../01-core.md#22-domain-names)); a domain whose backends this host cannot hold (an
  unknown type, or a type the host refuses, such as `local` on Windows) is skipped with that reason
  and the others are joined. Unknown fields are ignored.

---

## 4. Sealed manifest

The payload is stored as a share manifest of type `setup` at `tsync/shares/<token>`
([02 §2.14](../02-remote-model.md#214-share-manifest-json-and-share-artifacts)):

```json
{"v":1,"expires":1767225600,"domain":"Family Photos","type":"setup","sealed":"<base64url>",
 "about":[{"name":"Family Photos","extensions":[]},
          {"name":"Home","extensions":["totp","passwords"],
           "vault":{"color":"#16a34a","icon":"<base64 PNG>"}}]}
```

- `sealed` is base64url without padding of `nonce ‖ ciphertext ‖ tag`, with
  `ciphertext ‖ tag = XChaCha20-Poly1305-Seal(key, nonce, payload, ad = "tsync-setup/" token)` and
  a 24-byte random nonce. The AEAD is the vault's ([vault §4.2](../extensions/vault.md#42-wrapping-a-slot)).
  Binding the token in `ad` stops a sealed payload from being replayed under another token.
- `about` describes the domains in clear, so the page can name them without the key: one entry per
  payload domain, in the same order, with its `name`, the `extensions` in force for it
  ([05 §2.1](../05-ops-config.md#21-schema-and-validation) rule 5), and for a domain with a vault
  its appearance ([vault §8.1](../extensions/vault.md#81-appearance)): `color`, the one in force, and
  `icon` when there is one. It is for display only: what a join adds is the payload's.
- `domain` is the link's first domain: the share-space confinement of
  [security §6.4](security-model.md#64-the-share-space-on-a-listener) applies unchanged, so only a
  secret of that domain can write, read or delete the manifest.
- **Placement**: written to the first domain's shared backend directly, not through the composite,
  with the store's conditional create. A setup link is a credential held on one server; it is not
  replicated.
- **Validity**, in addition to the common rules: `sealed` MUST be non-empty base64url of at most
  `SETUP_MAX_SEALED` bytes once decoded, and at least nonce plus tag long. `about`, when present,
  MUST be a list of at most `SETUP_MAX_DOMAINS` entries, each with a valid domain name; a reader
  drops an entry's `vault` whose colour is not `#rrggbb` or whose icon is not a stored-form PNG
  (vault §8.1), and ignores unknown fields.
- **Lifetime**: `expires` defaults to `SETUP_DEFAULT_EXPIRY` and is always finite. Expiry and removal
  are those of every share ([gc §4.3](gc.md#43-shares)); revocation is §5.2.
- A setup manifest is never served under `/s/`: there it answers as an absent token (404).

---

## 5. Creating and revoking

### 5.1 `tsync config share DOMAIN... [--url URL] [--expires DUR]`

A command of class owner, per domain ([07 §5.3](../07-daemon-cli.md#53-commands)).

1. Each `DOMAIN` MUST be configured, else exit 2 naming it. A name given twice counts once; at most
   `SETUP_MAX_DOMAINS`.
2. Each domain's **shared backend** is, in this order:
   - for a domain this machine serves through its `http-proxy` frontend, the listener itself:
     `url` is `--url`, the address clients reach it at, which the listener cannot know behind TLS
     termination or a tunnel; `secret` is the domain's binding secret, inherited as
     [http-proxy §A3](../frontends/http-proxy.md#a3-configuration) says. Without `--url`: exit 2,
     `<domain> is served by this machine; give the address clients reach it at with --url`;
   - else its `http-proxy` member with role `main`, else its first `http-proxy` member with role
     `replica` in config order. A backfill or an archive is never shared: the joining machine makes
     it its main.

   A domain with neither is refused with exit 2: `<domain> is neither served by this machine nor
   reached through a tsync server`. `--url` given when no named domain is served here is refused
   with exit 2. `--url` follows the scheme rule of §2.
3. Each domain is checked through its shared backend as a join checks it (§6.2). A listener reached
   at a wrong `--url` fails here, before anything is written.
4. Describe each domain for `about` (§4): its extensions are those its shared backend's server
   states for it ([05 §2.1](../05-ops-config.md#21-schema-and-validation) rule 5), which a joining
   machine follows;
   for a domain with a vault, its appearance from its owner's `vault_status`, which a locked vault
   answers too.
5. Build the payload (§3), generate the token and key, seal (§4) and write the manifest through the
   first domain's shared backend, then fetch it as a joiner would (§6.1). A server that stores the
   manifest and does not serve it predates setup links: the manifest is deleted again, and the
   command says `<url> is too old to hold setup links`, exit 1. Any other failure is the driver's
   sentence, exit 1.
6. Print the link on stdout; on stderr, its expiry and
   `Anyone with this link can reach <domains> until then.`

`--expires DUR` takes the duration grammar of `tsync share`. The link and the key are never logged;
the token only at debug level ([security §10.3](security-model.md#103-masking)).

### 5.2 `tsync config share --revoke LINK`

Deletes the manifest the link names. The candidate domains are the configured ones whose shared
backend's `url` equals the link's base, and the domains this machine serves, signed with their
binding secret and sent to the link's base; each is asked in config order to delete
`tsync/shares/<token>`, which only the domain the manifest names can do. Exit 1 when no candidate
held the token, or when none exists.

Revoking stops new joins. A machine that already joined keeps its secret; rotating the server's
secret is what removes it.

---

## 6. Joining

### 6.1 Opening a link

1. Parse the link: scheme and host per §2, the path ending in `/join/<token>`, a fragment decoding
   to 32 bytes. Otherwise: `This is not a tsync setup link`.
2. `GET <base>/join/<token>?json=1` (§7), the fragment stripped. 404 → `This setup link was revoked,
   or never existed`; 410 → `This setup link expired on <date>`.
3. Open `sealed` with the key and `ad = "tsync-setup/" token`. A failure → `This setup link is
   damaged; copy it whole`. Then read the payload (§3).

### 6.2 Adding the domains

For each domain of the payload:

- **Already configured** with a backend whose `url` is the payload's: reported as already set up,
  left unchanged. With another `url`: refused for that domain, naming the name clash; the others
  proceed.
- **Checked** with the server, by the served check of
  [http-proxy §8.1](../backends/http-proxy.md#81-first-use-binding-and-conditional-create-support)
  signed with the payload's secret: a domain the server does not serve with it, a refused secret
  (or this machine's clock off), or a server that cannot be reached is not added, with the
  driver's sentence; the others proceed.
- **Built** as the wizard builds a new domain ([07 §5.9](../07-daemon-cli.md)), with no question
  asked: its defaults for `versioning` and `maxCache`; the payload's backends, the first with role
  `main` and the others `replica`; the frontends a new domain gets by default on this host, with
  their options' defaults (a mount point, a sync root); no `extensions` key, so the domain follows
  its main ([05 §2.1](../05-ops-config.md#21-schema-and-validation) rule 5).

A machine with no config gets the wizard's defaults for its globals. The new config is validated by
the parser and written as the wizard writes ([07 §5.9](../07-daemon-cli.md)), all domains in one
write: a join that adds nothing writes nothing.

### 6.3 Where a link is opened

- **`tsync config join LINK`**, class none. Prints each domain with its outcome and, when added,
  where it will appear; then tells the user to restart the service
  ([07 §2.7](../07-daemon-cli.md#27-runtime-paths)). Exit 0 when every domain was added or already
  set up, 1 otherwise.
- **The wizard**, on a new config file, asks first for a setup link (blank to set up by hand) and
  joins it before its other questions.
- **The Windows installer** offers an optional setup-link page once the programs are installed
  ([cloud-files §14.1](../frontends/cloud-files.md#141-package)). Its Next joins the link, then
  restarts the service so the new domains start ([07 §2.7](../07-daemon-cli.md#27-runtime-paths)); a
  failure is shown and the page stays, and it can be left blank to finish without one. An unattended
  install takes the link as `/LINK=`, and logs a failure to join without failing the install.
- **The Android app's Setup** ([android-app §10.7](../frontends/android-app.md#107-setup-and-settings))
  offers *Scan setup code*, with the scanner the vault's *Add* uses, and accepts a pasted setup link
  in its URL field. Opening the link fills the server and secret; a payload of several domains fills
  the choice of domains, each with its name and mark from `about`, one domain selects it. The app configures one domain, so the rest of the
  payload is not joined there. The sealed payload is opened by the core.

---

## 7. The page

`GET|HEAD /join/<token>` is unsigned and served by every listener, whether or not it serves shares
([backends/http-proxy §5.5](../backends/http-proxy.md#55-unsigned-endpoints)).

- **Dispatch**: each route is asked in config order whether `tsync/shares/<token>` loads from its
  share store, is a valid setup manifest (§4) and names its domain; the first that claims it
  answers. None → 404. An expired one → 410, whose body with `json` is `{"expires":<seconds>}`.
- **`?json=1`** → 200, the manifest as stored, `Cache-Control: no-store`.
- **Otherwise** a page that never decrypts and never holds a secret. It lists the domains of `about`,
  each by name with what it brings beside the files (*Two-factor codes* for `totp`, *Passwords* for
  `passwords`) and, for a domain with a vault, its mark (vault §8.1: the icon, else tsync's icon in
  the vault's colour); the manifest's `about` reaches the page per
  [security §13](security-model.md#13-html-and-browser-facing-output), the icon as a `data:` image.
  It shows, from its own address, a QR code of the whole link, fragment included, drawn in the page;
  the server's host; the expiry; and the steps per system (Windows: install, then paste the link on the installer's setup page;
  Android: install, then *Scan setup code*; macOS and Linux: `tsync config join '<link>'`, the link
  filled in from the page's address). Without a fragment the page says the link is incomplete and
  shows no QR code.
- Headers: those of [security §13](security-model.md#13-html-and-browser-facing-output), plus
  `Cache-Control: no-store` and
  `Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; frame-ancestors 'none'`.
  The page loads nothing from any other origin.

---

## 8. Security

- A setup link is worth the secrets it carries until it expires: anyone holding it can join, with
  full access to each domain the server does not serve read-only. The command says so (§5.1).
- Servers and stores hold only the sealed payload. Reading it takes the fragment, which is in the
  link alone.
- `about` is in clear: the server holding the link learns the names, extensions and appearances of
  every domain in it, including domains another server serves. It carries nothing that grants
  access, and a join never takes a name from it.
- The key and the link are secrets for [security §10.3](security-model.md#103-masking): never in a
  log or a report. The page's QR code is drawn on the viewer's screen and nowhere else.
- A config written by a join is a config like any other: 0600 from creation
  ([security §10.2](security-model.md#102-at-rest)).

---

## 9. Parameters

| Name | Value |
|---|---|
| `SETUP_DEFAULT_EXPIRY` | 7 days |
| `SETUP_MAX_SEALED` | 64 KiB |
| `SETUP_MAX_DOMAINS` | 16 |

---

## 10. Conformance

- **Round trip**: a link created for two domains, joined on a machine with no config, yields a
  config the parser accepts, with both domains, each with the shared backend as its `main`, the
  host's default frontends and no `extensions`. Binding: the domains, backends and roles; incidental:
  the order of keys.
- **Nothing in clear**: the stored manifest contains neither the secret nor the domains' URLs, and no
  request a creator or joiner sends contains the key. Binding: the bytes of the manifest and of each
  request line and header.
- **Integrity**: a manifest whose `sealed` is altered by one byte, or copied to another token, fails
  to open with the damaged-link sentence.
- **Confinement**: a manifest of type `setup` written with a secret of a domain it does not name is
  refused 401; `/s/<token>` answers 404 for it; a listing of the share space never shows it.
- **Lifetime**: an expired link answers 410 and is removed by expiry; a revoked link answers 404;
  revoking with a link of another server exits 1.
- **Refusals**: a domain with no `http-proxy` member, or only a backfill one, and not served here, is
  refused with exit 2 before anything is written; a server that predates setup links is named.
- **Served here**: on a machine serving a domain, `--url` with the listener's address yields a link
  whose payload carries that address and the binding's secret, and which joins; without `--url` the
  command exits 2; a `--url` that does not reach a listener serving the domain with that secret
  fails the check of §5.1 step 3 and writes nothing.
- **Joining**: an already configured domain with the same `url` is left byte-identical; one with
  another `url` is refused while the rest join; a payload naming a domain the server does not list
  adds nothing for it; on Windows a `local` backend in a payload is skipped with its reason.
- **Page**: the HTML carries the headers of §7 and no secret; it names every domain of `about` with
  its extensions and, for a vault, its colour or icon; with no fragment it shows no QR code.
- **Description**: `about` matches the payload's domains in order; a domain with a vault carries
  the colour `vault_status` reports, and its icon when it has one; one without carries no `vault`.

---

## 11. Rationale (do not undo)

- **The key in the fragment** keeps the one server that serves the link, and every replica of its
  share store, from ever holding a usable secret, while the link still expires and can be revoked
  there. A self-contained link would carry the same secrets with neither.
- **Only `http-proxy` backends** for now: a server can serve the domain read-only and its secret can
  be rotated, whereas a bucket credential grants whatever its IAM policy does. Bucket credentials
  can join the payload later as further backend types; readers already skip what they cannot hold.
- **Several uses until expiry**, not one: the same person sets up a computer and a phone from one
  link.
- **The page never decrypts**: it only needs to show itself as a QR code, so no cipher runs in the
  browser and no secret enters a page served from the listener's origin. What it names comes from
  `about`, which is in clear for that reason.
- **`about` is not authenticated by the key**: it only labels the page, and the payload alone
  decides what a join adds, so a description altered on the server can mislabel a page but cannot
  redirect a join.
