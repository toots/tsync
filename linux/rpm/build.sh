#!/bin/sh
# Assembles dist/tsync_<dist>_<arch>.rpm from the binary linux/build.sh made.
# Run from the repo root.
set -eu

RUN_NUMBER=${RUN_NUMBER:-0}
# Dated so a version says when it was built; the run number keeps same-day
# builds distinct, which is what dnf compares to decide an upgrade.
DATE=${BUILD_DATE:-$(date -u +%Y%m%d)}
src=$(pwd)
top=$(mktemp -d)

rpmbuild -bb linux/rpm/tsync.spec \
  --define "_topdir $top" \
  --define "srcdir $src" \
  --define "build_release ${DATE}.${RUN_NUMBER}"

# Named without a version: the nightly release keeps one asset per package,
# distro and architecture, so uploading over it is the whole of the cleanup. The
# package name is part of it -- the build emits tsync and tsync-tray, and
# without it the second would be copied over the first.
mkdir -p dist
distro=$(rpm --eval '%{?dist}' | sed 's/^\.//')
find "$top/RPMS" -name '*.rpm' | while read -r f; do
  cp "$f" "dist/$(rpm -qp --qf '%{NAME}' "$f")_${distro}_$(rpm -qp --qf '%{ARCH}' "$f").rpm"
done
rm -rf "$top"

for pkg in dist/*.rpm; do
  echo "== $pkg"
  rpm -qpi "$pkg"
  rpm -qpR "$pkg"
done
