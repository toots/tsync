# The vault

A domain can keep secrets as well as files: two-factor codes, and later passwords and passkeys. They live in the domain's **vault**, sync with it to every machine, and are encrypted before they leave the machine that wrote them. Whoever reads the storage, the provider included, sees only sealed records.

The files of a domain stay unencrypted, as before. Only the vault's records are sealed.

## Turning it on

A domain uses the vault when its config lists `extensions`, the kinds of secrets it keeps:

```json
{ "name": "Files", "extensions": ["totp"], "backends": [ ... ], "frontends": [ ... ] }
```

| Extension | Keeps |
|---|---|
| `totp` | [Two-factor codes](#two-factor-codes) |

Each kind is described in its own section below. With no `extensions`, the domain has no vault: its vault commands are refused, and nothing is written for it.

**Behind a server**, the server decides. A machine whose domain uses an `http-proxy` backend follows the server's list; it may list `extensions` itself only to use fewer of them, and a list naming one the server does not use is refused. The Android app always follows the server. `tsync status` shows the extensions in force, and where they come from:

```
  extensions       totp (from the main)
```

## Creating the vault

Once per domain, on any one machine:

```bash
tsync vault init
```

It asks for a **passphrase**, at least 16 characters, which you choose and remember; with `--generate` tsync makes one of six words for you instead, and prints it once to write down. It then prints a **secret key**, 26 characters in groups like `abcde-fghij-klmno-pqrst-uvwxyz`, once. Write the secret key down, or keep it in another password manager.

**The emergency kit** is a page to print and keep with your important papers: the secret key as text and as a QR code, and a box to write the passphrase in by hand. `tsync vault init --kit kit.html` writes it with the secret key it just made; later, on a machine that has joined the vault, `tsync vault kit --output kit.html` writes it again after asking for the passphrase. The file holds the secret key in plain text: print it, then delete it. tsync never replaces an existing file with a kit.

You need both to open the vault on a new machine. The secret key is what makes a short passphrase safe: whoever copies the storage cannot guess the passphrase without it. If you forget the passphrase, or lose the secret key along with every machine that has it, the vault's contents are gone. Nothing can recover them.

## Unlocking a machine

```bash
tsync vault unlock
```

The first time on a machine it asks for the passphrase and the secret key; the machine is then **enrolled**, and later unlocks ask only for the passphrase. An unlocked machine keeps the vault's key in the system's keystore, so it stays unlocked across restarts until you lock it:

| Machine | Where the key is kept |
|---|---|
| macOS | The login keychain, readable only by tsync's own service |
| Linux | The Secret Service (GNOME Keyring, KWallet); without one, memory until tsync stops |
| Android | The Android Keystore |

`--stdin` reads the passphrase (then the secret key) from standard input instead of the terminal, one line each. A passphrase is never taken as a command-line argument, which other programs can see.

## Locking

```bash
tsync vault lock            # forget the key; the next unlock asks for the passphrase
tsync vault lock --forget   # also forget the secret key: the next unlock asks for both
```

While a machine is unlocked, any program running as you on it can ask tsync for the vault's contents, as with any password manager's unlocked state. Lock the machines you leave unattended.

**Locking on its own.** A domain can lock its vault without being asked, which is off unless you turn it on. Give the domain a `vaultLock` in the config with any of:

```json
"vaultLock": {"idleMinutes": 15, "onScreenLock": true, "maxHours": 12}
```

- `idleMinutes`: no code, password or passkey used for that long. A status or a listing that shows no secret does not count as use.
- `onScreenLock`: the screen locks or the machine goes to sleep: on a Mac the menu bar app reports it.
- `maxHours`: that long after unlocking, however much the vault is used.

The server can set one for everyone behind it, and the strictest of yours and the server's applies: you can make it lock sooner, never later. While a policy is on, the key is never kept in the system keychain, so a restart leaves the vault locked; the machine stays set up and asks only for the passphrase. `tsync vault status` shows the policy in force, and why the vault was locked last.

## Changing the passphrase

```bash
tsync vault passphrase                    # a new passphrase; other machines unlock with it
tsync vault passphrase --new-secret-key   # also a new secret key, printed once
```

With `--new-secret-key`, every other machine needs the new secret key at its next unlock. Neither change revokes old secrets from someone who copied the storage earlier: a versioned domain keeps the previous keyring among its versions.

## Machines, and shutting one out

```bash
tsync vault machines                  # the machines that joined, and when each last unlocked
tsync vault machines --name "laptop"  # rename this one in the list
tsync vault rekey                     # a new key and secret key: shuts out every machine but this one
tsync vault rekey --new-passphrase    # the same, with a new passphrase
```

Each machine that joins the vault adds itself to the list, and the others say so until they list the machines: in `tsync vault status`, and as a row under the domain in the menu bar and the tray. The list only informs: it cannot keep a machine out.

A lost or stolen machine still holds the secret key, and the key that reads every record, so changing the passphrase is not enough. `tsync vault rekey` asks for the passphrase, draws a new key and secret key, re-encrypts every record, and prints the new secret key once. Every other machine is locked until you unlock it with the new secret key, and the list starts again with this machine alone. If the machine was lost, choose a new passphrase too. Earlier versions of the records, kept by a versioned domain, stay under the old key until retention removes them.

## Telling vaults apart

With several domains, tsync's pickers show each vault in its own colour: the tsync icon, tinted. Every vault gets a colour from its key, the same on every machine. You can choose another, or give the vault an icon of its own, which then replaces the tsync icon:

```bash
tsync vault appearance --color "#0d9488"        # a colour of your choice
tsync vault appearance --icon work.jpg          # any image or an http(s) URL, cropped square
tsync vault appearance --default-color --no-icon
```

The colour and icon sync with the domain and show even while the vault is locked, so they are not encrypted: do not use a private image.

## Status and deleting

`tsync vault status` says whether the domain has a vault, whether it is unlocked here, and whether this machine is enrolled.

`tsync vault delete` removes the vault and everything in it, for every machine, after you type the domain's name to confirm. It asks for no passphrase: forgetting the passphrase is the reason to delete and start again. In a versioned domain the sealed records stay among the domain's versions until they expire.

## Two-factor codes

With `totp` in `extensions`, the vault keeps the seeds of time-based two-factor codes (TOTP), the six-digit codes an authenticator app shows. tsync computes the codes; no seed ever leaves the vault, and none is printed back.

**Adding a code.** A service shows its seed as a QR code, which holds an `otpauth://totp/` link, or as text:

```bash
tsync totp add -                                          # paste the otpauth:// link on standard input
tsync totp add --secret - --issuer GitHub --account me    # the text seed, read from standard input
```

Pass `-` and paste, rather than the seed itself on the command line, so it stays out of your shell's history.

**Reading a code.**

```bash
tsync totp list               # the records: issuer, account, seconds left, id
tsync totp list github        # those whose issuer or account contains "github"
tsync totp list --show-codes  # with their current codes
tsync totp code ID            # one code
```

`list` prints no code unless you ask: a terminal's output ends up in its scrollback, a screen share, or a tool reading it.

**Moving from another authenticator.** `tsync totp import FILE` reads a plain-text export, one `otpauth://` link per line, as Ente Auth and others write it. It says how many it added, how many were already there, and why any line was refused, by line number and never by content. Importing the same file twice adds nothing.

**Moving out.** `tsync totp export` prints every record as an `otpauth://` link. It asks for the passphrase each time, even on an unlocked machine: no other way gets the seeds out.

**From the macOS menu bar.** The menu's *One-time codes* lists each record as `issuer — account`. Clicking one copies its current code, marked so clipboard managers and history skip it; the menu never shows a code itself. A locked domain shows *Locked — unlock…*, which asks for the passphrase (and the secret key on a machine not yet enrolled); *Add a code…* takes the issuer, the account and the seed, or a pasted `otpauth://` link. Each secret field has a *Show* box to see what you typed. Creating the vault, changing the passphrase, deleting and exporting stay with the command line. The Linux tray shows no codes: use `tsync totp list` there.

`tsync totp rename ID` and `tsync totp remove ID` change or remove one record. Two machines changing the same record at once lose nothing: two renames keep the newer name, a rename and a removal keep the renamed record, and two different codes under one record are both kept, the second labelled `(conflicted copy from <machine>)` for you to remove the one you do not want.

## What the vault protects

- **The storage never holds a secret in clear.** Records, and the key that opens them, are sealed under your passphrase and secret key before upload.
- **Record names say nothing.** The vault lives in a hidden `/.tsync-ext/` folder of the domain, under random names.
- **Conflicts never lose a record.** Two machines changing the vault at once are reconciled into one set, with nothing dropped.
