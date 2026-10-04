# Troubleshooting


| Symptom | Try |
|---|---|
| The service does not start | `tsync logs`. A config error is printed with the place in the file. |
| "unknown key(s)" | A misspelled or misplaced key. The message gives its path. |
| "… is unknown or not compiled into this build" | `tsync build-info` lists what this binary has. A source build needs the library present when building. |
| A config change has no effect | Restart the service. See [start it](getting-started.md#start-it). |
| "multiple domains configured — use --domain to select" | Pass `--domain NAME`, or `tsync default-domain NAME`. |
| The folder is empty or missing | `tsync status`. Is the service running and the frontend listed? |
| The mount fails with `allowOther` | Add `user_allow_other` to `/etc/fuse.conf`. |
| A file will not open offline | It was online-only. While connected, `tsync cache --fetch PATH`, or *Make Available Offline* in the file manager. |
| Opening a folder downloads everything in it | Something is generating thumbnails. Keep `mountSubtype` at its default. |
| A file named "conflicted copy" appeared | Two machines changed the same name. Keep the one you want and delete the other. See [when two machines change the same thing](machines.md#when-two-machines-change-the-same-thing). |
| This machine does not show what another one did | `tsync sync`; if it still differs, `tsync sync --full`. |
| Finder disagrees with the store (macOS) | `tsync fileprovider reimport`, then `tsync fileprovider reset`. |
| A client gets "unauthorized" from a server | The secrets differ, the domain names differ, or the clocks are more than 5 minutes apart. |
| Uploads to a server fail behind nginx | Raise `client_max_body_size`. |
| A client refuses its server's `url` | It must be `https://`. |
| A command says "refusing to …: the main … is not online" | Intended: copies are not written while a main is down. Run it again when the main is back. |
| A replica or backfill is behind | Normal after an outage. `tsync status` shows how much is owed. |
| A copy shows `parked` work | Fix what `tsync status` or `tsync logs` reports, then `tsync retry`. |
| A copy is missing files from before it was added | `tsync mirror`. |
| `tsync gc` says there is nothing it can collect | It needs a `local` main on this machine. See [cleanup](history.md#cleanup). |
| Space is not freed after `expire` | `expire` forgets history; `tsync gc --apply` frees the space. |
| `tsync share` says sharing is not available | Nothing serves links. See [share links](sharing.md#share-links). |
| No tray icon on GNOME | Install `gnome-shell-extension-appindicator` and log in again. |
| No tray icon elsewhere | Run `tsync-tray -v` in a terminal. |
