# 03 — Log and sync: formats and interfaces — OCaml implementation notes

Companion to [../03-journal-sync.md](../03-journal-sync.md). Not normative. The protocol is mapped in
[algorithms/publication.md](algorithms/publication.md), the merge's enactment in
[algorithms/conflict-resolution.md](algorithms/conflict-resolution.md), the local formats in
[04-checkout-cache.md](04-checkout-cache.md).

## Code map

| Spec concept | Code |
|---|---|
| Client uuid, folder-id leases (§2.1) | `Identity` (`lib/checkout`): `client_uuid`, `minter`, `mint` |
| Feed key (§2.2) | `Feed_key` (`lib/sync`): `parse`, `make`, `month`, `compare`; `minter` and `mint`, seeded from the applied log's head |
| Commands, log entry (§2.3–2.4) | `Log_entry` (`lib/core`); keys by `Key.log_entry`, `entry_number` |
| Cursor, tree head, takeover, void (§2.5–2.6) | `Log_store` (`lib/remote`); keys by `Key.cursor`, `tree_head`, `takeover`, `void` |
| Position, in-flight and arrival records, before-values (§2.7–2.8) | `Sync_state` |
| Feed ops, applied log (§2.9) | `Op`, `Applied`: `load`, `note`, `head`, `since`, `prune` |
| Upload records, local intents (§2.10) | `Local_ops.upload`, `upload_kind`, `encode_intent`, `decode_intent`; the logs are `Dqueue.Records` |
| Conflicted-copy name (§2.11) | `Conflict.name` |
| Log store (§3.1) | `Log_store` |
| Sync state (§3.2) | `Sync_state`; `committed` is `Cycle.won` |
| Applied log (§3.3) | `Applied` |
| Cycle (§3.4) | `Cycle`: `recover_local`, `arrive`, `arrive_by_state`, `push`, `project`, `request_cycle`; its status is `Engine.activity` |
| Upload queue (§3.5) | the `uploads` `Dqueue.t` of `Local_ops`, run by `Uploads.run_upload` |
| Merge (§3.6) | `Algebra.merge`; `Cycle.describe_clash` logs a clashed merge |
| Change feed over the applied log | `Engine`: `cursor`, `changes_since`, `prune_applied`; `Cycle.stamp_generation` |

## Departures from the spec

- **The arrival record names no feed key.** A record completed by recovery stamps a resync
  generation, as the spec says; the record has no `feed` field.
- **`clashed` is not a separate function.** `Cycle.describe_clash` reads the keys where the merge
  left a pending command, and logs them when it kept a file aside or restored a folder.
- **A before-value record is written with a directory fsync each**, also under an arrival that
  sets many: an arrival over a large pending set is slow.

## Learnings

- **`Feed_key.t` is a private string** whose only constructors are `parse` and `make`.
- **A before-value is `Identity`, a local value is `Known` or `Unknown`.** Comparing them goes
  through `Log_entry.equal` everywhere; a structural `=` on values would call a manifest and its
  identity different.
- **`Unknown` is not equal to itself**, so a command from an `Unknown` to the same `Unknown` is not
  null by `equal`. `Cycle.null` and the merge's local difference also accept physical equality.
