# Extensions

This file is normative. It owns what an extension is: how it is built in or out, where its
records live in a domain, how concurrent changes to them settle, and how a host declares what it
can do for one. It does not own the encryption every extension's records share
([vault](vault.md)), the config keys that turn an extension on for a domain
([05 §2.1](../05-ops-config.md#21-schema-and-validation)), the reserved name in the domain tree
([01 §2.3](../01-core.md#23-leaf-names-and-logical-paths)), or the security rules for keys and
passphrases ([security-model §10.6](../algorithms/security-model.md#106-vault-keys-and-passphrases)).

Extensions: [totp](totp.md), [passwords](passwords.md).

---

## 1. Problem

Some small, secret, per-user data (one-time-password seeds, website and app passwords)
should follow the user across machines the way files do. A domain already moves data between
machines with history, offline edits and conflict handling. An extension reuses that, keeping
its records encrypted in a hidden folder of the domain, instead of building a second sync
channel.

## 2. Parts of an extension

| Part | Where it runs | Owns |
|---|---|---|
| **Records and fold** | the core, in the domain's owner | the record schema and the fold that settles conflicted copies (§4) |
| **Vault** | the core, shared by every extension of a domain | the data key, the keyring, record encryption ([vault](vault.md)) |
| **Host adapter** | the frontend host, optional | what this platform can do with the records (§5) |

An extension has a **name**: `1*( "a"–"z" | "0"–"9" )`, starting with a letter. `vault` is
reserved for the vault itself. A name is also the extension's CLI group (§6), so it MUST NOT be
a top-level command or a frontend's CLI group
([07 §5.3](../07-daemon-cli.md#53-commands), [08 §2.1](../08-frontends.md#21-frontend-descriptor)).

## 3. Opting in

- The vault and every extension are part of every build: they need nothing outside tsync's own
  sources.
- A domain's vault and records are part of the domain: they exist in its store once any client
  made them ([vault §3](vault.md#3-initialising)), whatever this client's config says.
- A client **uses** an extension of a domain when the domain's main states it and the client's
  config, if it lists `extensions` for the domain, lists it too; behind a main that states
  nothing, when the client's config lists it
  ([05 §2.1](../05-ops-config.md#21-schema-and-validation), rule 5). Behind an http-proxy the
  server decides: a client can only narrow its list, and one that leaves `extensions` out (the
  Android app) decides nothing. For a domain whose config lists
  none, this client runs nothing of this file: it writes nothing under `/.tsync-ext/`, folds
  nothing, and refuses every vault and extension verb `invalid`. The folder still syncs, hidden,
  like any other.
- `tsync build-info` lists the extensions.

## 4. Records

### 4.1 Where they live

- An extension's records are ordinary files of the domain, under `/.tsync-ext/<name>/` at the
  domain root. The vault's own files are under `/.tsync-ext/vault/`.
- They go through the log, the merge, projection, versions, replication and garbage collection
  like any file. Nothing below the file operations knows they are records.
- Each record is one file. Its leaf is a **record id**, `32hexlower`, drawn from the CSPRNG when
  the record is created ([01 §2.10](../01-core.md#210-random-identifiers)), unless the
  extension's spec derives it from the record under K, so that two machines adding the same
  thing meet at one name. A leaf never carries a user-visible label: names are not encrypted.
- Records are read through the read path
  ([04 §3.5](../04-checkout-cache.md#35-the-local-tree-full-and-lazy)). On a lazy tree, a verb or
  fold first pulls the folders it reads (`/.tsync-ext/vault/` and its extension's) and fetches
  each body it needs; a failed pull or fetch fails the verb, and leaves a fold for the next
  arrival. A verb never answers from a partial set of records.
- Every record body is a vault envelope ([vault §5](vault.md#5-record-envelope)). An extension
  never stores plaintext.

### 4.2 The fold

Two clients that change one record concurrently leave the winner at the record's name and the
other under a conflicted-copy name beside it
([conflict-resolution §5](../algorithms/conflict-resolution.md#5-conflicted-copy-name)). Each
extension declares a **fold**: given a record file and its conflicted copies, the changes that
settle them into one record (or, where both must survive, several).

- A fold MUST be a function of the names and bytes of the files it folds, and of nothing else
  (not the clock, not the client, not a random draw). Two clients that fold the same state then
  make the same changes, and the merge settles identical changes without a new conflict
  ([conflict-resolution §8.2](../algorithms/conflict-resolution.md#82-convergence)).
- A fold therefore never re-encrypts: an envelope carries a random nonce. It keeps one of the
  existing files by renaming it, removes the others, or writes bytes that depend only on its
  inputs (the keyring, [vault §4.3](vault.md#43-concurrent-changes)).
- A fold MUST NOT lose a record that a user could still need. Copies it removes MUST hold no
  information the kept file lacks, beyond what the extension's own spec names as superseded.
- The owner runs the fold before each verb that reads the extension's records, and after an
  unlock. A copy that arrives stays, hidden, until then: the fold depends on nothing but the
  files, so folding later settles the same. A fold that needs plaintext waits until the vault is
  unlocked.

### 4.3 The grouped fold

A fold most extensions share. The extension names its record's **key fields**: the ones a
concurrent change must never silently replace. A record id and its conflicted copies fold as:

1. Decrypt each file. A file that does not open is left as it is, and is in no group.
2. Group the files by their key fields. The **primary group** holds the file at the record id,
   or the greatest file (rule 3) when no file is there. When the file there does not open, there
   is no primary group: the record id keeps it, and every group goes to rule 5.
3. In each group the greatest file is the one with the highest `modified`; on a tie, the one
   whose body is bytewise greatest.
4. The primary group's greatest file is moved to the record id, unless it is already there, and
   every other file of the group is removed: they differ only in fields the newest change wins.
5. Each other group's greatest file is moved to the id `hex16(XXH3(body, 0)) hex16(XXH3(body, 1))`,
   the body's two digests ([01 §3.3](../01-core.md#33-other-digests-with-the-same-construction))
   written as 32 hex digits, and the rest of its group is removed. No key field is lost: the
   user sees two records and removes the wrong one.

A clock decides only between files that agree on every key field. The fold reads plaintext, so
it waits for an unlocked vault.

### 4.4 Hidden from users

`/.tsync-ext` is a reserved root name
([01 §2.3](../01-core.md#23-leaf-names-and-logical-paths)): every interface that presents the
domain's names to a user or another party omits it, and only the extension layer reaches it.

## 5. Host adapters

- A host adapter belongs to one extension and one host: `linux`, `macos` or `android`
  ([README §5](../README.md#5-hosts-one-core-several-compositions)). It runs in the owner and
  declares a set of **capabilities**, drawn from a vocabulary the extension's spec defines.
- An extension's spec is host-independent: it defines each capability, and what the extension
  does on a host that lacks it. Every capability is optional. Each host has its own spec,
  `extensions/<name>/<host>.md`, which owns what that host declares and how it realises it.
- Each declared capability carries an **interaction**: `silent` (no user gesture), `confirm` (the
  user approves, one gesture per call) or `authenticate` (the user proves who they are, once per
  item). Work an extension starts by itself runs in the background only through `silent`
  capabilities. Anything else waits for a command the user ran, or for the host's app in the
  foreground.
- A host declares a capability only once it has been seen working on that host, from the process
  that will run it. A capability not yet seen is listed in the host's spec as planned, and not
  declared.
- A command or action that needs a capability the host did not declare is refused INVALID
  (`invalid`), naming the capability. It is never attempted.
- An extension whose spec defines no capabilities has no host adapter, and every command of it
  works on every host.
- A host adapter is where an extension touches the platform. The record format and fold MUST NOT
  depend on which hosts have one.

## 6. Commands and actions

- An extension registers CLI verbs as `tsync <name> <verb>`, and request-handler actions named
  `<name>_<verb>` ([08 §3.3](../08-frontends.md#33-actions)). Every verb, the vault's included,
  is of access class **owner** and needs a **serving** owner
  ([07 §2.5](../07-daemon-cli.md#25-one-shot-commands)): K may live only in the owner's memory, so
  a command that took ownership for its run would lose it on exit. With no owner serving, a verb
  is refused UNREACHABLE (`unreachable`) and tells the user to start tsync.
- A verb that needs plaintext, on a domain whose vault is locked, is refused UNPREPARED/locked
  (`locked`, [failure-model §7.2](../algorithms/failure-model.md#72-client-error-codes)).
- Actions are per domain: an owner answers only for its own domain's vault.
- Verbs and actions return plaintext only where the extension's spec says so. Nothing an
  extension logs or reports contains plaintext (masking:
  [security-model §10.3](../algorithms/security-model.md#103-masking)).

### 6.1 Several domains

A user may use an extension on several domains, each with its own vault and passphrase. The
caller (the CLI, an app, a browser bridge) shows them as one: it asks each domain that uses the
extension, and merges the answers. Nothing is copied between vaults, and nothing is
deduplicated: the same login or seed in two domains is two entries, each indexed by its domain.
A record is named by the pair (domain, id).

- **Reads** (`list`, `match`) cover every domain that uses the extension, each row naming its
  domain. A domain whose vault is locked, or whose owner does not answer, is named in the reply
  with its error; the others still answer. The read is refused only when no domain answered,
  with the first domain's error.
- **Writes** of a new record go to one domain: `--domain` (`domain` in an action), else the only
  domain that uses the extension, else the default domain
  ([07 §5.3](../07-daemon-cli.md#53-commands)) when it uses it. Anything else is refused
  `invalid`, naming the candidates.
- **An id** given without a domain names the record of the one domain that holds it. An id held
  by several domains is refused `invalid` as ambiguous until `--domain` picks one.
- A record refers to records of its own domain only.

## 7. Conformance

- A client whose config lists no extension for a domain writes nothing under `/.tsync-ext/` of
  that domain, folds nothing there, and refuses every vault and extension verb on it `invalid`,
  while another client using that domain's vault goes on reading and writing it.
- Two domains each use `totp`, one vault locked: `totp list` lists the other's records, each
  naming its domain, and names the locked domain. One TOTP seed added to both domains lists
  twice, once per domain. `totp add` with no `--domain` and no default
  domain is refused, naming both. An id present in both is refused until `--domain` is given.
- A record's leaf is 32 lowercase hex and its body a vault envelope. No record leaf or body
  holds a plaintext label.
- Two clients edit one record concurrently and both fold: the domain settles with no conflicted
  copy left and no new one produced by the folding.
- A fold of a record whose copies need plaintext does nothing while the vault is locked, and
  settles them after unlock.
- A command needing an undeclared capability is refused `invalid` and has no effect.
- Work an extension starts by itself never calls a capability whose interaction is not
  `silent`.
- A grouped fold whose record id holds a body that does not open leaves that body in place and
  moves each group's newest copy to its digest id.
- An extension name equal to a top-level command or a frontend's CLI group is refused.
- On a lazy tree with the extension's records evicted, a listing verb fetches them and answers
  every record, or fails; it never answers a partial list.
- With no owner serving, every vault and extension verb is refused `unreachable` and writes
  nothing.
