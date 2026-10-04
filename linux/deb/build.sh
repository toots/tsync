#!/bin/sh
# Assembles dist/<package>_<distro>_<arch>.deb for tsync, tsync-tray and
# tsync-dolphin from what linux/build.sh made. Run from the repo root, on the
# distro being targeted.
set -eu

RUN_NUMBER=${RUN_NUMBER:-0}
# Dated so a version says when it was built; the run number keeps same-day
# builds distinct, which is what apt compares to decide an upgrade.
DATE=${BUILD_DATE:-$(date -u +%Y%m%d)}

# Debian 13 and Ubuntu 26.04 would otherwise produce the same file name, and
# the second upload to the nightly release would replace the first. setup.sh,
# written by linux/repo/build.sh, spells this rule again from a client's
# os-release.
. /etc/os-release
case "$ID" in
  debian) suffix="deb$VERSION_ID" ;;
  *) suffix="$ID$VERSION_ID" ;;
esac
version="0.0.0-${DATE}.${RUN_NUMBER}~${suffix}"
arch=$(dpkg --print-architecture)
libdir="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/stub/debian" dist
printf 'Source: tsync\n\nPackage: tsync\nArchitecture: any\nDepends: ${shlibs:Depends}\nDescription: x\n' \
  > "$work/stub/debian/control"

# dpkg-shlibdeps rather than an ldd scan: ldd reports /lib/... while dpkg
# records /usr/lib/..., so under merged /usr a `dpkg -S` lookup finds nothing.
# It fills in the minimum versions too. The discovery library belongs to no
# installed package, so the plugin's need of it is declared by hand, as the
# exact version of tsync.
shlibs() {
  (cd "$work/stub" && dpkg-shlibdeps -O -l"$work/tsync$libdir/tsync" \
    -xtsync --ignore-missing-info "$@") | sed 's/^shlibs:Depends=//'
}

# pack NAME DEPENDS SUMMARY DESCRIPTION: the tree at $work/NAME becomes
# dist/NAME_<distro>_<arch>.deb. No version in the name: the nightly release
# keeps one asset per package, distro and architecture, so uploading over it
# is the whole of the cleanup; the package name keeps the three apart.
pack() {
  mkdir -p "$work/$1/DEBIAN"
  cat > "$work/$1/DEBIAN/control" <<CONTROL
Package: $1
Version: $version
Architecture: $arch
Maintainer: Romain Beauxis <toots@rastageeks.org>
Depends: $2
Section: utils
Priority: optional
Homepage: https://github.com/toots/tsync
Description: $3
$4
CONTROL
  dpkg-deb --build --root-owner-group "$work/$1" "dist/$1_${suffix}_${arch}.deb"
  dpkg-deb --info "dist/$1_${suffix}_${arch}.deb"
}

root="$work/tsync"
install -Dm755 _build/default/bin/tsync.exe "$root/usr/bin/tsync"
strip "$root/usr/bin/tsync"
install -Dm644 _build/default/linux/mounts/libtsync_mounts.so \
  "$root$libdir/tsync/libtsync_mounts.so"
strip --strip-unneeded "$root$libdir/tsync/libtsync_mounts.so"
install -Dm644 'linux/tsync@.service' "$root/usr/lib/systemd/system/tsync@.service"
install -Dm644 assets/tsync-app.svg "$root/usr/share/icons/hicolor/scalable/apps/tsync.svg"
for script in postinst prerm postrm; do
  install -Dm755 "linux/deb/$script" "$root/DEBIAN/$script"
done
deps=$(shlibs "$root/usr/bin/tsync" "$root$libdir/tsync/libtsync_mounts.so")
test -n "$deps"
# fuse3 by hand: fusermount3 is executed, not linked, so nothing in the binary
# names it.
pack tsync "$deps, fuse3" "Synchronise folders through object stores" \
" Keeps folders in step across machines through cloud buckets or a peer,
 storing files as content-addressed chunks so edits and duplicates upload
 once, and mounts them with FUSE."

root="$work/tsync-tray"
install -Dm755 _build/default/linux/tray/tsync_tray.exe "$root/usr/bin/tsync-tray"
strip "$root/usr/bin/tsync-tray"
install -Dm644 linux/tsync-tray.desktop "$root/etc/xdg/autostart/tsync-tray.desktop"
for state in idle sync paused error; do
  install -Dm644 "assets/tray/tsync-$state-symbolic.svg" \
    "$root/usr/share/icons/hicolor/symbolic/apps/tsync-$state-symbolic.svg"
done
deps=$(shlibs "$root/usr/bin/tsync-tray")
test -n "$deps"
pack tsync-tray "$deps, tsync (= $version)" "Tray icon for tsync" \
" Shows the state of every tsync domain as an icon in the desktop's
 notification area, with a menu to open folders and hold changes."

root="$work/tsync-dolphin"
DESTDIR="$root" cmake --install linux/dolphin/build --strip
plugin=$(find "$root" -name tsyncdolphin.so)
test -n "$plugin"
deps=$(shlibs "$plugin")
test -n "$deps"
pack tsync-dolphin "$deps, tsync (= $version)" "Dolphin context menu for tsync" \
" Adds share links and offline availability to the context menu of files
 and folders in a tsync mount."
