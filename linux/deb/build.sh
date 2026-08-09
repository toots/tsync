#!/bin/sh
# Assembles dist/tsync_<distro>_<arch>.deb from the binary linux/build.sh made.
# Run from the repo root, on the distro being targeted.
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
root=$(mktemp -d)

install -Dm755 _build/default/bin/tsync.exe "$root/usr/bin/tsync"
strip "$root/usr/bin/tsync"
install -Dm644 'linux/tsync@.service' "$root/usr/lib/systemd/system/tsync@.service"

# dpkg-shlibdeps rather than an ldd scan: ldd reports /lib/... while dpkg
# records /usr/lib/..., so under merged-/usr a `dpkg -S` lookup silently finds
# nothing. It also fills in the minimum-version constraints. fuse3 is appended
# by hand — fusermount3 is an exec, not a link.
stub=$(mktemp -d)
mkdir -p "$stub/debian"
printf 'Source: tsync\n\nPackage: tsync\nArchitecture: any\nDepends: ${shlibs:Depends}\nDescription: x\n' \
  > "$stub/debian/control"
deps=$(cd "$stub" && dpkg-shlibdeps -O "$root/usr/bin/tsync" | sed 's/^shlibs:Depends=//')
test -n "$deps"

mkdir -p "$root/DEBIAN"
cat > "$root/DEBIAN/control" <<EOF
Package: tsync
Version: $version
Architecture: $arch
Maintainer: Romain Beauxis <toots@rastageeks.org>
Depends: $deps, fuse3
Section: utils
Priority: optional
Homepage: https://github.com/toots/tsync
Description: Cloud-backed filesystem sync tool
 Mounts a cloud bucket as a local filesystem, storing files as
 content-addressed chunks so edits and duplicates upload once.
EOF

mkdir -p dist
# The name carries no version: the nightly release keeps one asset per distro
# and architecture, so uploading over it is the whole of the cleanup. The
# version is inside the package, which is where apt reads it.
out="dist/tsync_${suffix}_${arch}.deb"
dpkg-deb --build --root-owner-group "$root" "$out"
dpkg-deb --info "$out"
rm -rf "$root" "$stub"
