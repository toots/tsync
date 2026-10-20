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
- Offline, the codes still work: a banner says when they were last refreshed.
- The screen cannot be screenshotted or shown in recent apps.

**Activity.** What is uploading and downloading, what failed with a *Retry*, a pause switch, and the status text for diagnosis.

**Settings → Storage → Free up space** removes every download from the phone, files kept offline included.
