# Privacy

tsync collects nothing. It has no account, no server of its own, no analytics and no crash reporting. Your files and your vault go only to the storage you configure: your bucket, your disk, or a tsync server you run.

This applies to every part of tsync: the `tsync` program, the macOS app, the Android app and the browser extension.

## What goes where

- **Files** are sent to the storage named in your config, over HTTPS for anything but a local disk. tsync does not encrypt them; that storage's own protections apply.
- **The vault's records** (two-factor codes, logins, notes, passkeys) are encrypted on your device, under your passphrase and secret key, before they are sent to that same storage. Nobody without both can read them, including whoever runs the storage.
- **Nothing is sent to the authors of tsync**, or to any other party, except as listed below.

## The browser extension

- It reads the pages you visit only to find login, password, two-factor and passkey fields, and fills them when you pick a login.
- It talks only to the `tsync` program on the same computer, through Chrome's native messaging. It makes no network requests of its own.
- It stores one thing in the browser: the list of sites where you chose *Never for this site*.
- It turns off Chrome's own offer to save passwords, and its address and card autofill, so that new logins go to one place. The popup's checkbox turns them back on.

## The Android app

- **Camera backup**, when you turn it on, reads your photos and videos and uploads them to your tsync server.
- **Autofill** reads the fields of the app or page you are filling, to offer your logins. To match an app with a website, it fetches that website's public `/.well-known/assetlinks.json`.
- **Scanning a QR code** uses Google Play services' code scanner, which processes the camera image on the phone.

## Other requests tsync makes

Setting a vault's icon from an `http(s)` URL fetches that image once.

## Contact

Questions and reports go to [the project's issues](https://github.com/toots/tsync/issues).
