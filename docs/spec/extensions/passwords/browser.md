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
  - **Linux:** the packages install the packed extension (`/usr/share/tsync/browser-extension.crx`,
    signed with the extension's key; until the packaging carries it, the unpacked
    `/usr/share/tsync/browser-extension` is loaded as on macOS) and an external-extension file for
    each Chromium-family browser
    (`/usr/share/google-chrome/extensions/<id>.json`, and Chromium's, Brave's and Edge's own
    directories), naming the `.crx` and its version. The browser offers to enable it at its next
    start; a package upgrade updates it.
  - **macOS:** Chrome accepts an external extension there only from its store. The app bundle
    carries the unpacked extension (`TsyncApp.app/Contents/Resources/browser-extension`). A
    browser's folder picker cannot open a folder inside an app bundle, so
    `tsync passwords browser install` copies it to
    `~/Library/Application Support/tsync/browser-extension`, replacing an older copy, and prints
    that path and the steps; the user adds it once with *Load unpacked* in developer mode, and
    after an upgrade installs again and reloads the extension. A configuration profile that installs it by policy is left for
    later (§11).
  - Firefox needs its extensions signed by Mozilla, and comes with Firefox support (§11).
- **Incognito.** The extension works in incognito windows when the user allows it in the browser
  (*Allow in Incognito*, off by default for every extension). It then fills, saves, suggests and
  makes passkeys there as in a regular window, each the user's own act, and stores nothing of its
  own from an incognito tab: the save sheet offers no *Never for this site* there.
- The popup says what is missing when it cannot reach the bridge: the native host not installed
  (*Run `tsync passwords browser install`*), the owner not running, or no domain using passwords.

## 3. Forms and fills

### 3.1 Finding fields

- The content script classifies the fields of each frame as Chromium does for its own autofill:
  the `autocomplete` attribute first (`username`, `email`, `current-password`, `new-password`,
  `one-time-code`), then `type="password"`, then the name, id and label against Chromium's
  patterns (`otp|verification.code|2fa|six.digit`, and `mfa`, `one-time`, a login or
  authentication code, for a code), as the Android service does
  ([android §4](android.md#4-one-time-codes)). A field named only *Code* is not one (a promo or
  postal code as often), nor a *security code* (a card's CVC); its code is in the popup.
  Several code fields in one form are a code split in one box per digit, which tsync does not
  fill, and an account number, account holder or routing number is no username.
- A field the page marks for password managers to leave alone (`data-1p-ignore`,
  `data-bwignore`, `data-lpignore="true"`) is none of these.
- It marks each username, password and code field it found with tsync's icon (its mark in a blue
  circle, 20 px) at the right end inside the field, from the page's load and on every field
  drawn, not only the focused one, so tsync is seen to be there before a click. The icons are
  drawn in a closed shadow root the page cannot reach into, follow their fields on scroll and
  resize, and leave a field too small to carry one or not drawn: transparent, hidden by an
  ancestor, under `aria-hidden` or `inert`, or clipped away by a container.
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
- **A pick counts only as the user saw it**: a trusted click (`isTrusted`) on the icon or a row, the
  overlay on top at the click's point (`elementFromPoint`), visible, unfiltered, with nothing in the
  top layer over it; the overlay's own styles are pinned with inline `!important` so a page's
  stylesheet cannot fade or hide it. A click that fails any of these does nothing.
- **The pick** asks `fill` with the frame's origin, the domain and the id; the bridge refuses a login
  that does not match that origin (passwords §9.2). The content script sets the username and
  password fields of that frame's form, firing the `input` and `change` events a page listens to;
  a code pick sets only the code field.
- **A login matching by suffix only** (saved for `example.com`, asked by `login.example.com`, the
  `match` row's `exact` false) is marked so in the menu and fills only after the extension's sheet
  confirms it, naming both sites: a subdomain the user does not control never gets the parent
  site's login on one click.
- **Codes.** A code field's icon offers the codes of the logins matching the frame that link one;
  the pick fills the current code from `fill`. The popup also lists them with **Copy code**
  (§3.3). A two-factor code no login links is not offered in the browser: it is read from the
  tsync menu or `tsync totp`.
- **Suggesting a password** (passwords §5.1). A new-password field's icon offers *Use a strong
  password* above the logins. The pick, counted as a fill's is, sends `suggest` with the frame's
  origin and the form's username, fills the field and its confirmation with the answer, firing the
  same events, and keeps the record's id for that form.
- **Frames.** A login is filled only into the frame whose origin it matches: a form in a
  cross-origin frame is filled from that frame's matches, never the top page's.

### 3.3 The popup

The toolbar popup, on the user's click, shows the current tab's top-frame origin, its matching
logins (title, username, *Fill*, and *Copy code* for one linking a code), each domain's state
(locked, unlocked), and what is missing (§2). *Copy code* writes the code to the clipboard; the
web has no sensitivity marker, so the popup says the code stays on the clipboard until replaced.
The popup lists no other site's logins and no password.

It also offers **Turn off the browser's own password manager**: the browser's saving and filling
of passwords (`chrome.privacy.services.passwordSavingEnabled` set to false), which otherwise offers
alongside tsync's and keeps what a user meant for tsync. The extension turns it off once, when it
is installed, so the box starts checked; unchecking it gives the setting back to the browser, and
the extension never turns it off again by itself.

## 4. Saving

- When the user submits a form (a trusted `submit`, or a trusted click on its button) holding a
  password field the user typed into (a trusted `input` event; a value tsync filled does not
  count), the content script hands the username and the password typed to the service worker, with
  the frame's origin from the browser. A script's submit, or a password a script set, offers
  nothing.
- The service worker never compares the typed password with tsync's: whether a sheet appears
  depends on nothing secret, so a page cannot use it to test a guess. It asks `match` only to tell
  a new login from a changed one, and shows the extension's sheet: *Save this login in tsync?*, or
  *Update the password for `<title>`?* when tsync holds a login of that username for this exact
  site (`exact`), with **Save** or **Update**, **Not now** and, for a new one, **Never for this
  site**. Only that click sends `save`; the owner adds nothing when the password is already the one
  it holds, and updates only a login of the exact site (passwords §8).
- **A suggested password's submit** shows no sheet: the content script sends `save` with
  `suggested`, the id kept at the pick, and the username submitted. The password itself is not
  sent again.
- The password waits in the service worker's memory until the sheet is answered or closed, then is
  dropped. *Never for this site* is the one thing the extension keeps (§1): a list of origins,
  without usernames.
- A locked vault (every domain using passwords locked): the sheet says the login was not saved
  because tsync is locked, and to unlock it in tsync and sign in again.

## 5. Passkeys

- The content script installs, in the page's main world, a wrapper of
  `navigator.credentials.create` and `navigator.credentials.get` for `publicKey` requests. The
  wrapper forwards the request's options to the isolated content script and waits; anything else
  goes to the browser untouched.
- The service worker takes the origin from the browser (`MessageSender.origin`), never from the
  wrapper, and builds the client data itself (`type`, `challenge`, `origin`, `crossOrigin`), so the
  owner signs `SHA-256(clientDataJSON)` over an origin the page cannot choose; the owner checks the
  RP ID against it (passwords §7.3).
- **Nothing goes to the browser behind the user's back.** A request goes to the browser's own
  WebAuthn only when the user picks **Use a phone or security key** in a sign-in's sheet, and a
  creation never does: the browser's dialog would keep the passkey in its own manager, which a
  user cannot tell from tsync. A request the content script cannot pass to the service worker
  (an extension reloaded under an open page cuts it off) is rejected `NotAllowedError`, *tsync
  did not answer: reload the page*; an owner's refusal rejects the page's promise.
- **Frames.** tsync answers top-level pages, and builds `crossOrigin: false`. A request from a
  frame whose origin is not the top page's would need the embedder's permissions policy, which only
  the browser knows: the sheet says tsync cannot use passkeys inside that page, with **Cancel**,
  and for a sign-in **Use a phone or security key**.
- **Every sheet names the origin the browser gave**, never the RP ID or the names the page sent.
- **Assertion.** It asks `passkey_match`. With answers, it opens the extension's sheet listing them
  by user name, with **Use a phone or security key** and **Cancel**; a pick sends
  `passkey_assert` and the wrapper resolves the page's promise with the assertion. With none, the
  sheet says *tsync has no passkey for `<origin>`*, with the same two choices; with none and a
  locked domain, it says tsync is locked. *Phone or security key* passes the request on to the
  browser's own WebAuthn, unchanged; *Cancel* rejects it `NotAllowedError`. A sheet answers even
  when tsync has nothing, so a page cannot tell that from a cancel.
- **Creation.** It first asks `passkey_match` with the request's RP ID, so the owner refuses an RP ID
  the origin does not own before any sheet names it (a page's `SecurityError`). Then the sheet:
  *Save a passkey for `<user>` on `<origin>` in tsync?*, with **Save in tsync** and **Cancel**.
  **Save in tsync** sends `passkey_create`, with the request's exclude list; `exists` rejects the
  page's promise with `InvalidStateError`.
- **One session, refusal ends it.** A verification and the request it covers go in one bridge
  session; a cancelled or failed verification ends it, and the request is never sent.
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
- A locked vault: the sheet says so, with **Cancel**, and for a sign-in *Use a phone or security
  key*.
- **Conditional mediation** (`mediation: "conditional"`, passkeys in the autofill menu): tsync holds
  the request only when it has passkeys for the RP ID; otherwise it leaves it unanswered, until
  the page aborts it, and never gives it to the browser's own conditional UI. A held request adds *Sign in with a passkey* to the field's menu, whose
  pick opens the sheet as an assertion does.

## 6. What a page can and cannot do

- **Learn logins:** no. Nothing is asked without a gesture; what a gesture fills goes to the frame
  whose origin matches, and the bridge refuses any other. A page cannot click for the user: a
  pick is a trusted click on the overlay as drawn (§3.2), and a login matching by suffix needs the
  sheet.
- **Test a password guess:** no. The save sheet appears on the user's typing and submit, never on a
  comparison (§4).
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

A machine may use passwords in several domains (README §6.1): every list merges them. With more
than one domain in a list, its rows are grouped by domain under a header naming the domain with its
vault's mark ([vault §8.1](../vault.md#81-appearance), from the bridge's `status`: the vault's
icon, or the tsync glyph in its colour, the glyph also where a page's policy blocks the icon); a
row carries no mark. The popup's state lines carry each domain's mark. A new login or passkey goes
to the first domain using passwords.

## 9. Conformance

With the extension installed, the native host installed, and the vault unlocked:

- `https://github.com/login`: no bridge request before a gesture; a click on the field's icon lists
  the GitHub login; picking it fills both fields. The same login in a cross-origin frame of another
  site is not offered.
- The two-factor field's icon offers the linked code; picking it fills the current code.
- Signing in with a new login offers *Save*; saving adds it (`tsync passwords list` shows it);
  another password for it offers *Update*.
- `https://webauthn.io`: creating a passkey with tsync saves it, after Touch ID on macOS or the
  passphrase on Linux; signing in with it succeeds, the site seeing UV set. *Use a phone or security key* hands a sign-in to the
  browser; a creation offers only *Save in tsync* and *Cancel*.
- With the vault locked, every menu and sheet says so and fills nothing.
- A page script calling `navigator.credentials.get` with a forged `origin` in its options gets an
  assertion over the real origin, or none.

## 10. Seen working

| Browser | Host | Fill | Codes | Save | Passkeys |
|---|---|---|---|---|---|
| Chrome | macOS | seen | seen | seen | seen |
| Chrome | Linux | planned | planned | planned | planned |

## 11. Later

- **Firefox**: the same extension, its native-messaging manifest (`allowed_extensions`), and a
  Mozilla-signed package.
- **macOS without developer mode**: a configuration profile installing the extension by Chrome
  policy, or a store listing, if loading it unpacked proves a burden.
