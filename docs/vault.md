# The vault

A domain can keep secrets as well as files: two-factor codes, and later passwords and passkeys. They live in the domain's **vault**, sync with it to every machine, and are encrypted before they leave the machine that wrote them. Whoever reads the storage, the provider included, sees only sealed records.

The files of a domain stay unencrypted, as before. Only the vault's records are sealed.

## Turning it on

A domain uses the vault when its config lists `extensions`, the kinds of secrets it keeps:

```json
{ "name": "Files", "extensions": ["..."], "backends": [ ... ], "frontends": [ ... ] }
```

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

It asks for a **passphrase**, at least 16 characters, which you choose and remember. It then prints a **secret key**, 26 characters in groups like `abcde-fghij-klmno-pqrst-uvwxyz`, once. Write the secret key down, or keep it in another password manager: tsync never shows it again.

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

## Changing the passphrase

```bash
tsync vault passphrase                    # a new passphrase; other machines unlock with it
tsync vault passphrase --new-secret-key   # also a new secret key, printed once
```

With `--new-secret-key`, every other machine needs the new secret key at its next unlock. Neither change revokes old secrets from someone who copied the storage earlier: a versioned domain keeps the previous keyring among its versions.

## Telling vaults apart

With several domains, tsync's pickers show each vault in its own colour: the tsync icon, tinted. Every vault gets a colour from its key, the same on every machine. You can choose another, or give the vault an icon of its own, which then replaces the tsync icon:

```bash
tsync vault appearance --color "#0d9488"        # a colour of your choice
tsync vault appearance --icon work.png          # a square PNG, at most 256 pixels and 64 KiB
tsync vault appearance --default-color --no-icon
```

The colour and icon sync with the domain and show even while the vault is locked, so they are not encrypted: do not use a private image.

## Status and deleting

`tsync vault status` says whether the domain has a vault, whether it is unlocked here, and whether this machine is enrolled.

`tsync vault delete` removes the vault and everything in it, for every machine, after you type the domain's name to confirm. It asks for no passphrase: forgetting the passphrase is the reason to delete and start again. In a versioned domain the sealed records stay among the domain's versions until they expire.

## What the vault protects

- **The storage never holds a secret in clear.** Records, and the key that opens them, are sealed under your passphrase and secret key before upload.
- **Record names say nothing.** The vault lives in a hidden `/.tsync-ext/` folder of the domain, under random names.
- **Conflicts never lose a record.** Two machines changing the vault at once are reconciled into one set, with nothing dropped.
