#!/bin/bash
# The checks of 10 §5 on a release build: check-release.sh <tsync.app> signed|unsigned.
# Reads TSYNC_APP_ID, TSYNC_APP_GROUP and BUILD_NUMBER.
set -euo pipefail
app=$1 signing=$2
cd "$(dirname "$0")"
work=$(mktemp -d)

fail() { echo "check-release: $*" >&2; exit 1; }
value() { plutil -extract "$2" raw "$1/Info.plist"; }

plugins=("$app"/PlugIns/*.appex)
[ "${#plugins[@]}" = 1 ] || fail "expected one extension, found ${#plugins[@]}"
appex=${plugins[0]}
[ -d "$appex" ] || fail "no extension in $app"

for bundle in "$app" "$appex"; do
  grep -q OCAMLRUNPARAM "$bundle/$(value "$bundle" CFBundleExecutable)" \
    || fail "$bundle does not hold the core"
  [ "$(value "$bundle" CFBundleVersion)" = "$BUILD_NUMBER" ] \
    || fail "$bundle is not build $BUILD_NUMBER"
done
[ "$(value "$app" CFBundleIdentifier)" = "$TSYNC_APP_ID" ] || fail "app identifier"
[ "$(value "$appex" CFBundleIdentifier)" = "$TSYNC_APP_ID.fileprovider" ] || fail "extension identifier"
[ "$(value "$appex" CFBundleShortVersionString)" = "$(value "$app" CFBundleShortVersionString)" ] \
  || fail "the extension's version is not the app's"
for bundle in "$app" "$appex"; do
  [ "$(value "$bundle" TsyncAppGroup)" = "$TSYNC_APP_GROUP" ] || fail "$bundle app group"
done
# App Store Connect refuses an iPad app without all four.
[ "$(value "$app" 'UISupportedInterfaceOrientations~ipad')" = 4 ] || fail "the app does not declare every orientation on iPad"
# The Diagnostics test server is for builds installed from a Mac.
[ -z "$(value "$app" TsyncTestServerURL)" ] || fail "a test server URL is built in"
[ -z "$(value "$app" TsyncTestServerSecret)" ] || fail "a test server secret is built in"

case $signing in
  signed)
    for bundle in "$app" "$appex"; do
      codesign --verify --strict "$bundle"
      codesign -dvv "$bundle" > "$work/signature" 2>&1
      grep -q '^Authority=Apple Distribution' "$work/signature" || fail "$bundle is not signed for distribution"
      codesign -d --entitlements - --xml "$bundle" > "$work/entitlements.plist"
      # plutil splits a key path at every dot; PlistBuddy takes the key whole.
      [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$work/entitlements.plist")" = "$TSYNC_APP_GROUP" ] \
        || fail "$bundle is not entitled to the app group"
    done
    [ "$(plutil -extract aps-environment raw "$work/entitlements.plist")" = production ] \
      || fail "the extension does not push through production"
    ;;
  unsigned)
    # The entitlements exist only once signed: the setting they are made from.
    xcodebuild -project TsyncPhone.xcodeproj -target TsyncPhoneFileProvider -configuration Release \
      -showBuildSettings > "$work/settings"
    grep -qx ' *TSYNC_APS_ENVIRONMENT = production' "$work/settings" \
      || fail "the extension does not push through production"
    echo "::notice::signature checks not run: the build is unsigned"
    ;;
  *) fail "signed or unsigned, not $signing" ;;
esac
echo "check-release: $app passes"
