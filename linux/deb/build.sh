#!/bin/sh
# Assembles dist/tsync_<distro>_<arch>.deb and dist/tsync-tray_<distro>_<arch>.deb
# from the binaries linux/build.sh made. Run from the repo root, on the distro
# being targeted.
#
# Two packages, not one: the tray pulls libdbus and is useless without a desktop
# session, and a headless server installing tsync should get neither.
set -eu

RUN_NUMBER=${RUN_NUMBER:-0}
# Dated so a version says when it was built. The run number keeps same-day
# builds distinct, which is what apt compares to decide an upgrade.
DATE=${BUILD_DATE:-$(date -u +%Y%m%d)}

# Debian 13 and Ubuntu 26.04 otherwise produce identically named files, and the
# second one uploaded to the nightly release silently replaces the first.
. /etc/os-release
case "$ID" in
  debian) suffix="deb$VERSION_ID" ;;
  *) suffix="$ID$VERSION_ID" ;;
esac
version="0.0.0-${DATE}.${RUN_NUMBER}~${suffix}"

arch=$(dpkg --print-architecture)
stub=$(mktemp -d)
mkdir -p "$stub/debian"

# dpkg-shlibdeps rather than an ldd scan: ldd reports /lib/... while dpkg
# records /usr/lib/..., so under merged-/usr a `dpkg -S` lookup silently finds
# nothing. It also fills in the minimum-version constraints. Run per package, so
# each one asks for the libraries its own binary needs and no others -- which is
# the whole point of the split: libdbus lands on tsync-tray alone.
shlibdeps() {
  printf 'Source: tsync\n\nPackage: %s\nArchitecture: any\nDepends: ${shlibs:Depends}\nDescription: x\n' \
    "$1" > "$stub/debian/control"
  (cd "$stub" && dpkg-shlibdeps -O "$2") | sed 's/^shlibs:Depends=//'
}

# The name carries no version: the nightly release keeps one asset per package,
# distro and architecture, so uploading over it is the whole of the cleanup. The
# version is inside the package, which is where apt reads it.
emit() {
  name=$1 root=$2 deps=$3 blurb=$4
  mkdir -p "$root/DEBIAN"
  cat > "$root/DEBIAN/control" <<EOF
Package: $name
Version: $version
Architecture: $arch
Maintainer: Romain Beauxis <toots@rastageeks.org>
Depends: $deps
Section: utils
Priority: optional
Homepage: https://github.com/toots/tsync
Description: $blurb
EOF
  out="dist/${name}_${suffix}_${arch}.deb"
  dpkg-deb --build --root-owner-group "$root" "$out"
  dpkg-deb --info "$out"
  rm -rf "$root"
}

mkdir -p dist

# The daemon and the CLI. fuse3 is appended by hand -- fusermount3 is an exec,
# not a link, so nothing in the binary points at it.
root=$(mktemp -d)
install -Dm755 _build/default/bin/tsync.exe "$root/usr/bin/tsync"
strip "$root/usr/bin/tsync"
install -Dm644 'linux/tsync@.service' "$root/usr/lib/systemd/system/tsync@.service"
deps=$(shlibdeps tsync "$root/usr/bin/tsync")
test -n "$deps"
emit tsync "$root" "$deps, fuse3" 'Cloud-backed filesystem sync tool
 Mounts a cloud bucket as a local filesystem, storing files as
 content-addressed chunks so edits and duplicates upload once.'

# The tray. Pinned to the exact build of tsync it ships beside: the two speak
# over the IPC socket, and a mismatched pair is not something to discover at
# runtime.
tray=$(mktemp -d)
install -Dm755 _build/default/tray/main.exe "$tray/usr/bin/tsync-tray"
strip "$tray/usr/bin/tsync-tray"
mkdir -p "$tray/etc/xdg/autostart"
sed 's|@BIN@|/usr/bin/tsync-tray|' linux/tsync-tray.desktop.in \
  > "$tray/etc/xdg/autostart/tsync-tray.desktop"
chmod 644 "$tray/etc/xdg/autostart/tsync-tray.desktop"
# The .desktop names an icon and the tray asks for four more, so the package
# that ships them is the package that has to ship the icons. The suffix and the
# symbolic/ directory are a pair: together they are what makes GTK recolour to
# the panel foreground. Qt ignores both and recolours by the stylesheet the
# SVGs carry instead.
install -Dm644 assets/tsync-app.svg \
  "$tray/usr/share/icons/hicolor/scalable/apps/tsync.svg"
for state in idle sync paused error; do
    install -Dm644 "assets/tray/tsync-$state-symbolic.svg" \
      "$tray/usr/share/icons/hicolor/symbolic/apps/tsync-$state-symbolic.svg"
done
tray_deps=$(shlibdeps tsync-tray "$tray/usr/bin/tsync-tray")
test -n "$tray_deps"
emit tsync-tray "$tray" "$tray_deps, tsync (= $version)" 'Sync status in the system tray
 Shows what each tsync domain is doing in the desktop notification area,
 with a menu listing the files in flight and a switch that pauses uploads.'

rm -rf "$stub"
