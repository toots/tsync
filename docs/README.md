# tsync documentation

tsync presents storage you control as a folder that downloads a file only when it is opened. There are two ways to set it up, and the choice shapes everything after it:

- **Direct.** Each machine talks to the storage itself: a bucket, a disk, a mounted NAS. Every machine holds the storage's credentials. This is the simplest setup for one or two computers.
- **Through a server.** One machine runs tsync next to the storage and serves it over HTTPS. Every other machine, phones included, connects to that server with one shared secret. Storage credentials, extra copies and share links are set up once, on the server.

```
Direct                               Through a server

laptop  ──┐                          laptop  ──┐
desktop ──┼──▶  bucket or disk       desktop ──┼──▶  tsync server  ──▶  bucket or disk
                                     phone   ──┘
```

Both are the same program and the same config file. A server is a domain with an `http-proxy` frontend; its clients are domains with an `http-proxy` backend. You can start direct on one machine and put a server in front later without moving any data.

## Start here

| Page | What it covers |
|---|---|
| [Install](install.md) | macOS, Linux packages, Android, building from source |
| [Getting started](getting-started.md) | Configure a first domain, start the service, put files in, day-to-day use |

## Going further

| Page | What it covers |
|---|---|
| [Add a second machine](machines.md) | Sharing a domain between machines, and what happens when they change the same thing |
| [Run tsync as a server](server.md) | The `http-proxy` frontend and backend, reverse proxies, checking on a server |
| [Use it from an Android phone](android.md) | The app: setup, files, camera backup |
| [Keep more than one copy](copies.md) | Backend roles, replicas and backfills, `tsync mirror`, data integrity |
| [Versions, trash and cleanup](history.md) | Reverting files, restoring folders, `expire` and `gc` |
| [Share links and export](sharing.md) | Public links, and getting files out of a domain |
| [Tuning](tuning.md) | Chunk sizes, the cache, concurrency, upload pacing |

## Reference

| Page | What it covers |
|---|---|
| [Config reference](config.md) | Every key of the config file, backend types, frontend options, paths, TLS |
| [Command reference](commands.md) | Every command, the status report, logs |
| [macOS and the Linux desktop](desktop.md) | Finder and the menu bar; the tray and the Dolphin plugin |
| [Troubleshooting](troubleshooting.md) | Symptoms and what to try |

Provisioning a bucket for tsync on AWS or Google Cloud: [terraform/README.md](../terraform/README.md).

[spec/](spec/README.md) is for people working on tsync itself: the specification it is built from, with the known [pitfalls](spec/pitfalls/README.md) and past [reviews](spec/review/) beside it.
