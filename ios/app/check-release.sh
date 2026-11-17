#!/bin/bash
# The checks of 10 §5 on a release build: check-release.sh <tsync.app> signed|unsigned.
# Reads TSYNC_APP_ID, TSYNC_APP_GROUP, TSYNC_EXPORT_COMPLIANCE_CODE and BUILD_NUMBER.
set -euo pipefail
app=$1 signing=$2
cd "$(dirname "$0")"
work=$(mktemp -d)

fail() { echo "check-release: $*" >&2; exit 1; }
value() { plutil -extract "$2" raw "$1/Info.plist"; }

plugins=("$app"/PlugIns/*.appex)
[ "${#plugins[@]}" = 3 ] || fail "expected three extensions, found ${#plugins[@]}"
appex=$app/PlugIns/TsyncPhoneFileProvider.appex
credentials=$app/PlugIns/TsyncPhoneCredentials.appex
share=$app/PlugIns/TsyncPhoneShare.appex
[ -d "$appex" ] || fail "no File Provider extension in $app"
[ -d "$credentials" ] || fail "no credential provider extension in $app"
[ -d "$share" ] || fail "no share extension in $app"
# ios-app §8.7: an ExtensionKit extension, under Extensions.
upload=$app/Extensions/TsyncPhoneUpload.appex
[ -d "$upload" ] || fail "no upload extension in $app"
[ "$(value "$upload" EXAppExtensionAttributes.EXExtensionPointIdentifier)" = com.apple.photos.background-upload ] \
  || fail "the upload extension is not a background upload extension"

# passwords/ios §1, ios-app §7: the credential provider and the share extension hold no core.
for bundle in "$app" "$appex"; do
  grep -q OCAMLRUNPARAM "$bundle/$(value "$bundle" CFBundleExecutable)" \
    || fail "$bundle does not hold the core"
done
for bundle in "$credentials" "$share" "$upload"; do
  ! grep -q OCAMLRUNPARAM "$bundle/$(value "$bundle" CFBundleExecutable)" \
    || fail "$bundle holds the core"
done
for bundle in "$app" "$appex" "$credentials" "$share" "$upload"; do
  [ "$(value "$bundle" CFBundleVersion)" = "$BUILD_NUMBER" ] \
    || fail "$bundle is not build $BUILD_NUMBER"
  [ "$(value "$bundle" CFBundleShortVersionString)" = "$(value "$app" CFBundleShortVersionString)" ] \
    || fail "$bundle's version is not the app's"
  [ "$(value "$bundle" TsyncAppGroup)" = "$TSYNC_APP_GROUP" ] || fail "$bundle app group"
done
[ "$(value "$app" CFBundleIdentifier)" = "$TSYNC_APP_ID" ] || fail "app identifier"
[ "$(value "$appex" CFBundleIdentifier)" = "$TSYNC_APP_ID.fileprovider" ] || fail "extension identifier"
[ "$(value "$credentials" CFBundleIdentifier)" = "$TSYNC_APP_ID.credentials" ] \
  || fail "credential provider identifier"
[ "$(value "$share" CFBundleIdentifier)" = "$TSYNC_APP_ID.share" ] || fail "share extension identifier"
[ "$(value "$upload" CFBundleIdentifier)" = "$TSYNC_APP_ID.upload" ] || fail "upload extension identifier"
# 10 §5.6: the vault's ciphers are declared with the code App Store Connect
# issued, and not at all before it is.
if [ -n "$TSYNC_EXPORT_COMPLIANCE_CODE" ]; then
  [ "$(value "$app" ITSAppUsesNonExemptEncryption)" = true ] || fail "the app does not declare its encryption"
  [ "$(value "$app" ITSEncryptionExportComplianceCode)" = "$TSYNC_EXPORT_COMPLIANCE_CODE" ] \
    || fail "the app's export compliance code is not the identifiers file's"
else
  ! value "$app" ITSAppUsesNonExemptEncryption > /dev/null 2>&1 || fail "the app declares encryption without a code"
  ! value "$app" ITSEncryptionExportComplianceCode > /dev/null 2>&1 || fail "the app has an empty export compliance code"
fi
# App Store Connect refuses an iPad app without all four.
[ "$(value "$app" 'UISupportedInterfaceOrientations~ipad')" = 4 ] || fail "the app does not declare every orientation on iPad"
# Test actions and the test server are for builds installed from a Mac.
[ -z "$(value "$app" TsyncDevelopment)" ] || fail "a development build"
[ -z "$(value "$app" TsyncTestServerURL)" ] || fail "a test server URL is built in"
[ -z "$(value "$app" TsyncTestServerSecret)" ] || fail "a test server secret is built in"

case $signing in
  signed)
    # The File Provider extension last: the push check reads its entitlements.
    for bundle in "$credentials" "$share" "$upload" "$app" "$appex"; do
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
