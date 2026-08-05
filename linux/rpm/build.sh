#!/bin/sh
# Assembles dist/tsync-<version>.<dist>.<arch>.rpm from the binary
# linux/build.sh made. Run from the repo root.
set -eu

RUN_NUMBER=${RUN_NUMBER:-0}
src=$(pwd)
top=$(mktemp -d)

rpmbuild -bb linux/rpm/tsync.spec \
  --define "_topdir $top" \
  --define "srcdir $src" \
  --define "run_number $RUN_NUMBER"

mkdir -p dist
find "$top/RPMS" -name '*.rpm' -exec cp {} dist/ \;
rm -rf "$top"

for pkg in dist/*.rpm; do
  echo "== $pkg"
  rpm -qpi "$pkg"
  rpm -qpR "$pkg"
done
