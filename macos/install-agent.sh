#!/usr/bin/env bash
# Install and start the service's LaunchAgent for the current user.
#
# file-provider §11: a per-user agent definition, acceptable where the bundled
# SMAppService agent cannot be registered. It names the app as its associated
# bundle so the system attributes it to the app in Login Items.
#
# Runs as the user who will own the agent — never as root.
set -euo pipefail

APP="${1:-/Applications/TsyncApp.app}"
LABEL=org.feverdreamtv.tsync.daemon
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SOCKET="$HOME/Library/Group Containers/group.org.feverdreamtv.tsync/tsync/tsync.sock"
LOG="$HOME/Library/Logs/tsync-daemon.log"

[[ -x "$APP/Contents/MacOS/tsync" ]] || {
    echo "no daemon at $APP/Contents/MacOS/tsync" >&2
    exit 1
}

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
# A service still draining after bootout makes the bootstrap below fail with
# an I/O error; wait until launchd has let it go.
for _ in $(seq 1 60); do
    launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
done
# A leftover socket makes callers think the daemon is up before it is.
rm -f "$SOCKET"

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/tsync</string>
        <string>start</string>
    </array>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>org.feverdreamtv.tsync</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Restart on any unclean exit. The service keeps running with no domain
         configured, so a clean exit is a requested stop. -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <!-- Keep whatever the daemon says on its way out. launchd restarts it on a
         crash, so without this an uncaught exception leaves nothing behind but a
         higher restart count: the process that could explain itself is already
         gone and its successor is healthy. -->
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

launchctl enable "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
