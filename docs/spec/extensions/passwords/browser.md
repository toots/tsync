# Passwords in a browser

This file is normative. It owns the browser extension of the [passwords](../passwords.md)
extension: what it is, how it reaches the owner, how it finds forms, fills, saves and handles
passkeys, and what the user sees. The bridge and its requests are passwords §9; this file is the
extension on the other end.

The extension is a client of the owner, not a host adapter (passwords §9): it declares no
capability. What has been seen working is recorded in §10.

## 1. What it is

- **One WebExtension** (Manifest V3), built from `browser/` in the repository, for the Chromium
  family first: Chrome, Chromium, Brave, Edge and Vivaldi, on macOS and Linux. Firefox comes later
  (§11).
- It has three parts:
  - **the service worker**, the only part that talks to the bridge (`chrome.runtime.connectNative`),
    and the only part that decides what a page may receive;
  - **a content script** in every frame, in the extension's isolated world, which finds fields and
    fills them, and draws nothing a page script can read;
  - **the extension's own pages**: the toolbar popup, and the sheet of §5 (an extension window),
    where the user picks, approves and types. A page never sees them.
- **It holds no secret.** It never writes a password, a code, a passkey or a match result to
  `chrome.storage`, IndexedDB or the page; what a fill hands a field is in memory for that fill
  only. It keeps one setting of its own, whether to offer to save (§4).

## 2. Installing

- `tsync passwords browser install` writes the native-messaging manifest for each Chromium-family
  browser it finds on the host, under the browser's per-user directory (`NativeMessagingHosts/` of
  its profile root on macOS and Linux), naming the bridge's absolute path and the extension's id in
  `allowed_origins`. `--extension-id ID` adds one; `tsync passwords browser uninstall` removes what
  install wrote. Nothing else in the browser's directories is touched.
- **The extension id is fixed**: the manifest carries the extension's public key (`key`), so an
  unpacked copy and a packaged one have the same id, the one install names.
- **No store.** The extension is never published to a browser's store; tsync's own install adds it:
  - **Linux:** the packages install the packed extension (`/usr/share/tsync/browser-extension.crx`)
    and an external-extension file for each Chromium-family browser
    (`/usr/share/google-chrome/extensions/<id>.json`, and Chromium's, Brave's and Edge's own
    directories), naming the `.crx` and its version. The browser offers to enable it at its next
    start; a package upgrade updates it.
  - **macOS:** Chrome accepts an external extension there only from its store. The app bundle
    carries the unpacked extension (`TsyncApp.app/Contents/Resources/browser-extension`), and the
    user adds it once with *Load unpacked* in developer mode; `tsync passwords browser install`
    prints the path and the steps. A configuration profile that installs it by policy is left for
    later (§11).
  - Firefox needs its extensions signed by Mozilla, and comes with Firefox support (§11).
- The popup says what is missing when it cannot reach the bridge: the native host not installed
  (*Run `tsync passwords browser install`*), the owner not running, or no domain using passwords.

## 3. Forms and fills

### 3.1 Finding fields

- The content script classifies the fields of each frame as Chromium does for its own autofill:
  the `autocomplete` attribute first (`username`, `email`, `current-password`, `new-password`,
  `one-time-code`), then `type="password"`, then the name, id and label against Chromium's
  patterns (`otp|verification.code|2fa|six.digit` for a code), as the Android service does
  ([android §4](android.md#4-one-time-codes)).
- It marks each username, password and code field it found with a small tsync icon inside the
  field, drawn in a closed shadow root the page cannot reach into.
- **Finding asks nothing.** Classifying and marking fields sends no request: a page that draws a
  form learns nothing, and the bridge is not asked about it.

### 3.2 Filling, on a gesture only

- **The gesture** is a click on the field's icon, the popup, or the keyboard shortcut (Chromium
  `commands`, default `Ctrl+Shift+L` / `⌘⇧L`). Nothing else asks the bridge for the page's logins:
  not a page load, not a focus, not a script.
- On the gesture the service worker asks `match` with the **origin of the frame**, taken from the
  browser (`MessageSender.origin` of the content script's message), never from the page. It shows
  the logins it answers in a menu under the field, drawn by the extension (§1), by title and
  username. A locked domain is a row *tsync is locked — unlock it in tsync*, which does nothing
  (extensions README §5).
- **The pick** asks `fill` with the frame's origin, the domain and the id; the bridge refuses a login
  that does not match that origin (passwords §9.2). The content script sets the username and
  password fields of that frame's form, firing the `input` and `change` events a page listens to.
- **Codes.** A code field's icon offers the codes of the logins matching the frame that link one;
  the pick fills the current code from `fill`. The popup also lists them with **Copy code**
  (§3.3). A two-factor code no login links is not offered in the browser: it is read from the
  tsync menu or `tsync totp`.
- **Frames.** A login is filled only into the frame whose origin it matches: a form in a
  cross-origin frame is filled from that frame's matches, never the top page's.

### 3.3 The popup

The toolbar popup, on the user's click, shows the current tab's top-frame origin, its matching
logins (title, username, *Fill*, and *Copy code* for one linking a code), each domain's state
(locked, unlocked), and what is missing (§2). *Copy code* writes the code to the clipboard; the
web has no sensitivity marker, so the popup says the code stays on the clipboard until replaced.
The popup lists no other site's logins and no password.

## 4. Saving

- When a form holding a password field the user typed into is submitted (a `submit` event, or a
  navigation that follows a click on the form's button), the content script hands the username
  and the password typed to the service worker, with the frame's origin from the browser.
- The service worker asks nothing yet. It shows the extension's sheet (§5): *Save this login for
  `<site>` in tsync?*, naming the username, with **Save**, **Not now** and **Never for this site**.
  Only **Save** sends `save`; a reply naming a record to update shows *Update the password for
  `<title>`?* in the same sheet, and only **Update** sends `save` with `update`.
- The password waits in the service worker's memory until the sheet is answered or closed, then is
  dropped. *Never for this site* is the one thing the extension keeps (§1): a list of origins,
  without usernames.
- A locked vault: the sheet says the login was not saved because tsync is locked, and to unlock it
  in tsync and sign in again.

## 5. Passkeys

- The content script installs, in the page's main world, a wrapper of
  `navigator.credentials.create` and `navigator.credentials.get` for `publicKey` requests. The
  wrapper forwards the request's options to the isolated content script and waits; anything else
  goes to the browser untouched.
- The service worker takes the origin from the browser (`MessageSender.origin`), never from the
  wrapper, and builds the client data itself (`type`, `challenge`, `origin`, `crossOrigin`), so the
  owner signs `SHA-256(clientDataJSON)` over an origin the page cannot choose; the owner checks the
  RP ID against it (passwords §7.3).
- **Assertion.** It asks `passkey_match`. With answers, it opens the extension's sheet listing them
  by user name, with **Use another passkey or device**; a pick sends `passkey_assert` and the
  wrapper resolves the page's promise with the assertion. With none, or on *another device*, the
  request goes on to the browser's own WebAuthn, unchanged.
- **Creation.** It opens the sheet: *Save a passkey for `<user>` on `<site>` in tsync?*, with
  **Save** and **Use another passkey or device**. **Save** sends `passkey_create`, with the
  request's exclude list; `exists` rejects the page's promise with `InvalidStateError`.
- **User verification.** A request whose `userVerification` is `required` or `preferred` is
  verified before it is sent, by the machine's own means, through the bridge:
  - **macOS:** the bridge asks LocalAuthentication (`deviceOwnerAuthentication`: Touch ID or the
    account password), and sends `verified: true` only when it succeeded, as the AutoFill
    extension does ([macos §5](macos.md#5-user-verification));
  - **Linux:** no platform verifier: the sheet asks for the vault's passphrase, which the bridge
    sends as `passphrase` (passwords §7.4) and the owner checks. It verifies; it unlocks nothing,
    and is never kept.
  A cancelled or failed verification cancels the request. With `discouraged`, nothing is verified
  and UV is clear.
- A locked vault: the sheet says so and offers only *Use another passkey or device*.
- Conditional mediation (`mediation: "conditional"`, passkeys in the autofill menu) is answered as
  an assertion when the user clicks the field's icon; until then the request waits, as the
  browser's own does.

## 6. What a page can and cannot do

- **Learn logins:** no. Nothing is asked without a gesture; what a gesture fills goes to the frame
  whose origin matches, and the bridge refuses any other.
- **Spoof its origin:** no. Every request carries the origin the browser gives the extension for
  the sending frame; the wrapper's and the content script's words about the origin are never used.
- **Read the extension's UI:** no. Menus are in closed shadow roots, sheets and the popup are
  extension pages.
- **Trigger a save or a passkey silently:** no. Each needs a click in the extension's own sheet.
- **Read a filled password back:** yes, as with any password manager or typing: a page script can
  read the field it was filled into. That is the page's own field.

## 7. The bridge requests used

`status`, `match`, `fill`, `save`, `passkey_match`, `passkey_create`, `passkey_assert`, as passwords
§9.2, and `verify` (passwords §9.2), with which the service worker asks the bridge to verify the
user before a passkey request (§5).

## 8. Several domains

A machine may use passwords in several domains (README §6.1): every list merges them, each row
naming its domain when there is more than one; a new login or passkey goes to the first domain
using passwords, and the sheet names it.

## 9. Conformance

With the extension installed, the native host installed, and the vault unlocked:

- `https://github.com/login`: no bridge request before a gesture; a click on the field's icon lists
  the GitHub login; picking it fills both fields. The same login in a cross-origin frame of another
  site is not offered.
- The two-factor field's icon offers the linked code; picking it fills the current code.
- Signing in with a new login offers *Save*; saving adds it (`tsync passwords list` shows it);
  another password for it offers *Update*.
- `https://webauthn.io`: creating a passkey with tsync saves it, after Touch ID on macOS or the
  passphrase on Linux; signing in with it succeeds, the site seeing UV set. *Use another passkey or device* hands the request to the
  browser.
- With the vault locked, every menu and sheet says so and fills nothing.
- A page script calling `navigator.credentials.get` with a forged `origin` in its options gets an
  assertion over the real origin, or none.

## 10. Seen working

| Browser | Host | Fill | Codes | Save | Passkeys |
|---|---|---|---|---|---|
| Chrome | macOS | planned | planned | planned | planned |
| Chrome | Linux | planned | planned | planned | planned |

## 11. Later

- **Firefox**: the same extension, its native-messaging manifest (`allowed_extensions`), and a
  Mozilla-signed package.
- **macOS without developer mode**: a configuration profile installing the extension by Chrome
  policy, or a store listing, if loading it unpacked proves a burden.
