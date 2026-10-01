#!/bin/sh
# Assembles dist/tsync_<dist>_<arch>.rpm from the binary linux/build.sh made.
# Run from the repo root.
set -eu

RUN_NUMBER=${RUN_NUMBER:-0}
# Dated so a version says when it was built; the run number keeps same-day
# builds distinct, which is what dnf compares to decide an upgrade.
DATE=${BUILD_DATE:-$(date -u +%Y%m%d)}
top=$(mktemp -d)
trap 'rm -rf "$top"' EXIT

rpmbuild -bb linux/rpm/tsync.spec \
  --define "_topdir $top" \
  --define "srcdir $(pwd)" \
  --define "build_release ${DATE}.${RUN_NUMBER}"

# No version in the name: the nightly release keeps one asset per distro and
# architecture. setup.sh, written by linux/repo/build.sh, finds the directory
# this names by spelling fc$VERSION_ID.
mkdir -p dist
distro=$(rpm --eval '%{?dist}' | sed 's/^\.//')
for f in "$top"/RPMS/*/*.rpm; do
  out="dist/$(rpm -qp --qf '%{NAME}' "$f")_${distro}_$(rpm -qp --qf '%{ARCH}' "$f").rpm"
  cp "$f" "$out"
  rpm -qpi "$out"
  rpm -qpR "$out"
done
