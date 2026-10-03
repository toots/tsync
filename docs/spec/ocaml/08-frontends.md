# 08 — The frontend contract and the request handler — OCaml implementation notes

Companion to the spec [../08-frontends.md](../08-frontends.md). Not normative. Notes on one frontend
are in [fuse](frontends/fuse.md), [http-proxy](frontends/http-proxy.md),
[file-provider](frontends/file-provider.md) and [android](frontends/android.md); the processes that
host the handler are in [07-daemon-cli.md](07-daemon-cli.md).

## Where each part lives

| Spec | Code |
|---|---|
| Descriptor and registry (§2.1) | `Tsync_config.Frontend`: `register`, `find`, `names`, and `t` with `fields`, `presenting`, `commands_only`, `pulled`, `group`, `commands`. Each frontend's `*_options.ml` registers at module initialisation: `Fuse_options`, `Http_proxy_options`, `File_provider_options`, `Android_options`. |
| What is linked | `lib/catalog/dune`: a `select` per optional library whose two alternatives are empty files; every frontend library is `(library_flags (-linkall))`. `bin/dune` links `tsync_catalog`. |
| Hosting a presenting frontend (§3.1) | `Owner.present` (the hooks, and what presents once the socket serves), `Owner.host`, `register_host`, `host_for`. `Fuse_mount` and `File_provider_host` register one. |
| Item references (§2.2) | `Protocol.target` (`Ref`, `Rel`, `Child`); `Handler` `resolve_ref`, `resolve_rel`, `destination`, `target`; `Handler.path_of_ref`. |
| Item row (§2.3) | `Protocol.row`, `row_fields`, `row_of_fields`; `Handler` `row`, `row_or_unnamed`. |
| Error codes (§2.4) | `Fail.code`, `Ipc.failure`, `Protocol.failure_of_reply`. |
| Cursors and anchors (§2.5) | the engine's `cursor`; `Kept_walk.write`, `first_cursor`, `page`. |
| Hooks (§3.2) | `Handler.hooks`: `changed`, `reannounce`, `frontend`. `Owner` sets the engine's changed hook to `hooks.changed`. |
| Actions (§3.3) | `Protocol.request`, one constructor per action; `Protocol.action`, `mutates`, `bulk`, `refused_while_paused`; `Handler` `act`. |
| Evict and restore (§3.4) | `Protocol.Evict`, `Restore`; `Handler` `files_under`, `each_item`. |
| Rules (§3.5) | `Handler` `call_with`, `bounded`; the engine's `atomically`; `Transfer.check_dest`, `check_staging`. |
| Change feed (§3.6) | the engine's `changes_since`; `Handler` `feed_op`, `changes`. |
| Listings (§3.7) | `Handler` `list_dir`, `list_all`, `walk_domain`; `Kept_walk`. |
| Events (§3.8) | `Protocol.event`, `Handler.publish_event`, `event_json`, `note_reachability`; `Ipc.publish`. |
| A socket of several domains (§3.3) | `Owner` `route`, `shared_router`. |

## Where the code departs from the spec

- **Descriptor.** `Frontend.t` has no availability function and no access class per verb. Kind,
  topology, serving and tree are read from `presenting`, `commands_only` and `pulled`. A verb gets
  the resolved domain and its arguments, and takes ownership or asks the owner itself.
- **Hooks.** There is no `on_upload_done`, `status_fields`, `stats_fields` or `on_stop`. A frontend
  describes itself through `hooks.frontend ()`, a typed `Status_report.frontend`, from which `status`
  takes `mount`. `stop` is the `stop` function `Handler.create` is given, `Stop.request` in an owner.
- **Actions.** `prune` and `set_aside` do not exist. `stats` ignores its argument in an owner.
- **Jobs.** One per domain at a time ([07](07-daemon-cli.md)).
- **File-id index.** Every mutation waits for the index before the metadata hold, and `status`
  lists uploads with `bytes = 0`: both are in [frontends/file-provider.md](frontends/file-provider.md).

## Learnings

- **The request protocol is a GADT** (`Protocol`, `'a request` whose parameter is the reply's
  type). `Handler.call : t -> 'a request -> 'a` serves in-process callers and the one-shot fallback
  with no JSON at all, `Protocol.call` serves socket clients typed both ways, and `Handler.answer`
  is the only place a request is decoded. The codec is written by hand to keep §3.3's wire exactly;
  `tests/owner/protocol_test` round-trips every constructor.
- **The reply is bounded, the work is not** (`Handler` `bounded`): a request that is not bulk runs
  in a detached fiber and its caller waits `Ipc.request_deadline` on a promise, then answers
  DEADLINE while the work finishes for the next caller. `Ping`, `Stop` and bulk requests run inline.
- **An occupied destination travels as an exception carrying the occupant's row** (`Occupied`), so
  the `exists` reply nests its `item` at the socket and `Handler.call` re-raises the plain failure.
- **Event ids come from one process-wide `Atomic`** (`Handler` `event_ids`), whichever domain and
  whichever fiber publishes.
- **`pendingBytes` reads the whole WAL**, so `Handler` `pending_bytes` keeps the figure for 5 s:
  menus poll `status`.
- **Registration is a module initialiser, so linking is what enables a frontend.** `-linkall`
  keeps a library nobody references by name; the catalog's `select` makes an optional library a
  dependency only where it builds. `Daemon_cmds.frontend_cmds` reads the registry when the binary's
  own modules initialise, after every library's.
- **An optional library disappears without a failing build.** `tsync_fuse` is `(optional)` and
  `tsync_file_provider` is `enabled_if` macOS. What fails is the config parser, which refuses a
  type "unknown or not compiled into this build", and `linux/build.sh`, which requires
  `tsync build-info` to list `fuse`.
- **A host that needs the main thread runs the owner on another** (`Owner.host`): FUSE takes `run`
  and calls it from a thread of its own; File Provider calls it in place.
- **Foreign threads enter with `Rt.run_sync`**, which blocks only the calling thread: FUSE workers
  ([frontends/fuse.md](frontends/fuse.md)) and JNI threads
  ([frontends/android.md](frontends/android.md)) alike. Everything C calls is total.
- **Shared objects for desktop plugins.** None is built in this tree; the rules for when they are
  rebuilt are in [frontends/fuse.md](frontends/fuse.md).

## Tests

`tests/owner/{owner,shared,protocol}_test` (rows, mutations, refusals, the feed's and the walk's
stale answers, the shared socket's router), `tests/sync/{feed,file_ids}_test`,
`tests/android/lazy_test` for the handler on a pulled tree.
