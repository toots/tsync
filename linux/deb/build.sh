#!/bin/sh
# Assembles dist/tsync_<distro>_<arch>.deb from the binary linux/build.sh made.
# Run from the repo root, on the distro being targeted.
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

root=$(mktemp -d)
stub=$(mktemp -d)
trap 'rm -rf "$root" "$stub"' EXIT

install -Dm755 _build/default/bin/tsync.exe "$root/usr/bin/tsync"
strip "$root/usr/bin/tsync"
install -Dm644 'linux/tsync@.service' "$root/usr/lib/systemd/system/tsync@.service"
install -Dm644 assets/tsync-app.svg "$root/usr/share/icons/hicolor/scalable/apps/tsync.svg"
for script in postinst prerm postrm; do
  install -Dm755 "linux/deb/$script" "$root/DEBIAN/$script"
done

# dpkg-shlibdeps rather than an ldd scan: ldd reports /lib/... while dpkg
# records /usr/lib/..., so under merged /usr a `dpkg -S` lookup finds nothing.
# It fills in the minimum versions too.
mkdir -p "$stub/debian"
printf 'Source: tsync\n\nPackage: tsync\nArchitecture: any\nDepends: ${shlibs:Depends}\nDescription: x\n' \
  > "$stub/debian/control"
deps=$( (cd "$stub" && dpkg-shlibdeps -O "$root/usr/bin/tsync") | sed 's/^shlibs:Depends=//')
test -n "$deps"

# fuse3 by hand: fusermount3 is executed, not linked, so nothing in the binary
# names it.
cat > "$root/DEBIAN/control" <<CONTROL
Package: tsync
Version: $version
Architecture: $arch
Maintainer: Romain Beauxis <toots@rastageeks.org>
Depends: $deps, fuse3
Section: utils
Priority: optional
Homepage: https://github.com/toots/tsync
Description: Synchronise folders through object stores
 Keeps folders in step across machines through cloud buckets or a peer,
 storing files as content-addressed chunks so edits and duplicates upload
 once, and mounts them with FUSE.
CONTROL

# No version in the name: the nightly release keeps one asset per distro and
# architecture, so uploading over it is the whole of the cleanup.
mkdir -p dist
out="dist/tsync_${suffix}_${arch}.deb"
dpkg-deb --build --root-owner-group "$root" "$out"
dpkg-deb --info "$out"
