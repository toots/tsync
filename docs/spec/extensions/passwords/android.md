# Passwords on Android

This file is normative. It owns how the [passwords](../passwords.md) extension reaches Android's
autofill and Credential Manager: which capabilities this host declares, the components that
realise them, and what the user sees. Every capability is planned until it has been seen working
on a signed build ([README §5](../README.md#5-host-adapters)); §9 lists what is declared.

## 1. Components

Both run in the app's default process and call the owner through the bridge, as every component
of the app does ([android-app §2](../../frontends/android-app.md#2-components-and-process)): the
owner is in that process and serves no socket. A request that arrives before boot boots first,
never on the main thread.

| Component | Platform | Role |
|---|---|---|
| Autofill service | `android.service.autofill.AutofillService`, Android 8 | logins and one-time codes in apps and in browsers that use the autofill framework; save (§5) |
| Credential provider | `androidx.credentials.provider.CredentialProviderService`, Android 14 | passkeys, and logins asked through Credential Manager (§6) |

- **Enabling them** is the user's: *Settings → Passwords, passkeys & accounts* (Android 14), or
  *Autofill service* before. The Passwords tab (§8) shows a row "Turn on tsync for autofill"
  while the autofill service is not the selected one (`AutofillManager.hasEnabledAutofillServices`),
  which opens that setting (`ACTION_REQUEST_SET_AUTOFILL_SERVICE`).
- Neither holds a secret beyond the request it answers, nor writes one to disk, nor logs a
  password, code, passphrase, seed or key.
- The phone serves one domain (android-app §2); there is no domain merge.
- **Neither unlocks** ([README §5](../README.md#5-host-adapters)). A request on a locked vault is
  answered with one entry, "tsync is locked", whose tap opens the app's Vault screen
  ([android-app §10.8](../../frontends/android-app.md#108-vault)), where the user unlocks; nothing is
  filled or signed. The user then asks again.

### 1.1 Records at hand

A request reads what the phone holds (§3): the records' bodies the cache keeps for
`RECORD_KEEP` ([README §4.1](../README.md#41-where-they-live)). So that they are there when a
form asks, the app lists the passwords once (`passwords_list`, `pull: auto`) after an unlock and
each time it comes to the foreground, fetching the bodies it lacks. A phone whose app has not
run for longer than `RECORD_KEEP` may answer its first request after that with nothing, and the
next with the logins.

## 2. Who is asking

A request names the app it fills, and for a browser the page. The extension trusts only what the
platform vouches for:

- **An app** is its package name as the framework reports it (the activity component of the
  `AssistStructure`, or `CallingAppInfo.packageName`), giving the site `android://<package>`
  (passwords §4.1). An app never names a web origin for itself.
- **A web page** is `https://<webDomain>` (`http` only when `webScheme` says so) from the
  structure's nodes, honoured only when the requesting package is a browser of the bundled
  **browser list**: package names with their signing certificates' SHA-256, refreshed each
  release. Any other app declaring a `webDomain` is treated as itself, so an app cannot draw a
  github.com form to collect github.com's login.
- The Credential Manager origin of a browser is `CallingAppInfo.getOrigin(<the same list in the
  platform's privileged-apps JSON form>)`; a caller off the list has no web origin (§6.3).

## 3. Logins

- **Fill** (`fill`, `confirm`). `onFillRequest` finds the username and password fields (autofill
  hints, then input types), and answers one dataset per matching login (`passwords_list` with
  `site` and `pull: background`, so the answer comes from what the phone holds, within the
  platform's deadline, while the pull goes on: a login added elsewhere a moment ago appears at
  the next request), shown by title and username. **No dataset holds a password**: each is gated by an
  authentication intent, so the platform has nothing to fill until the user picks. The pick
  starts a transparent activity that asks `passwords_fill` (passwords §8) and returns the dataset with the
  username and password.
- **Inline suggestions** (Android 11, in the keyboard) are planned: this version answers the
  dropdown only.
- **Nothing to offer**: no dataset, and no save info unless §5 applies. A fill request never
  answers from a cache.

## 4. One-time codes

- **Fill** (`fill` with codes, `confirm`). A field with a one-time-code hint
  (`AUTOFILL_HINT_SMS_OTP` or the `one-time-code` HTML autocomplete) gets one dataset per login
  matching the site that links a code, gated as §3, listed with `pull: background` as §3. The pick asks `passwords_fill` and fills its
  `code`; the code is read at the pick, never when the datasets are built.

## 5. Save

- **Save** (`save`, `confirm`). A fill response with a password field carries save info for the
  username and password, so the platform offers "Save to tsync?" when the user submits the form.
  `onSaveRequest` sends `passwords_save` (passwords §8) with the request's site, and the username and
  password typed. The platform's prompt is the approval.
- A reply naming a record to update (passwords §8: same site and username, another password)
  shows a notification "Update the password for `<site>`?", private on the lock screen, with
  **Update**, which sends `passwords_save` again with `update`. Nothing is updated without that
  tap. The new password waits in that button's pending intent, which the system holds for this
  app alone and drops when the notification is dismissed; it is never written to disk.
- A locked vault refuses the save, and a notification says it was not saved and why.

## 6. Passkeys

Through Credential Manager (Android 14), for the browsers of the list (§2). An app's passkey
needs its origin (`android:apk-key-hash:…`) checked against the RP's Digital Asset Links, which
the owner does not do: a passkey request from an app off the list is answered with no entry.

### 6.1 Assertion

- `onBeginGetCredentialRequest` answers, for each `BeginGetPublicKeyCredentialOption`, one
  `PublicKeyCredentialEntry` per passkey `passwords_passkey_match` (with `pull: background`, §3)
  answers for the request's RP
  ID and allow-list, and for each `BeginGetPasswordOption` one `PasswordCredentialEntry` per login
  matching the origin. Each entry carries a pending intent; nothing is signed or read before the
  pick. A locked vault answers one authentication action, "tsync is locked", opening the Vault
  screen (§1).
- The pick starts an activity that verifies the user when asked (§7), sends
  `passwords_passkey_assert` with the origin, the RP ID and the request's client data hash, and
  returns the assertion as WebAuthn's JSON (`PublicKeyCredential`). A login entry returns a
  `PasswordCredential` from `passwords_fill`.

### 6.2 Creation

- `onBeginCreateCredentialRequest` of a `BeginCreatePublicKeyCredentialRequest` from a browser of
  the list answers one entry, named by the domain. The system's sheet names the site and the user
  name; picking tsync's entry is the approval. The activity it starts verifies the user when asked
  (§7), sends `passwords_passkey_create` and returns the registration response's JSON. An exclusion the owner refuses `exists` returns WebAuthn's
  `InvalidStateError`.

### 6.3 The origin

The origin is the browser's, from `getOrigin` (§2). Without one the provider answers no entry;
the owner's check (passwords §7.3) is never skipped.

## 7. User verification

When the request asks for verification (`required` or `preferred`), the activity shows
`BiometricPrompt` with `BIOMETRIC_STRONG | DEVICE_CREDENTIAL` before it sends the request, and
sends `verified: true` only when it succeeded; a cancelled prompt cancels the request. With
`discouraged` it verifies nothing. The provider never asks for the passphrase (passwords §7.4).

## 8. In the app

The Vault screen ([android-app §10.8](../../frontends/android-app.md#108-vault)) gets a
**Passwords** tab when the domain uses `passwords`:

- **List** (`passwords_list`, with a search field as `filter`): logins by title and username,
  and passkeys by RP ID and user name; no password shown.
- **Copy** the username or the password (`passwords_get`), with `EXTRA_IS_SENSITIVE`, confirmed by
  a message naming the login, not the value; **Copy code** for a login linking one.
- **Remove** after a confirmation naming the record.
- No add, edit, import or export on the phone: logins arrive from a computer or from §5.
- The tab shows secrets only when copied; it sets `FLAG_SECURE` as the Codes tab does.

## 9. Capabilities

| capability | interaction | realised by | declared |
|---|---|---|---|
| `fill` | `confirm` | §3, the autofill service | planned |
| `fill` with codes | `confirm` | §4 | planned |
| `save` | `confirm` | §5, the platform's save prompt | planned |
| `passkey` | `confirm`, `authenticate` when verification is asked | §6, §7, Android 14, browsers of the list | planned |

## 10. Conformance

With tsync selected as the autofill service and the vault unlocked, on a signed build:

- Chrome on `https://github.com/login`, a login for `https://github.com`: the keyboard or the
  dropdown offers it by title and username; picking it fills both fields. Before the pick, the
  platform holds no password.
- An app declaring `webDomain` github.com that is not on the browser list is offered only the
  logins of `android://<its package>`.
- The two-factor field offers the linked login's current code.
- Submitting a new login offers "Save to tsync?"; saving adds it, and the Passwords tab lists it.
  Submitting another password for it offers the update notification.
- `https://webauthn.io` in Chrome: registering creates a passkey record after the biometric
  prompt when asked; signing in with it succeeds.
- With the vault locked, every request shows "tsync is locked" and fills nothing; its tap opens
  the Vault screen.
- With the app's process killed and the vault unlocked, the login page offers the login at the
  first tap, within the platform's deadline; the time from the request to the answer is
  measured on the phone and recorded here.
