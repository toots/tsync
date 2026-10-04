#!/bin/sh
# Installs the packages linux/deb/build.sh made and checks what an install in
# a build container can still get wrong. Run as root from the repo root.
set -eux

test "$(ls dist/*.deb | wc -l)" = 3
deb=$(ls dist/tsync_*.deb)
apt-get install -y ./dist/tsync_*.deb ./dist/tsync-tray_*.deb ./dist/tsync-dolphin_*.deb

# The release has the mount and both TLS implementations.
info=$(tsync build-info)
echo "$info" | grep -Eq '^frontends:.*\bfuse\b'
echo "$info" | grep -Eq '^tls:.*\bopenssl\b'
echo "$info" | grep -Eq '^tls:.*\bnative\b'

# ldd cannot fail here, where the -dev packages installed every library; the
# declared dependencies are what a clean machine gets. One name per line.
depends() {
  dpkg-deb -f dist/"$1"_*.deb Depends | tr ',' '\n' | sed 's/^ *//; s/ .*//'
}
files() {
  dpkg-deb -c dist/"$1"_*.deb | grep -v '/$' | sed 's/^.* \.\//\//; s/ -> .*//'
}
pinned() {
  dpkg-deb -f dist/"$1"_*.deb Depends | tr ',' '\n' \
    | grep -qx " *tsync (= $(dpkg-deb -f dist/"$1"_*.deb Version))"
}
# A library by its prefix, the fuse3 package by its whole name, which
# libfuse3 would otherwise satisfy.
for lib in libssl libfuse3 libgmp; do
  depends tsync | grep -q "^$lib"
done
depends tsync | grep -qx fuse3

. linux/packages-verify.sh

# The scripts no-op in a container, where /run/systemd/system is absent, so
# only their presence can be checked; and that the restart and the stop name
# the instances, since a template's own name is no unit systemd acts on.
for s in postinst prerm postrm; do
  dpkg-deb --ctrl-tarfile "$deb" | tar t | grep -q "\./$s"
done
test "$(dpkg-deb --ctrl-tarfile "$deb" | tar xO ./postinst ./prerm \
  | grep -c "'tsync@\*\.service'")" = 2
dpkg -L tsync | grep -q '/usr/lib/systemd/system/tsync@.service'
# The desktop packages run nothing at install or removal.
for p in tsync-tray tsync-dolphin; do
  test -z "$(dpkg-deb --ctrl-tarfile dist/"$p"_*.deb | tar t | grep -E 'postinst|prerm|postrm|preinst' || true)"
done
