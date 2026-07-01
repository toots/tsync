#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HOME/.local/bin/tsync"
PLIST_DST="$HOME/Library/LaunchAgents/com.toots.tsync.daemon.plist"
LABEL="com.toots.tsync.daemon"

echo "Building OCaml daemon..."
(cd "$REPO" && eval "$(opam env)" && dune build)

echo "Installing binary..."
mkdir -p "$(dirname "$BIN")"
rm -f "$BIN"
cp "$REPO/_build/default/bin/tsync.exe" "$BIN"
chmod +x "$BIN"

echo "Linking config..."
GROUP_CONFIG="$HOME/Library/Group Containers/group.com.toots.tsync/config.json"
XDG_CONFIG="$HOME/.config/tsync/config.json"
mkdir -p "$(dirname "$XDG_CONFIG")"
[[ -L "$XDG_CONFIG" ]] && rm -f "$XDG_CONFIG"
[[ ! -f "$XDG_CONFIG" ]] && ln -sf "$GROUP_CONFIG" "$XDG_CONFIG"

echo "Installing launchd plist..."
mkdir -p "$(dirname "$PLIST_DST")"
cat > "$PLIST_DST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/tsync-daemon.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/tsync-daemon.log</string>
</dict>
</plist>
EOF

echo "Starting daemon..."
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load -w "$PLIST_DST"

echo -n "Waiting for socket..."
SOCK="$HOME/Library/Group Containers/group.com.toots.tsync/tsync/tsync.sock"
deadline=$(( $(date +%s) + 15 ))
until [[ -S "$SOCK" ]]; do
    [[ $(date +%s) -lt $deadline ]] || { echo " timeout"; exit 1; }
    sleep 1; echo -n "."
done
echo " ready"

echo "Done."
