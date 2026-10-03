# Backend driver: `local` — OCaml implementation notes

Companion to the language-neutral spec [../../backends/local.md](../../backends/local.md). See [README.md](../README.md) for how these notes are organised. Mappings and their memory: [../memory.md](../memory.md) §M.2.

Code: `lib/store/local.ml`, `local_path.ml`, `chunk_spaces.ml`, `corruption_marker.ml`; below them `Tsync_core.Fs`, `Dir_watch`, `Names`.

## Map

| Spec | Code |
|---|---|
| Fields (§2) | `Local.fields`: `path` (`Field_spec.absolute_or_home`), `verifyWrites`; `Local.expand_home` |
| Registration, linkless | the top-level `Driver.register "local"` with `linkless = true`; `Config.parse_backend` refuses `link` on it |
| Key to file, confinement (§3) | `Local_path.path`, `Local_path.check_no_links` (an `lstat` of every directory between root and key); reads open with `Fs.open_nofollow` |
| Temporary names (§3) | `Local.temp_name` (`.tsync-tmp-<Ids.short>.tmp`), opened `O_CREAT; O_EXCL`; `Names.is_temp_name` |
| Lock files omitted from listings (§3) | `is_gc_lock` |
| Durable write (§4) | `durable_write`: `mkdirs` (`Fs.mkdir_p`, fsyncing each created directory's parent), temporary, `Fs.fsync`, `Fs.rename`, `Fs.fsync_dir`; one retry on ABSENT |
| Claim (§4) | `create_new` (`Unix.link`, then `Fs.rename_noreplace` on `EPERM`, `EOPNOTSUPP`, `EMLINK`), `claim` (holder read back, 3 retries when it vanished) |
| Read (§4) | `read_opt`: `Fs.map_fd`, or `Fs.read_fd_bigstring` when `Fs.is_network_fs root` |
| Version name (§5.1) | `version`: device, inode, the bits of mtime and ctime, size |
| Key lock (§5.2) | `key_locks` (64 mutexes, by hash of the key), `with_key` |
| Conditional replace (§5) | `put_if_unchanged` in `Local.create` |
| Gate and chunk scoping (§6) | `Chunk_spaces.gate` around every `put`, claim, conditional replace and `copy`; `Chunk_spaces.read`, `list`, `twins` for chunk accesses during a run; `with_publish_lock`, `with_run_lock` |
| Watch (§8) | `watch` in `Local.create` over `Dir_watch.open_`, `wait`, `close`; one watcher per directory in a table under a mutex |
| Verified writes (§9) | `verify_written`, `Corruption_marker.body`, `Xxh.dual_bigstring` |
| Failure kinds (§10) | `Fail.kind_of_errno`, applied by `Fs.sys`; `fed` reports LINK failures to the store's `Health` |
| Network filesystems (§12) | `Fs.is_network_fs`, read through `mappable ()` |

## Departures

- **No local stall bound** (§10). A filesystem call runs on the calling fiber's thread with no deadline, so a hung mount holds that fiber and never fails LINK.
- **Temporaries in a store root are never swept** (§7). The listing walk skips them and removes none; the owner's daily sweep covers the checkout tree only (finding 122).
- **`fast_read` is `true` on a network filesystem too** (finding 148).
- **`max_concurrency` is always none**: the driver does not probe the device.
- **`delete_multi` takes the key lock around the unlink only**; the `lstat` that picks regular files runs before it.
- **`check_no_links` and the access are separate system calls**: a directory swapped for a link between them is followed. Reads open the final component with `Fs.open_nofollow`; writes rename or link onto it, which never follows a link there.

## Learnings

- **A mapped body faults instead of failing** (pitfall B-1.4). `mappable ()` asks `Fs.is_network_fs` on every read and keeps no answer, and `Fs.is_network_fs` answers `true` when it cannot tell: a store built before its mount appeared is not mapped once the mount is there.
- **Mapped chunks are not counted by the collector** (pitfall C-3.3, [memory.md](../memory.md) §M.2). The driver hands mappings out and releases nothing itself (finding 86); the composite's copy job and `Store_mirror` call `Fs.drop_mapped_pages` once a body is sent.
- **`verify_written` reads through `Chunk_spaces.read`**, the same path a later reader takes, never the argument. A failure to read becomes a marker with a `reason`; a mismatch never fails the `put`.
- **The key lock is taken inside the gate, never around it**: `Chunk_spaces.gate` may wait on the publish lock for 30 s, and holding a key lock across that would stall every writer hashing to the same slot.
- **64 striped mutexes, not one per key**: the lock table is fixed, so nothing has to be evicted. Two keys that share a slot serialise for the length of one write.
- **`Fun.protect ~finally` around the staged claim file** needs a finaliser that cannot raise (`Fs.unlink_quiet`); a raising one surfaces as `Finally_raised` and hides the claim's outcome.
- **The watch arms before it reads** and keeps its watcher across calls; `` `Gone `` drops the watcher so the next call reopens it. On a network filesystem no watcher is opened and the wait is `Rt.sleep Store.watch_interval`.
- **The publish lock file sits in the directory of the cursor**, so each manifest write wakes a watch on it (finding 138); `Dir_watch` filters temporary names only.
- **The run lock and the publish lock are two files** (pitfalls A-7.9, B-4.5). The run lock is a POSIX record lock (`Unix.lockf`), which the process loses when it closes any descriptor of that file; the publish lock is a `flock` opened and closed around every gated write, so it cannot share the file. Record locks of one process merge, so `with_run_lock` first claims the path in the `sessions` table under a mutex.
- **Tests.** `tests/store/local_test` runs the contract and the driver's own cases, `spaces_test` and the `gc_scoping` snapshot cover the chunk spaces, `watch_test` the watch. No test records the order of system calls, so fsync-before-publish is checked by reading the code.
