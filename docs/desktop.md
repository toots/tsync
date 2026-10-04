# macOS and the Linux desktop

## macOS

**Finder.** The domain is a location in the sidebar. A cloud badge marks files that are online-only. Right-click for *Make Available Offline*, *Make Online Only* and *Copy Share URL*. Finder's own *Download Now* and *Remove Download* work too, but they do not keep a file offline for you: the system may remove such a download when it wants space.

**Menu bar.** The icon shows idle, transferring, paused or unreachable. The menu lists each domain with the files moving now; clicking a domain opens it and clicking a file reveals it in Finder. *Stats* is a short form of `tsync status`, and *Hold changes* is `tsync pause` for every domain. There is no Quit: the app is what tells Finder about changes made elsewhere.

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
