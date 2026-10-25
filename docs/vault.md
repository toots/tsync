# The vault

A domain can keep secrets as well as files: two-factor codes, logins, notes and passkeys. They live in the domain's **vault**, sync with it to every machine, and are encrypted before they leave the machine that wrote them. Whoever reads the storage, the provider or a server's operator included, sees only sealed records.

This page covers the vault itself: creating it, unlocking machines, its keys, exports and backups. Using what it keeps, from the command line, the macOS menu bar and AutoFill, Chrome and Android, is on [Passwords, passkeys and two-factor codes](passwords.md).

The files of a domain stay unencrypted. Only the vault's records are sealed.

## Turning it on

A domain uses the vault when its config lists `extensions`, the kinds of secrets it keeps:

```json
{ "name": "Files", "extensions": ["totp", "passwords"], "backends": [ ... ], "frontends": [ ... ] }
```

| Extension | Keeps |
|---|---|
| `totp` | [Two-factor codes](passwords.md#two-factor-codes) |
| `passwords` | [Logins, notes and passkeys](passwords.md#passwords-and-passkeys) |

 With no `extensions`, the domain has no vault: its vault commands are refused, and nothing is written for it.

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
- `onScreenLock`: the screen locks or the machine goes to sleep: on Linux tsync watches this itself, on a Mac the menu bar app reports it, and on Android the phone's screen turning off locks it.
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

## Exporting and importing

An export is the whole vault in one file you keep: every code, login, note and passkey, the vault's keys and its appearance. It is a backup that needs neither the server nor tsync's own copy of the vault, and the way to start a vault again without losing anything.

```bash
tsync vault export --output vault.export    # asks for the passphrase
```

The file is sealed with your passphrase and this machine's secret key, as strongly as the vault itself, so it opens with those two and nothing else: keep the emergency kit that holds the secret key with it. tsync never replaces a file; choose a new name each time.

To start again from an export, delete the vault, make a new one, and import into it:

```bash
tsync vault delete
tsync vault init --kit kit.html
tsync vault import vault.export             # asks for the export's passphrase and secret key
```

The import asks for the passphrase and secret key the export was made with, which are the old ones: the new vault has its own. It only goes into a vault with nothing in it yet. Afterwards every other machine unlocks with the new secret key, as after `tsync vault rekey`.

The same cycle carries a vault across a release whose notes say the vault's format changed: export with the old release, upgrade every machine, then delete, init and import with the new one.

## Scheduled backups

A machine can back the vault up on its own. Each backup is sealed to a backup key that no computer keeps, so a stolen laptop or a read of the backup folder gives nothing away.

First make the backup key, and print its kit:

```bash
tsync vault backup-key --kit backup-kit.html
```

It shows the key once. Keep the printed page somewhere other than your computers; delete the file. Then give the domain a schedule in the config:

```json
"vaultBackup": {"dir": "/mnt/backups/tsync", "everyHours": 24, "keep": 14}
```

While the vault is unlocked, tsync writes a backup when the last one is a period old, and keeps the newest `keep`. A locked vault writes none until you unlock it. `tsync vault status` shows the last backup, and the menu says when one is overdue. Choose a folder on another disk, or in a domain on another store: a backup in the same place as the vault does not survive losing it.

To restore one, into a new vault as for an export:

```bash
tsync vault import --backup-key /mnt/backups/tsync/Files-20261025T141516.123Z.tsync-vault-backup
```

## Status and deleting

`tsync vault status` says whether the domain has a vault, whether it is unlocked here, and whether this machine is enrolled, with the auto-lock policy, the backup schedule and the last backup when they are set.

After a re-key or an import it also counts the **retired keys**: each key the vault used before, kept inside the vault under the current one so that anything sealed under an old key, an older export say, still opens. Nothing needs doing about them. A retired key that does not unwrap is named, since what was sealed under it no longer opens.

`tsync vault delete` removes the vault and everything in it, for every machine, after you type the domain's name to confirm. It asks for no passphrase: forgetting the passphrase is the reason to delete and start again. In a versioned domain the sealed records stay among the domain's versions until they expire.

## What the vault protects

- **The storage never holds a secret in clear.** Records, and the key that opens them, are sealed under your passphrase and secret key before upload. Whoever copies the bucket, or runs the server, needs both to read anything, and the secret key makes a short passphrase as hard to guess as a long one.
- **Record names say nothing.** The vault lives in a hidden `/.tsync-ext/` folder of the domain, under random names.
- **Conflicts never lose a record.** Two machines changing the vault at once are reconciled into one set, with nothing dropped.

What it does not hide:

- **That there is a vault, and roughly what is in it.** The storage shows which kinds of secrets a domain keeps, how many records of each, their sizes, and when each changed.
- **The colour and icon** of [the vault's appearance](#telling-vaults-apart), which stay readable so a locked vault can be told apart.
- **Anything on an unlocked machine.** Any program running as you there can ask tsync for a password, as with any password manager. Lock the machine, or set [`vaultLock`](#locking).
- **Old secrets from an old copy.** Someone who copied the storage and later learns the passphrase and secret key reads the records as they were then. A re-key protects what comes after it, not what was taken before.

And there is no way back in: a forgotten passphrase, or a secret key lost with every machine holding it, loses the vault. An [export](#exporting-and-importing) or a [scheduled backup](#scheduled-backups) is the only copy that survives either.
