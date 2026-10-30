#!/bin/sh
# passwords/browser §2: the native-messaging manifests the Linux packages carry,
# one per browser location, each printed by the tsync being packaged.
#   linux/browser-manifests.sh TSYNC ROOT   writes them under the package root ROOT
#   linux/browser-manifests.sh --list       prints where they are installed
set -eu

dirs="/etc/opt/chrome/native-messaging-hosts
/etc/chromium/native-messaging-hosts
/etc/opt/edge/native-messaging-hosts"
name=org.feverdreamtv.tsync.json

if [ "$1" = --list ]; then
  for dir in $dirs; do echo "$dir/$name"; done
  exit 0
fi

for dir in $dirs; do
  mkdir -p "$2$dir"
  "$1" passwords browser manifest --path /usr/bin/tsync > "$2$dir/$name"
  chmod 644 "$2$dir/$name"
done
