#!/usr/bin/env bash
# Build and install TsyncApp.app into /Applications, then launch it. The app
# registers itself as a login item and starts the bundled daemon agent.
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"

say() { echo "==> $*" >&2; }

APP=$("$MACOS_DIR/build.sh" | tail -n1)

say "Stopping"
for label in org.feverdreamtv.tsync org.feverdreamtv.tsync.daemon; do
    launchctl bootout "gui/$UID/$label" 2>/dev/null || true
done
pkill -f TsyncFileProvider 2>/dev/null || true
pkill -f TsyncApp 2>/dev/null || true
sleep 2

say "Installing to /Applications"
rm -rf /Applications/TsyncApp.app
cp -R "$APP" /Applications/

say "Starting"
/Applications/TsyncApp.app/Contents/Resources/install-agent.sh
open /Applications/TsyncApp.app

SOCK="$HOME/Library/Group Containers/group.org.feverdreamtv.tsync/tsync/tsync.sock"
echo -n "==> Waiting for socket" >&2
deadline=$(( $(date +%s) + 15 ))
until [[ -S "$SOCK" ]]; do
    [[ $(date +%s) -lt $deadline ]] || { echo " timeout" >&2; exit 1; }
    sleep 1; echo -n "." >&2
done
echo " ready" >&2
