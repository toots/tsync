#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PROJ="$REPO/tsync.xcodeproj"
PLIST="$HOME/Library/LaunchAgents/com.toots.tsync.plist"

XCODE_FLAGS=(-project "$PROJ" -scheme TsyncApp -configuration Release
    -destination 'platform=macOS' CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
BUILT_PRODUCTS=$(xcodebuild "${XCODE_FLAGS[@]}" -showBuildSettings 2>/dev/null \
    | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')
BUILT_APP="$BUILT_PRODUCTS/TsyncApp.app"

echo "Building..."
build_log=$(mktemp)
xcodebuild "${XCODE_FLAGS[@]}" -jobs 12 >"$build_log" 2>&1 \
    || { cat "$build_log"; rm -f "$build_log"; exit 1; }
rm -f "$build_log"

echo "Installing to /Applications..."
launchctl unload "$PLIST" 2>/dev/null || true
pkill -f TsyncFileProvider 2>/dev/null || true
pkill -f TsyncApp 2>/dev/null || true
sleep 2
pluginkit -e ignore -i com.toots.tsync.fileprovider 2>/dev/null || true
pluginkit -r -i com.toots.tsync.fileprovider 2>/dev/null || true
rm -rf /Applications/TsyncApp.app
cp -R "$BUILT_APP" /Applications/

echo "Starting..."
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.toots.tsync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/TsyncApp.app/Contents/MacOS/TsyncApp</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
pluginkit -a /Applications/TsyncApp.app/Contents/PlugIns/TsyncFileProvider.appex
pluginkit -e use -i com.toots.tsync.fileprovider
launchctl load -w "$PLIST"

echo "Done."
