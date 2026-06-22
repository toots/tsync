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
rm -rf /Applications/TsyncApp.app
cp -R "$BUILT_APP" /Applications/

echo "Starting..."
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 /Applications/TsyncApp.app/Contents/MacOS/TsyncApp" "$PLIST"
pluginkit -a /Applications/TsyncApp.app/Contents/PlugIns/TsyncFileProvider.appex
launchctl load -w "$PLIST"

echo -n "Waiting for TsyncApp..."
IPC_SOCK="$HOME/Library/Group Containers/group.com.toots.tsync/tsync.sock"
deadline=$(( $(date +%s) + 30 ))
until [[ -S "$IPC_SOCK" ]]; do
    [[ $(date +%s) -lt $deadline ]] || { echo " timeout"; exit 1; }
    sleep 1; echo -n "."
done
echo " ready"
sleep 2

echo "Done."
