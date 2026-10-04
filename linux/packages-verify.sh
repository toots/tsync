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

# One file, one owning package.
for p in tsync tsync-tray tsync-dolphin; do files "$p"; done | sort > /tmp/tsync-files
test -z "$(uniq -d /tmp/tsync-files)"
files tsync | grep -q '/tsync/libtsync_mounts\.so$'
test "$(grep -c 'libtsync_mounts' /tmp/tsync-files)" = 1
files tsync-tray | grep -qx '/usr/bin/tsync-tray'
files tsync-tray | grep -qx '/etc/xdg/autostart/tsync-tray.desktop'
for state in idle sync paused error; do
  files tsync-tray | grep -qx "/usr/share/icons/hicolor/symbolic/apps/tsync-$state-symbolic.svg"
done
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
