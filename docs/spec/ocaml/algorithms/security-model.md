# Security model — OCaml implementation notes

Companion to [../../algorithms/security-model.md](../../algorithms/security-model.md). Where each mechanism lives in the OCaml tree, and where the code at the spec snapshot falls short of the spec. Paths are relative to the repository root.

## Where the mechanisms live

| Spec section | Code |
|---|---|
| §4 signature, freshness | `lib/backends/api/http_proxy.ml` (`Auth.canonical`, `sign`, `verify`, `max_skew = 300.`); constant-time compare is `Eqaf.equal` after a length check |
| §5.1 key and name validation | `lib/core/stored_key.ml` (`listed` is the constructor for a key a peer reported), `lib/core/logical_key.ml`, domain names in `lib/domain/config/parsing/conf_parsing.ml` |
| §5.2 route confinement | `within`, `op_keys`, `route_for` in `lib/app/frontends/http_proxy/http_proxy_frontend.ml` |
| §5.3 filesystem stores | `resolve` in `lib/backends/drivers/local/local_backend.ml` |
| §6 shares | `lib/domain/ops/share.ml` (`create`, `clear_cache`, token from `Id.token 16`), `lib/app/cli/cmd_share.ml`, `lib/app/frontends/http_proxy/share_server.ml`, `lambda/handler.py` (`load_share`) |
| §7 sockets | `lib/core/ipc.ml` (`serve` creates the parent `0o700` via `Fs.mkdir_p_sync ~perm`); staging and dest in `lib/app/cli/runner/daemon/engine/ipc_handler.ml` (`handle_write`, `ensure_cached`, `fetch_range`) and `lib/domain/checkout/content/data.ml` |
| §8 FUSE | `lib/app/frontends/fuse/fuse_frontend.ml` (`allowOther` option), `fuse_fs.ml` (`mount ~allow_other`) |
| §10 secrets | `lib/app/wizard/wizard.ml` (config write), `field_spec.ml` (masking) |
| §13 HTML | `share_server.ml` (browse page substitution), `lambda/browse.html`, `lib/app/frontends/http_proxy/stats.html` |

## Gaps at the spec snapshot

Each is a place the code does not yet meet the spec. They are listed so a reader of the code is not misled by it.

- **Key traversal (§5.1, §5.3).** `within` checks only that a key starts with a route root; `Stored_key.listed` is the identity; the local driver's `resolve` joins the key onto its root without normalising. A signed `tsync/<d>/../../<path>` reads, writes and deletes outside the store with the listener's privileges (reproduced). Keys copied between stores by mirror, backfill and GC go through the same unchecked join.
- **Domain names (§5.1).** Not validated; `shares`, `corrupted`, `verify-jobs`, `gc-jobs`, `/` and `..` break prefix confinement.
- **Unserved domain and bad signature** answer 404 `unknown domain` and 401 respectively, so domain names can be enumerated.
- **Share space (§6.4).** Share-prefix keys route to any verifying route with no check of the manifest's `domain`: any domain's secret can list, read, overwrite and delete every manifest in its store. The lambda handler does not check a file share's `key` against its `domain`. `tsync share --token` accepts any non-empty hex and overwrites with a plain put; there is no revoke; expired manifests are never deleted.
- **Browse page (§13).** `__SHARE_DATA__` is `Yojson.Safe.to_string` (and `json.dumps` in the lambda) inside `<script>`, unescaped; the `__OG_*` substitutions run first, so a title containing a placeholder is substituted again. Shared files are served inline without a sandbox CSP.
- **Status (§10.4, §12).** `/stats` accepts any route's secret and reports every domain. `stats.html` keeps the secret in `sessionStorage` under `tsync-secret` and carries a JS SHA-256/HMAC fallback for non-secure contexts.
- **Limits (§11).** `Cohttp_lwt.Body.to_bigstring` reads the whole body before routing, authentication and admission; there is no header, idle or keep-alive timeout and no connection cap; share responses and the ZIP member list are unbounded.
- **Sockets (§7).** Only `Ipc.serve` creates the socket directory `0o700`; the durable queue can create it first with `0o755`. Socket files are created under the process umask. No peer-credential check.
- **Confused deputy (§7.3).** `staging` and `dest` are used as given; `dest` is opened `O_WRONLY|O_CREAT` without `O_EXCL` or `O_NOFOLLOW`.
- **FUSE (§8).** `allow_other` is passed without `default_permissions`; no caller check.
- **TLS (§9).** `http://` is accepted for any host; the listener binds all interfaces; no `ca_certificate`. Android permits cleartext and builds its CA bundle once.
- **Secrets (§10).** No generation or length check. The wizard writes `config.json` then `Unix.chmod path 0o600` (`wizard.ml:881`). Masking in `field_spec.ml` masks only fields the spec marks secret, so unknown fields print in clear. Android Auto Backup copies the config.
