# Config reference

## Config file

One JSON object. `tsync build-info` prints its location. Keys that are not listed here are refused.

**Top level**

| Key | Required | Default | Meaning |
|---|---|---|---|
| `domains` | yes | | The list of domains |
| `name` | no | the hostname | This machine's name, used in conflicted copies |
| `maxUploads` | no | 4 | See [concurrency](tuning.md#concurrency) |
| `maxChunkBuffers` | no | `maxUploads` | |
| `maxDownloads` | no | 8 | |
| `uplink` | no | | See [uplink](tuning.md#uplink) |
| `links` | no | | Per-link overrides of `uplink`. Naming a link no backend uses is refused. |
| `tls` | no | `openssl` if built in | `"openssl"` or `"native"`. See [TLS](#tls). |

**Domain**

| Key | Required | Default | Meaning |
|---|---|---|---|
| `name` | yes | | The domain's name, and its folder's. Unique, ignoring case. No `/`. |
| `backends` | yes | | See below, and [backend types](#backend-types) |
| `frontends` | yes | | At least one. See [frontend options](#frontend-options). |
| `symlinks` | yes | | `"keep"`, `"follow"` or `"skip"`. See [symlinks](#symlinks). |
| `versioning` | yes | | Keep previous versions |
| `readOnly` | no | `false` | Refuse local writes. Forced on when no backend is a `main`. |
| `chunkSize` | no | the main's, else 8 MiB | 256 KiB to 256 MiB |
| `cacheChunkSize` | no | 16 MiB | |
| `maxCache` | no | unlimited | The wizard writes 1 GiB |

**Backend**

| Key | Required | Meaning |
|---|---|---|
| `type` | yes | `s3`, `gcs`, `local` or `http-proxy` |
| `name` | yes | Your label. Unique in the domain, ignoring case. No `/`. |
| `role` | yes | `main`, `replica`, `backfill` or `readOnly`. See [keep more than one copy](copies.md). |
| `link` | no | Remote stores only; default `wan`. See [uplink](tuning.md#uplink). |
| others | | The type's own fields, below |

**Values**

- **Sizes** are a number of bytes or a string with a unit in powers of 1024: `512K`, `8M`, `1.5 GiB`, `"8388608"`.
- **Booleans** are `true` and `false`; the strings `yes`, `no`, `on`, `off`, `1` and `0` are accepted too.
- **Durations** on the command line are a number and a unit: `30d`, `12h`, `45m`, `90s`.

### Symlinks

| `symlinks` | Importing a symlink | Creating one in the folder |
|---|---|---|
| `keep` | Stored as a symlink, dangling ones included | Allowed |
| `follow` | The target's content is stored under the link's name. A dangling link is skipped. | Refused |
| `skip` | Ignored, and counted in the summary | Refused |

A symlink another machine stored under `keep` is shown as a symlink everywhere.

## Backend types

**`s3`**

| Field | Required | Default | Meaning |
|---|---|---|---|
| `bucket` | yes | | |
| `accessKeyId` | yes | | |
| `secretAccessKey` | yes | | |
| `region` | no | `us-east-1` | |
| `endpoint` | no | AWS | For S3-compatible services: Backblaze B2, MinIO and others |
| `shareUrl` | no | | The share function's address. See [share links](sharing.md#share-links). |
| `unsignedPayload` | no | `false` | Skip hashing request bodies for the signature |
| `etagIsMd5` | no | `true` | Set to `false` for a service whose ETags are not MD5 sums. `tsync mirror` then compares by hashing. |

**`gcs`**

| Field | Required | Meaning |
|---|---|---|
| `bucket` | yes | |
| `serviceAccountKey` | yes | The service account's JSON key itself, as a string. Not a path to it. Leave out only for an emulator on localhost. |
| `endpoint` | no | For an emulator |
| `shareUrl` | no | The share function's address |

**`local`**

| Field | Required | Default | Meaning |
|---|---|---|---|
| `path` | yes | | A directory, absolute or starting with `~/`: another disk, a mounted NAS |
| `verifyWrites` | no | `true` | Re-read each chunk after writing it |

**`http-proxy`**

| Field | Required | Meaning |
|---|---|---|
| `url` | yes | A tsync server. `https://`, or `http://` for localhost only. |
| `secret` | yes | The server's secret for this domain, at least 32 characters |
| `ca_certificate` | no | A CA bundle to trust, for a private authority |

## Frontend options

A frontend is written as its name, `"fuse"`, or as an object with options, `{ "type": "fuse", … }`. A domain has at most one of `fuse` and `file_provider`, and may have `http-proxy` beside it.

**`fuse`** (Linux)

| Option | Default | Meaning |
|---|---|---|
| `mountPoint` | `~/tsync/<domain>` | An absolute path |
| `allowOther` | `false` | Let other users of the machine in. Needs `user_allow_other` in `/etc/fuse.conf`. |
| `uid`, `gid` | yours | The owner and group every entry shows, as a name or a number |
| `fileMode` | `"0644"` | The mode files show |
| `dirMode` | `"0755"` | The mode directories show |
| `mountSubtype` | `"sshfs"` | The filesystem type shown is `fuse.<this>` |

With `allowOther` and the default modes, other users can read and not write. A shared library that a group may write: `"gid": "media", "fileMode": "0664", "dirMode": "0775"`.

The mount calls itself `fuse.sshfs` on purpose. File managers generate a thumbnail for every file on a filesystem they take for local, which downloads the whole folder you are looking at. They leave `sshfs` alone. Set `"mountSubtype": "tsync"` if you want thumbnails.

**`file_provider`** (macOS) has no options.

**`http-proxy`**

| Option | Default | Meaning |
|---|---|---|
| `secret` | required | At least 32 characters |
| `port` | 443 with TLS, else 80 | |
| `ssl_certificate`, `ssl_certificate_key` | none | PEM files, absolute paths. Both or neither. |
| `bind` | every address with TLS, localhost without | Comma-separated addresses to listen on |
| `shares` | `false` | Serve share links for this domain |
| `readOnly` | `false` | Refuse writes from clients for this domain |
| `max_concurrent` | from the stores, else 16 | Reads and writes of data in progress at once |
| `max_connections` | | Open connections |
| `max_put_body` | 256 MiB | Largest upload request |
| `max_body_memory` | 1 GiB | Memory for request bodies, all requests together |
| `max_share_responses` | 64 | Share downloads at once |
| `max_zip_members` | 100000 | Largest folder a zip download takes |
| `idle_timeout`, `header_timeout`, `keepalive_timeout` | | Seconds |

**`android`** is what the Android app writes in its own config. `tsync start` refuses a config that names it.

## Files and paths

| | Linux | macOS |
|---|---|---|
| Config | `~/.config/tsync/config.json` | `~/Library/Group Containers/group.org.feverdreamtv.tsync/config.json` |
| Data | `~/.local/share/tsync` | `tsync/` beside the config |
| Cache | `~/.cache/tsync` | `cache/` inside the data directory |
| Folder | `~/tsync/<domain>` | under `~/Library/CloudStorage/` |

On Linux these follow `XDG_CONFIG_HOME`, `XDG_DATA_HOME` and `XDG_CACHE_HOME`.

The **cache** holds downloaded content and can be lost: it is fetched again. The **data** directory holds your edits that are not uploaded yet and the record of work in progress. Do not delete it while anything is pending in `tsync status`.

## TLS

tsync can use OpenSSL or a TLS implementation written in OCaml. The packages include both and use OpenSSL, which is faster.

Switch to the other one with `"tls": "native"` in the config, or `tsync start --tls native`. That is worth trying against a service OpenSSL has trouble with; Backblaze B2 has been one.

A source build has whichever you installed: the opam package `tsync-ssl` brings OpenSSL and `tsync-tls` the native one. `tsync build-info` lists them.
