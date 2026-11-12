#!/bin/sh
# What linux/deb/verify.sh and linux/rpm/verify.sh check alike, once the three
# packages are installed (linux-desktop §6.3). Each caller defines:
#   depends PACKAGE   the declared dependencies, one per line
#   files PACKAGE     the files the package lists, one per line
#   pinned PACKAGE    succeeds when PACKAGE depends on tsync at its own version
# Sourced, not run.

# The split: no bus or toolkit library on a headless machine, no file
# manager's toolkit beside a tray.
desktop='dbus|qt6|kf6'
if depends tsync | grep -Eiq "$desktop"; then
  echo "tsync depends on a desktop library" >&2; exit 1
fi
depends tsync-tray | grep -iq 'dbus'
if depends tsync-tray | grep -Eiq 'qt6|kf6'; then
  echo "tsync-tray depends on the file manager's toolkit" >&2; exit 1
fi
depends tsync-dolphin | grep -iq 'qt6'
depends tsync-dolphin | grep -iq 'kf6'
pinned tsync-tray
pinned tsync-dolphin

# The media helper alone links FFmpeg, and is where tsync looks for it.
ffmpeg='libav(codec|format|filter|util)|libswscale'
if depends tsync | grep -Eiq "$ffmpeg"; then
  echo "tsync depends on an FFmpeg library" >&2; exit 1
fi
if depends tsync-media | grep -Eiq "$desktop"; then
  echo "tsync-media depends on a desktop library" >&2; exit 1
fi
pinned tsync-media
files tsync-media | grep -qx '/usr/libexec/tsync/tsync-media'
if env -u LD_LIBRARY_PATH ldd /usr/bin/tsync | grep -Eiq "$ffmpeg"; then
  echo "the installed tsync loads FFmpeg" >&2; exit 1
fi
# A static FFmpeg shows in no dependency, but leaves its version tags.
if grep -aEq 'Lav[cf][0-9]{2}\.' /usr/bin/tsync; then
  echo "the installed tsync has FFmpeg linked in" >&2; exit 1
fi
tsync build-info | grep -Eq '^share previews: ffmpeg$'
printf '20\nthumbnail\nimage\n%s\n' "$(pwd)/lambda/share-card.png" \
  | /usr/libexec/tsync/tsync-media > /tmp/tsync-card.jpg
test "$(head -c 3 /tmp/tsync-card.jpg | od -An -tx1 | tr -d ' ')" = ffd8ff

# One file, one owning package.
for p in tsync tsync-media tsync-tray tsync-dolphin; do files "$p"; done | sort > /tmp/tsync-files
test -z "$(uniq -d /tmp/tsync-files)"
files tsync | grep -q '/tsync/libtsync_mounts\.so$'
test "$(grep -c 'libtsync_mounts' /tmp/tsync-files)" = 1
files tsync-tray | grep -qx '/usr/bin/tsync-tray'
files tsync-tray | grep -qx '/etc/xdg/autostart/tsync-tray.desktop'
for state in idle sync paused error; do
  files tsync-tray | grep -qx "/usr/share/icons/hicolor/symbolic/apps/tsync-$state-symbolic.svg"
done
# passwords/browser §2: tsync alone carries the browsers' manifests, each the
# installed tsync's own, naming itself.
rm -rf /tmp/tsync-manifests
tsync passwords browser manifest --path /usr/bin/tsync --root /tmp/tsync-manifests > /tmp/tsync-manifests.list
test -s /tmp/tsync-manifests.list
while read -r manifest; do
  files tsync | grep -qx "$manifest"
  test "$(grep -c "$manifest" /tmp/tsync-files)" = 1
  cmp "/tmp/tsync-manifests$manifest" "$manifest"
done < /tmp/tsync-manifests.list

# The startup list is where a user turns the tray off.
if grep -Eq '^(NoDisplay|Hidden)=' /etc/xdg/autostart/tsync-tray.desktop; then
  echo "the autostart entry is hidden" >&2; exit 1
fi

# The plugin is where the file manager scans, and its recorded search path
# is the installed library directory alone. ldd cannot tell: where this runs
# the build tree may still be there, and a path into it would resolve.
plugin=$(files tsync-dolphin | grep '/tsyncdolphin\.so$')
scanned=$(qtpaths6 --query QT_INSTALL_PLUGINS 2>/dev/null || qtpaths --qt=6 --query QT_INSTALL_PLUGINS)
test "$plugin" = "$scanned/kf6/kfileitemaction/tsyncdolphin.so"
library=$(files tsync | grep '/tsync/libtsync_mounts\.so$')
runpath=$(readelf -d "$plugin" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')
test "$runpath" = "$(dirname "$library")"
if env -u LD_LIBRARY_PATH ldd "$plugin" | grep 'not found'; then
  echo "the installed plugin does not resolve its libraries" >&2; exit 1
fi
env -u LD_LIBRARY_PATH ldd "$plugin" | grep -q "libtsync_mounts.so => $library"
# The name the loader searches by is the file's.
test "$(readelf -d "$library" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')" = libtsync_mounts.so

# The tray runs, and says why it leaves outside a session.
status=0
message=$(env -u DBUS_SESSION_BUS_ADDRESS -u XDG_RUNTIME_DIR tsync-tray 2>&1) || status=$?
test "$status" = 1
test "$message" = "tsync-tray: no session bus: the tray needs a running desktop session"
