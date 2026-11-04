# macOS, Windows and the Linux desktop

## macOS

**Finder.** The domain is a location in the sidebar. A cloud badge marks files that are online-only. Right-click for *Make Available Offline*, *Make Online Only* and *Copy Share URL*. Finder's own *Download Now* and *Remove Download* work too, but they do not keep a file offline for you: the system may remove such a download when it wants space.

**Menu bar.** The icon shows idle, transferring, paused or unreachable. The menu lists each domain with the files moving now; clicking a domain opens it and clicking a file reveals it in Finder. *Stats* is a short form of `tsync status`, and *Hold changes* is `tsync pause` for every domain. *One-time codes* copies a two-factor code from the [vault](passwords.md#two-factor-codes), and unlocks it when it is locked. With passwords in the vault, tsync also fills logins, codes and passkeys through [AutoFill](passwords.md#autofill-on-macos). There is no Quit: the app is what tells Finder about changes made elsewhere.

**Editing large files.** Finder hands tsync a whole file after an edit, so the whole file is read again. Only the chunks that changed are uploaded.

**Repairs**

```bash
tsync fileprovider reimport   # Finder is missing items
tsync fileprovider reset      # Finder shows items that no longer exist
```

`reimport` has the system list the whole domain again. `reset` removes the domain from the system and adds it back, which is the thorough fix. Edits Finder had not handed over yet are preserved, and the menu says where.

**Uninstall**

```bash
tsync fileprovider purge
```

It unregisters the domains, stops the service, and removes the app and the data directory. `config.json` stays, so installing again picks up where you were. If it cannot remove the `/usr/local/bin/tsync` link, it prints the command that does.

## Windows

**Explorer.** Each domain is a folder, `%USERPROFILE%\tsync\<domain>` unless its [`syncRoot`](config.md#frontend-options) says otherwise, registered with Windows the way OneDrive's is. The *Status* column shows a cloud for a file that is online-only and a check for one on this PC. Right-click for *Always keep on this device*, which downloads a file or a whole folder and keeps it, and *Free up space*, which makes it online-only again. Opening an online-only file downloads it first. There is no share link entry: use `tsync share`.

A link stored by another machine is not shown in the folder, and a link you put in the folder is skipped: Windows has no place for one in a cloud folder.

**Editing large files.** As on macOS, tsync reads a changed file whole, and uploads only the chunks that changed.

### Windows tray

The tray shows an icon in the notification area, light or dark to suit the taskbar, for idle, transferring, paused or unreachable. Click it for the same menu as on Linux:

- Clicking a domain opens its folder in Explorer. Clicking a file opens its folder with the file selected; it never opens the file.
- *Stats* is a short form of `tsync status`, read when you open the menu.
- *Hold changes* is `tsync pause` for every domain.
- *One-time codes* appears for a domain that uses `totp`. Clicking a code copies it, marked so that clipboard history and the cloud clipboard keep no copy. A locked domain's *Locked — unlock…* asks for the passphrase in a small window, and for the vault's secret key the first time on this PC.
- Messages, such as a code that could not be copied, appear as notifications from the icon.
- *Quit* closes the tray only. Syncing continues.

Setup starts the tray at sign-in. To turn that off, switch off *tsync-tray* in *Settings → Apps → Startup*. To start it again by hand, run `tsync-tray`. Its warnings go to `%LOCALAPPDATA%\tsync\logs\tray.log`.

### Repairs

```powershell
tsync cloudfiles reimport   # Explorer is missing items, or shows ones that are gone
tsync cloudfiles reset      # rebuild the folder from the domain
```

`reimport` compares the folder with the domain and changes what differs. `reset` empties the folder and lets it fill again from the domain as you browse it; it is refused while the folder holds a change the domain does not have yet, so nothing is lost.

### Uninstall

Uninstall from *Settings → Apps → Installed apps → tsync*. Each folder is released from Windows: files that were on disk stay as plain files, files that were only in the cloud are removed, and the folder itself stays. Your config stays in `%LOCALAPPDATA%\tsync\config.json`. If something could not be released, it is listed in `%TEMP%\tsync-purge.err`.

## Linux desktop

### Tray

`tsync-tray` shows an icon for idle, transferring, paused or unreachable, and a menu:

```
photos — Uploading 1 · Downloading 2
    out.raw
    holiday.mov
        752.0 MiB of 14.5 GiB · 1.5 MiB/s · 2h 34m left
---
1.2 GiB sent · 300.0 MiB to go
---
Stats >
[ ] Hold changes
---
Quit tsync tray
```

- Clicking a domain opens its folder. Clicking a file shows it in the file manager; it never opens the file.
- *Stats* is a short form of `tsync status`, read when you open it.
- *Hold changes* is `tsync pause` for every domain. The checkmark shows what the service reports, not what you clicked.
- *One-time codes* appears for a domain that uses `totp`, whether its config lists it or the server it follows does, on Wayland with `wl-copy` (wl-clipboard) installed. It lists each code by `issuer — account`, with its vault's colour or icon; clicking one copies its current code, marked so Klipper keeps no history of it. A locked domain's *Locked — unlock…* asks for the passphrase in KDE's dialog (`kdialog`). Codes are added with `tsync totp add`.
- *Quit* closes the tray only. Syncing continues.

The package starts the tray with your desktop session. To turn that off, use your desktop's autostart settings, or:

```bash
cp /etc/xdg/autostart/tsync-tray.desktop ~/.config/autostart/
echo 'Hidden=true' >> ~/.config/autostart/tsync-tray.desktop
```

The tray uses the StatusNotifierItem protocol, which KDE Plasma, XFCE, Cinnamon and LXQt display as is, under X11 and Wayland. **GNOME does not**: install the *AppIndicator and KStatusNotifierItem Support* extension (`gnome-shell-extension-appindicator`) and log in again. Without it the tray runs and nothing draws it.

`tsync-tray -v` in a terminal says what it found.

### Dolphin

`tsync-dolphin` adds entries to the context menu of a single file or folder inside a tsync folder:

| Entry | Does |
|---|---|
| *Copy Share Link* | Puts a link on the clipboard and says when it expires |
| *Make Available Offline* | Downloads and keeps it, for 10 days |
| *Keep Offline Longer* | Shown for a file already kept offline; extends it |
| *Make Online Only* | Frees the local copy |

The result arrives as a desktop notification. On a folder the work may take a while and continues if you close Dolphin; the tray shows its progress.

### Shell completion

A source install (`make install`) sets up completion for bash and zsh, and prints where it put it.
