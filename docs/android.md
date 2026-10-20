# Use it from an Android phone


The app connects to one domain on one tsync server.

**Setup.** Enter the server's URL and the secret, then tap **Check server**: the app lists the domains that secret opens. Pick one, set how much storage the cache may use (2 GB by default), and tap **Connect**. The URL must be `https://`.

**Files.** Browse the domain, also offline: a folder you have seen stays listed, with a banner saying when it was last refreshed. Each file shows whether it is online-only, available offline, or waiting to upload. Long-press an item to open it, share a link, keep it offline, remove its download, rename, move or delete it.

**Other apps.** tsync appears in Android's file picker, so any app can open and save documents in the domain. It is also a share target: *Save to tsync* in another app's share sheet, then pick a folder.

**Camera backup.** In Settings, turn on *Back up camera photos and videos*, and choose between everything already on the phone and new captures only. It uploads over wifi only and not on a low battery, unless you switch those off. *Back up now* runs it at once.

**Vault.** <a id="vault"></a>When the server's domain uses the [vault](vault.md), a *Vault* screen appears. The phone follows the domain: create the vault, change its passphrase or delete it on a computer.

- *Unlock* with the passphrase, and the first time on this phone the secret key too; the phone then stays unlocked until you lock it from the screen's menu (⋮), which can also forget the secret key.
- *Codes* lists your two-factor codes with the seconds each has left. Tap one to copy it; the copy is marked sensitive, so the keyboard and clipboard previews hide it. Long-press to rename or remove. The search field narrows the list.
- *Add* (+) scans a QR code, imports another authenticator's plain-text export, or takes the issuer, account and seed by hand (or a pasted `otpauth://` link). Scanning uses Google Play services' scanner; on GrapheneOS, Play services needs the camera permission for it. A QR code opened from the camera or a browser is offered to tsync too, and added only after you confirm.
- *Passwords* (with passwords in the vault) lists your logins and passkeys. Tap one to copy its username, password or code, marked sensitive, or to remove it. Logins arrive from your computers, or from autofill's save prompt below.
- Offline, the codes still work: a banner says when they were last refreshed.
- When another machine joins the vault, a banner names it until you tap *Seen*; after a re-key elsewhere, the unlock asks for the new secret key and says why.
- The screen cannot be screenshotted or shown in recent apps.

**Passwords and autofill.** <a id="passwords-and-autofill"></a>tsync can fill logins, two-factor codes and passkeys in apps and browsers.

- **Turn it on** in *Settings → Passwords, passkeys & accounts*: choose tsync as the *Preferred service*, and turn tsync on (and Google off, if you like) under *Additional providers*. The *Passwords* tab offers *Turn on tsync for autofill* until you have.
- **Chrome** fills from its own password manager unless told otherwise: in Chrome, *Settings → Autofill services → Autofill using another service*, then restart Chrome. Vanadium and Firefox use tsync directly.
- **Filling.** Tap a username or password field: tsync's suggestions name each login by title and username, and the password is fetched only when you pick one. A code field offers the code of the site's login that links one.
- **Saving.** Signing in with a login tsync does not have offers *Save to tsync?*. A changed password asks, in a notification, whether to update the one tsync has.
- **Passkeys** (Android 14 and later) work in the browsers Google lists for passkeys, Chrome, Firefox, Brave, Edge, Samsung Internet and Vanadium among them: create one with tsync, and sign in with it, after the fingerprint or screen lock when the site asks. Apps' own passkeys are not supported yet.
- **Which site.** A page's address is believed only from a browser on that list, checked by its signature. Any other app is offered only the logins saved for that app, whatever it claims to show.
- **A locked vault** shows *tsync is locked*; tapping it opens the Vault screen, where you unlock. Autofill never asks for your passphrase.
- Suggestions come from what the phone already holds, so they appear quickly and offline; logins added elsewhere a moment ago show at the next tap.

**Activity.** What is uploading and downloading, what failed with a *Retry*, a pause switch, and the status text for diagnosis.

**Settings → Storage → Free up space** removes every download from the phone, files kept offline included.
