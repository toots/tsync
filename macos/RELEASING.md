# Building and releasing the macOS app

The macOS deliverable is a single notarized `tsync.pkg` holding one
self-contained `TsyncApp.app`: the Swift app, the File Provider extension, the
OCaml daemon and every non-system library it needs all live inside the bundle.

It is an installer package rather than a disk image because the daemon doubles as
the `tsync` CLI, and a sandboxed app cannot put anything outside its own bundle.
`scripts/postinstall` runs as root, so it can symlink the CLI into
`/usr/local/bin` — which is in the default `PATH` from `/etc/paths` but does not
exist on a clean machine. Installing to `/Applications` directly also avoids the
Gatekeeper app translocation that bites users who run an app straight out of a
mounted image.

```
TsyncApp.app/Contents
├── MacOS/TsyncApp                        the app (a background login item)
├── MacOS/tsync                           the OCaml daemon + CLI
├── libs/                                 Homebrew dylibs the daemon links
├── Resources/install-agent.sh            installs the daemon's LaunchAgent
└── PlugIns/TsyncFileProvider.appex       the File Provider extension
```

The app registers itself as a login item through `SMAppService`
(`TsyncApp/LoginItem.swift`). The daemon is a plain LaunchAgent written to
`~/Library/LaunchAgents` by `install-agent.sh`, which both `scripts/postinstall`
and `deploy.sh` call.

> A bundled `SMAppService.agent` in `Contents/Library/LaunchAgents` is the
> modern equivalent and would avoid the second plist, but it does not work here:
> with the agent correctly placed, sealed into the signature and signed with the
> app's Team ID, `SMAppService.agent(plistName:)` reports `.notFound` and
> `register()` fails with `Operation not permitted`, so the daemon never starts.
> `SMAppService.mainApp` works, which is why the login item still uses it.

Uninstalling is `tsync fileprovider purge`: it unregisters the domains and the
login item and removes the bundle, agent plist, cache and symlink, keeping
`config.json`.

## Identifiers

| | |
|---|---|
| App | `org.feverdreamtv.tsync` |
| Extension | `org.feverdreamtv.tsync.fileprovider` |
| App Group | `group.org.feverdreamtv.tsync` |
| Daemon agent label | `org.feverdreamtv.tsync.daemon` |
| Team ID | `PSE2VP6582` |

All five have to agree across `project.yml`, both `.entitlements` files,
`Shared/Config.swift`, `install-agent.sh` and `lib/platform/runtime/macos_runtime.ml`.
Changing the App Group changes the container path, which orphans any existing
local cache and config.

---

## Building locally

Needs [opam](https://opam.ocaml.org/) with OCaml ≥ 5.5, Xcode, and:

```bash
brew install xcodegen dylibbundler xxhash
```

```bash
cd macos
make generate    # regenerate tsync.xcodeproj; only needed after editing project.yml
make build       # complete TsyncApp.app, path printed on stdout
make deploy      # the same build, installed into /Applications and started
```

`build.sh` is the single entry point everything else calls. It:

1. builds the daemon with `dune build bin/tsync.exe`;
2. builds the app and extension with `xcodebuild`, with `CODE_SIGNING_ALLOWED=NO`
   — signing happens at the end, because injecting files afterwards would
   invalidate any earlier signature;
3. copies the daemon to `Contents/MacOS/tsync` and `install-agent.sh` to
   `Contents/Resources/`;
4. runs `dylibbundler` to copy the daemon's Homebrew dependencies (openssl, gmp,
   pcre2, libev, xxhash) into `Contents/libs` and rewrite their install names to
   `@executable_path/../libs`;
5. signs inside-out: dylibs, then the daemon, then the extension, then the app.

It takes a few environment variables:

| | |
|---|---|
| `CONFIGURATION` | `Release` (default) or `Debug` |
| `SIGN_IDENTITY` | codesign identity, default `-` (ad-hoc) |
| `PROFILE_APP` / `PROFILE_APPEX` | provisioning profiles to embed |
| `BUNDLE_VERSION` / `BUNDLE_SHORT_VERSION` | override `CFBundleVersion` / `CFBundleShortVersionString` |
| `JOBS` | parallel `xcodebuild` jobs, default 12 |

A plain `make build` signs ad-hoc, which is enough to run the app on the machine
that built it. Ad-hoc signatures carry no Team ID, so the hardened runtime's
library validation would reject the bundled dylibs — `build.sh` therefore only
turns on the hardened runtime and a secure timestamp once a real `SIGN_IDENTITY`
is given. That difference is why a release build must be installed from a real
pkg at least once, not only via `make deploy`.

### Watching it run

```bash
log stream --predicate 'subsystem == "org.feverdreamtv.tsync"' --level debug
log stream --process tsync                                    # daemon stdout/stderr
launchctl print "gui/$UID/org.feverdreamtv.tsync.daemon"      # agent state
launchctl kickstart -k "gui/$UID/org.feverdreamtv.tsync.daemon"   # restart it
```

The extension has to be approved once in **System Settings → General → Login Items
& Extensions → File Provider Extensions**.

---

## Signing and notarizing

`make package` runs `build.sh` with a real identity, builds the installer with
`pkgbuild`, then notarizes and staples it to `macos/dist/tsync.pkg`. It needs
**two** Developer ID certificates, two provisioning profiles and an App Store
Connect key — the sections below are how to obtain each of them. Everything here
is also what the CI secrets are made from, so do this once locally first: it is
far quicker to debug than a push to main.

### 1. Developer ID certificates

Two separate certificates, from the same account. **Developer ID Application**
signs the app bundle and everything nested in it; **Developer ID Installer**
signs the `.pkg`. One cannot substitute for the other, and an unsigned pkg cannot
be notarized. Neither is "Apple Development" or "Apple Distribution" — those are
for Xcode-local builds and the App Store.

1. <https://developer.apple.com/account/resources/certificates/list> → **+**
2. **Developer ID Application**, then **G2 Sub-CA (Xcode 11 or later)**.
3. It asks for a Certificate Signing Request. Generate one in Keychain Access →
   **Certificate Assistant → Request a Certificate From a Certificate Authority**,
   fill in your email and name, choose **Saved to disk**.
4. Upload the CSR, download `developerID_application.cer`, double-click it to add
   it to your login keychain, where it pairs with the private key the CSR made.
5. Repeat from step 1, this time choosing **Developer ID Installer**. You can
   reuse the same CSR file.

> If the team already has these, export them from the Mac that created them
> instead of issuing more. Developer ID certificates are limited in number and
> revoking one invalidates already-shipped builds.

Confirm both are usable — an identity only appears when its private key is
present, and only the Application one is a *codesigning* identity, so the
Installer certificate needs a lookup without `-p codesigning`:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
security find-identity -v                | grep "Developer ID Installer"
```

### 2. Provisioning profiles

Both targets are sandboxed and share an App Group. Under Developer ID distribution
that combination is only honoured when a matching provisioning profile is embedded
in the bundle, so two are needed, one per bundle ID.

Register the identifiers first, at
<https://developer.apple.com/account/resources/identifiers/list>:

1. **App Group** → identifier `group.org.feverdreamtv.tsync`.
2. **App ID** `org.feverdreamtv.tsync` → enable **App Groups**, assign that group.
3. **App ID** `org.feverdreamtv.tsync.fileprovider` → same group.

Then at <https://developer.apple.com/account/resources/profiles/list> → **+**,
under **Distribution** pick **Developer ID** (the plain macOS one, *not* "Developer
ID + Mac App Store"), twice:

| Profile | App ID | Save as |
|---|---|---|
| `tsync app` | `org.feverdreamtv.tsync` | `app.provisionprofile` |
| `tsync fileprovider` | `org.feverdreamtv.tsync.fileprovider` | `appex.provisionprofile` |

Each asks which certificate to include: the Developer ID Application certificate
from step 1. Inspect one with `security cms -D -i app.provisionprofile`.

> They expire after a year. When the release job starts failing with a profile
> error, regenerate both and re-set the two secrets.

### 3. App Store Connect API key

`notarytool` also accepts an app-specific password, but an API key is better for
CI: it survives Apple ID password changes and is not tied to anyone's 2FA.

1. <https://appstoreconnect.apple.com/access/integrations/api> → **Team Keys**.
2. **+**, name it `tsync notarization`, role **Developer** — Admin is not needed.
3. Download `AuthKey_XXXXXXXXXX.p8`. **It can only be downloaded once.**
4. Copy the **Key ID** (the `XXXXXXXXXX` in the filename) and the **Issuer ID**
   (a UUID above the key list).

```bash
xcrun notarytool history --key AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX --issuer <issuer-uuid>
```

### Putting it together

```bash
cd macos
export SIGN_IDENTITY="Developer ID Application: Your Name (PSE2VP6582)"
export INSTALLER_IDENTITY="Developer ID Installer: Your Name (PSE2VP6582)"
export PROFILE_APP=$PWD/app.provisionprofile
export PROFILE_APPEX=$PWD/appex.provisionprofile
export AC_API_KEY_PATH=$PWD/AuthKey_XXXXXXXXXX.p8
export AC_API_KEY_ID=XXXXXXXXXX
export AC_API_ISSUER_ID=<issuer-uuid>
./package.sh
```

Omit the three `AC_*` variables to build and sign without the notarization round
trip, which takes a few minutes. Then check the result is what a user will get:

```bash
spctl -a -vvv -t install dist/tsync.pkg   # accepted, source=Notarized Developer ID
pkgutil --check-signature dist/tsync.pkg
xcrun stapler validate dist/tsync.pkg
```

The pkg is a component package straight from `pkgbuild`. `productbuild` and a
distribution XML only become worthwhile if the installer ever needs a title page,
a licence or a custom layout.

Install it on a machine that has never had tsync to check the whole path works:
`/Applications/TsyncApp.app` exists, `which tsync` resolves through
`/usr/local/bin`, the app is running, and the extension shows up under **System
Settings → General → Login Items & Extensions → File Provider Extensions**.

---

## CI secrets

`.github/workflows/release.yml` runs after `test.yml` passes on main, packages the
pkg and publishes it to the rolling `nightly` prerelease. It reads seven
repository secrets, all derived from the three sections above. Binary material is
base64-encoded because GitHub secrets are text.

Export both certificates into one `.p12`: in Keychain Access select **Developer ID
Application: … (PSE2VP6582)** and **Developer ID Installer: … (PSE2VP6582)**,
expanding each triangle so the private keys are selected too — four items in all —
then right-click → **Export 4 items…** → `cert.p12`. The password it asks you to
set is `MACOS_CERT_PASSWORD`. The workflow pulls both identities back out of that
single file, so there is no second certificate secret.

```bash
base64 -i cert.p12               | gh secret set MACOS_CERT_P12
gh secret set MACOS_CERT_PASSWORD          # the .p12 password
base64 -i app.provisionprofile   | gh secret set MACOS_PROFILE_APP
base64 -i appex.provisionprofile | gh secret set MACOS_PROFILE_APPEX
base64 -i AuthKey_XXXXXXXXXX.p8  | gh secret set AC_API_KEY_P8
gh secret set AC_API_KEY_ID                # 10-character key id
gh secret set AC_API_ISSUER_ID             # issuer UUID
```

| Secret | Contents |
|---|---|
| `MACOS_CERT_P12` | base64 of the `.p12` (both certificates **and** their private keys) |
| `MACOS_CERT_PASSWORD` | password set when exporting the `.p12` |
| `MACOS_PROFILE_APP` | base64 of `app.provisionprofile` |
| `MACOS_PROFILE_APPEX` | base64 of `appex.provisionprofile` |
| `AC_API_KEY_P8` | base64 of `AuthKey_XXXXXXXXXX.p8` |
| `AC_API_KEY_ID` | 10-character key id |
| `AC_API_ISSUER_ID` | issuer UUID |

Confirm with `gh secret list`, then delete the local `.p12`, `.p8` and profiles.
They are credentials, and the `.p8` cannot be re-downloaded.

The workflow imports them into a throwaway keychain, picks the identity out of it
with `security find-identity`, and hands the profiles and key to `package.sh`
through the same environment variables you used locally. Re-run it by hand from
the Actions tab (`workflow_dispatch`) when you need to re-cut a release without a
new commit.

## Known limitations

- **Apple silicon only.** `macos-latest` runners are arm64 and the OCaml daemon is
  not built universal; that needs a second opam switch and `lipo`.
- **`nightly` is a rolling tag.** Every green commit on main overwrites the same
  pkg. There is no versioned release channel yet; `CFBundleShortVersionString` is
  hardcoded to `0.0.0` and `CFBundleVersion` is the workflow run number.
