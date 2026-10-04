#!/bin/sh
# Installs the packages linux/rpm/build.sh made and checks what an install in
# a build container can still get wrong. Run as root from the repo root.
set -eux

test "$(ls dist/*.rpm | wc -l)" = 3
rpm=$(ls dist/tsync_*.rpm)
dnf install -y ./dist/tsync_*.rpm ./dist/tsync-tray_*.rpm ./dist/tsync-dolphin_*.rpm

# The release has the mount and both TLS implementations.
info=$(tsync build-info)
echo "$info" | grep -Eq '^frontends:.*\bfuse\b'
echo "$info" | grep -Eq '^tls:.*\bopenssl\b'
echo "$info" | grep -Eq '^tls:.*\bnative\b'

# ldd cannot fail here, where the -devel packages installed every library; the
# declared requirements are what a clean machine gets.
depends() {
  rpm -qpR dist/"$1"_*.rpm | sed 's/ .*//'
}
files() {
  rpm -qpl dist/"$1"_*.rpm
}
pinned() {
  rpm -qpR dist/"$1"_*.rpm \
    | grep -qx "tsync = $(rpm -qp --qf '%{VERSION}-%{RELEASE}' dist/"$1"_*.rpm)"
}
# A library by its prefix, the fuse3 package by its whole name, which
# libfuse3 would otherwise satisfy.
for lib in libssl libfuse3 libgmp; do
  depends tsync | grep -q "^$lib"
done
depends tsync | grep -qx fuse3

. linux/packages-verify.sh

# The scriptlets no-op in a container, where /run/systemd/system is absent, so
# only their presence can be checked; and that the restart and the stop name
# the instances, since a template's own name is no unit systemd acts on.
scripts=$(rpm -qp --scripts "$rpm")
for s in postinstall preuninstall; do
  echo "$scripts" | grep -q "^$s scriptlet"
done
test "$(echo "$scripts" | grep -c "'tsync@\*\.service'")" = 2
rpm -ql tsync | grep -q 'tsync@.service'
# The desktop packages run nothing at install or removal.
for p in tsync-tray tsync-dolphin; do
  test -z "$(rpm -qp --scripts dist/"$p"_*.rpm)"
done
