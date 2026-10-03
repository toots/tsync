# Security model — OCaml implementation notes

Companion to [../../algorithms/security-model.md](../../algorithms/security-model.md). Not normative.
Finding numbers refer to [the 2026-10-01 review](../../../review/2026-10-01-rewrite.md).

## Where the mechanisms live

| Spec section | Code |
|---|---|
| §4 signature, freshness | `Proxy_wire.verify` (constant-time `Eqaf.equal`), `Proxy_wire.fresh`, `max_clock_skew` (`lib/store/http_proxy/proxy_wire.ml`); `verifies`, `fresh`, `verified_routes` in `lib/frontends/http_proxy/store_server.ml` |
| §4.3 answers | `unauthorized`: one 401 for a bad signature and for a domain no route serves |
| §5.1 keys and names | `Key.t` and `Key.prefix` are private strings built only by the namers or by `Key.of_string` (`lib/core/key.ml`); the grammar is `Names.valid_key`, `valid_prefix`, `valid_leaf`, `valid_path`; `Domain_name.of_string` refuses reserved names (`Names.reserved_roots`) |
| §5.2 route confinement | `within`, `route_for`, `writable`, `share_candidates` (`store_server.ml`) |
| §5.3 filesystem stores | `Local_path.path`, `check_no_links`: no symbolic link between the root and the key; the local driver opens with `Fs.open_nofollow` |
| §6 shares | `Share.Make` (`create`, `revoke`, `clear_cache`; `lib/gc/share.ml`), token from `Ids.token`, `Key.share` accepts 1 to 128 lowercase hex; served by `Share_server` (`claims`, `manifest_domain`, `handle`); expiry in `Retention` |
| §7.1 socket directory and file | `Ipc.serve`: `check_dir` (0700, this uid), the socket bound under `umask 0o177` (`lib/ipc/ipc.ml`) |
| §7.2 peer credentials | `Fs.peer_uid` (`SO_PEERCRED`, `getpeereid` in `sys_stubs.c`), checked per connection |
| §7.3 paths over IPC | `Transfer.check_dest`, `check_staging` against the roots the host declares (`lib/owner/transfer.ml`); `Owner` defaults them to the user's home |
| §8 FUSE | `allowOther` always with `default_permissions`; `owner_only_writes` refuses other uids unless the configured modes grant others write (`lib/frontends/fuse/fuse_mount.ml`) |
| §9 TLS | `Transport.tls` (`host`, `ca_file`), `lib/http/native`, `lib/http/ssl`; `Field_spec.http_url` refuses `http://` to a host that is not loopback at config validation; `Transport.cleartext_loopback_only` on Android; a plaintext listener binds loopback unless `bind` says otherwise (`proxy_options.ml`) |
| §10.1 generation and strength | `Ids.secret` (32 bytes of `/dev/urandom`), `Field_spec.secret_length`, `min_secret_length` |
| §10.2 at rest | `Fs.durable_replace ~perm:0o600` from the wizard command (`bin/setup_cmds.ml`): the mode is set on the temporary; `Paths.read_config` refuses a config readable by group or other, or fixes it when interactive; `Fs.mkdir_p` creates 0700 |
| §10.3 masking | `Config.masked_fields`: a field is shown only when its `Field_spec` marks it non-secret |
| §10.4 in a browser | `status_page.html`: the secret in a variable only, Web Crypto, refused outside a secure context |
| §11 listener limits | `Server.limits` (`header_bytes`, `header_timeout`, `idle_timeout`, `keepalive_timeout`, `max_connections`; `lib/http/server.ml`); `Proxy_options.listener` (`max_put_body`, `max_bulk_body`, `max_body_memory`, `max_zip_members`); `admitted`, `body_deadline` |
| §12 status | `/stats` answers for `verified_routes` only: the domains whose secret signed the request |
| §13 HTML | `Share_server.script_json`, `fill`; `content-security-policy: sandbox` and `nosniff` on served files |

## Where the code departs from the spec

- **A listing is built whole, unpaged and outside admission** (finding 77): `list` of a chunk area
  holds every entry three times, and `max_keys` cuts after listing.
- **get-multi has no byte cap** (finding 78): up to the key bound of whole chunks in one frame, read
  eight at a time inside one data slot.
- **The data slot is released before the response body is written** (finding 79), so bodies in flight
  are bounded by the connection cap, not by the slots.
- **Share reads are outside the storage bound** (finding 81): a range request reads whole chunks, and
  the ZIP member walk is quadratic.
- **`umask` is process-wide** (finding 115). `Ipc.serve` narrows it around `bind`; a directory another
  domain creates in that window gets mode 0600.

## Learnings

- A key that comes from outside (a listing, a peer, a job record) passes `Key.of_string` or does not
  exist: the type is private, so no free string reaches a driver, and the local driver joins nothing
  it has not validated.
- A copy carries two names, so it escapes a check written for one. `share_candidates` gives no route
  to a copy or a bulk operation that names a share manifest, and a manifest write only to the route
  whose domain the body names (finding 6).
- One deadline is computed at accept and after each response; every read of the head and of the TLS
  handshake gets what is left of it. A timeout per read lets a client trickle a header for days
  (finding 29).
- A request's body is read and its signature verified before it takes a data slot, under a deadline
  sized from the declared length (`body_deadline`, finding 30).
- Staging and destination paths are checked through directories only (`check_under`); the host
  declares its roots, and a client's request adds none (finding 31).
- A mount point is normalised once at intake: compared as written, a stale mount under a trailing
  slash or a symlink is never found (finding 33).
