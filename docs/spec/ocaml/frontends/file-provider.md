# The macOS application (File Provider frontend) — implementation notes

Companion to the language-neutral spec [../../frontends/file-provider.md](../../frontends/file-provider.md). See [README.md](../README.md) for how these notes are organised. Section numbers in parentheses refer to the spec. The pitfalls met while building it are in [`docs/spec/pitfalls`](../../pitfalls/README.md).

## Where each part lives

| Spec | OCaml (the owner) | Swift (`macos/`) |
|---|---|---|
| Processes and the service (§2, §11) | `bin/daemon_cmds.ml` `macos_service`: one process owns every domain, takes the governor, keeps the store server running with the supervisor's restart loop, and opens its own log | `TsyncApp/AppDelegate.swift`: the login item; `install-agent.sh`: the per-user agent |
| Shared socket and router (§4.2, §8.1, §10) | `lib/owner/owner.ml` `serve ~shared`: one socket for every domain, possibly none; the router answers `subscribe`, `menu`, `menu_stats`, `pause` and `stop` without a domain; events also go to the `*` topic | `Shared/OwnerClient.swift`: one connection per request, deadlines, cancellation, the liveness probe for bulk requests, `Subscription` |
| Request handler (§4–§6) | `lib/owner/handler.ml`, `protocol.ml`; transfer paths by path rules alone (`transfer.ml`, no declared roots on the shared socket) | `TsyncFileProvider/TsyncExtension.swift`: one method per callback; `Owner.swift`: domain-scoped calls |
| File ids (§6.1) | `lib/checkout/mirror.ml`: markers, the in-memory id index, the backfill and its completion record; `lib/sync/*`: `fids` in the WAL, `fid` in the applied log | `Row.swift` `ItemRef` |
| Items and versions (§6.2–§6.4) | `handler.ml` `row` | `Item.swift`, `Row.swift` |
| Anchors, pages, the feed (§5, §7) | `lib/sync/engine.ml` `cursor`, `changes_since`, `prune_applied`; `lib/owner/kept_walk.ml` | `Enumerators.swift`, `Cursors.swift`, `ChangeBatch.swift` |
| Partial ranges, errors (§6.8, §6.10) | — | `PartialRange.swift`, `Errors.swift` |
| Events and the relay (§8) | `lib/frontends/file_provider/file_provider_host.ml`: the debounced `changed` | `TsyncApp/Relay.swift` |
| Registration (§9.1) | — | `TsyncApp/Reconciler.swift` |
| Reset, purge, reimport (§9.2–§9.4) | `lib/frontends/file_provider/file_provider_cli.ml` | — |
| Menu (§10) | `lib/menu/menu_model.ml`, the model of 07 §5.8, called by the shared router of `lib/owner/owner.ml` | `TsyncApp/StatusMenu.swift` |

## Where the code departs from the spec

- **Upload progress.** `status.uploading` lists the running uploads with `bytes = 0`: the upload
  queue does not count bytes per file, so the menu shows which files are uploading but not how far.
- **Rebuild durability.** A rebuild writes the last-sync mark after a `syncfs`, which macOS only
  schedules ([pitfall B-1.12](../../pitfalls/B-implementation.md)): a crash right after the mark
  can lose mirror entries until the next full resync.
- **File-id index wait.** Every mutation waits for the file-id index before the metadata hold, not
  only one naming an `i:` reference; it differs only while the index rebuilds after a crash. The
  test does not force a marker change during the build's walk, so the queue of changes made
  meanwhile is covered by review only.
- **Store-server restarts** reuse the supervisor's loop (`Supervisor.keep_running`), so the macOS
  service process restarts its store-server child with the supervisor's backoff.

## Tests

- OCaml: `tests/owner/{owner,shared,protocol,menu}_test.ml`, `tests/sync/{file_ids,feed,offline}_test.ml`.
- Swift: `macos/TsyncTests/SpecTests.swift` (`make test`), snapshots of the pure parts.
- Nothing drives the extension against the framework automatically; the checks made on a Mac are
  recorded in [the review](../../review/2026-10-02-macos-file-provider.md) §2.4.
