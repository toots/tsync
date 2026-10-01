#!/bin/sh
# Installs the package linux/rpm/build.sh made and checks what an install in a
# build container can still get wrong. Run as root from the repo root.
set -eux

rpm=$(ls dist/tsync_*.rpm)
dnf install -y "./$rpm"

# The release has the mount and both TLS implementations.
info=$(tsync build-info)
echo "$info" | grep -Eq '^frontends:.*\bfuse\b'
echo "$info" | grep -Eq '^tls:.*\bopenssl\b'
echo "$info" | grep -Eq '^tls:.*\bnative\b'

# ldd cannot fail here, where the -devel packages installed every library; the
# declared requirements are what a clean machine gets.
requires=$(rpm -qpR "$rpm")
for lib in libssl libfuse3 libgmp fuse3; do
  echo "$requires" | grep -q "$lib"
done

# The scriptlets no-op in a container, where /run/systemd/system is absent, so
# only their presence can be checked; and that the restart and the stop name
# the instances, since a template's own name is no unit systemd acts on.
scripts=$(rpm -qp --scripts "$rpm")
for s in postinstall preuninstall; do
  echo "$scripts" | grep -q "^$s scriptlet"
done
test "$(echo "$scripts" | grep -c "'tsync@\*\.service'")" = 2
rpm -ql tsync | grep -q 'tsync@.service'
