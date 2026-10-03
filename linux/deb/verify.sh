#!/bin/sh
# Installs the package linux/deb/build.sh made and checks what an install in a
# build container can still get wrong. Run as root from the repo root.
set -eux

deb=$(ls dist/tsync_*.deb)
apt-get install -y "./$deb"

# The release has the mount and both TLS implementations.
info=$(tsync build-info)
echo "$info" | grep -Eq '^frontends:.*\bfuse\b'
echo "$info" | grep -Eq '^tls:.*\bopenssl\b'
echo "$info" | grep -Eq '^tls:.*\bnative\b'

# ldd cannot fail here, where the -dev packages installed every library; the
# declared dependencies are what a clean machine gets.
depends=$(dpkg-deb -f "$deb" Depends)
for lib in libssl libfuse3 libgmp fuse3; do
  echo "$depends" | grep -q "$lib"
done

# The scripts no-op in a container, where /run/systemd/system is absent, so
# only their presence can be checked; and that the restart and the stop name
# the instances, since a template's own name is no unit systemd acts on.
for s in postinst prerm postrm; do
  dpkg-deb --ctrl-tarfile "$deb" | tar t | grep -q "\./$s"
done
test "$(dpkg-deb --ctrl-tarfile "$deb" | tar xO ./postinst ./prerm \
  | grep -c "'tsync@\*\.service'")" = 2
dpkg -L tsync | grep -q '/usr/lib/systemd/system/tsync@.service'
