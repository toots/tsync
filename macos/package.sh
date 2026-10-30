#!/usr/bin/env bash
# Produce a notarized, stapled tsync.pkg for distribution.
#
# The installer places the app in /Applications and the browsers' native-messaging
# manifests under /Library, and symlinks the CLI into /usr/local/bin — see
# scripts/postinstall. That is the reason for a pkg rather
# than a disk image: a sandboxed app cannot put anything outside its bundle.
#
# Required environment:
#   SIGN_IDENTITY        "Developer ID Application: … (TEAMID)", in the keychain
#   INSTALLER_IDENTITY   "Developer ID Installer: … (TEAMID)", in the keychain
#   PROFILE_APP          .provisionprofile for org.feverdreamtv.tsync
#   PROFILE_APPEX        .provisionprofile for org.feverdreamtv.tsync.fileprovider
#   PROFILE_CREDENTIALS  .provisionprofile for org.feverdreamtv.tsync.credentials
#   PROFILE_DAEMON       .provisionprofile for org.feverdreamtv.tsync.daemon
#
# Notarization runs only when App Store Connect credentials are present:
#   AC_API_KEY_PATH / AC_API_KEY_ID / AC_API_ISSUER_ID
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$MACOS_DIR/dist}"
PKG="$OUT/tsync.pkg"

say() { echo "==> $*" >&2; }

: "${SIGN_IDENTITY:?set SIGN_IDENTITY to a Developer ID Application identity}"
: "${INSTALLER_IDENTITY:?set INSTALLER_IDENTITY to a Developer ID Installer identity}"
: "${PROFILE_APP:?set PROFILE_APP to the app provisioning profile}"
: "${PROFILE_APPEX:?set PROFILE_APPEX to the extension provisioning profile}"
: "${PROFILE_CREDENTIALS:?set PROFILE_CREDENTIALS to the AutoFill extension provisioning profile}"
# file-provider §11: an owner that cannot claim the App Group prompts at every start.
: "${PROFILE_DAEMON:?set PROFILE_DAEMON to the owner wrapper provisioning profile}"

APP=$(CONFIGURATION=Release "$MACOS_DIR/build.sh" | tail -n1)

say "Building installer"
rm -rf "$OUT"
mkdir -p "$OUT"

# passwords/browser §2: the payload is the app and the browsers' native-messaging
# manifests, each printed by the app's own tsync naming where it is installed.
ROOT="$OUT/root"
mkdir -p "$ROOT/Applications"
ditto "$APP" "$ROOT/Applications/TsyncApp.app"
TSYNC=/Applications/TsyncApp.app/Contents/Library/Helpers/tsyncd.app/Contents/MacOS/tsync
MANIFESTS=(
    "Library/Google/Chrome/NativeMessagingHosts"
    "Library/Application Support/Chromium/NativeMessagingHosts"
    "Library/Microsoft/Edge/NativeMessagingHosts"
)
for dir in "${MANIFESTS[@]}"; do
    mkdir -p "$ROOT/$dir"
    "$ROOT$TSYNC" passwords browser manifest --path "$TSYNC" \
        > "$ROOT/$dir/org.feverdreamtv.tsync.json"
done

# A relocatable bundle is installed over whatever copy of it the installer
# finds elsewhere on disk, not in /Applications.
pkgbuild --analyze --root "$ROOT" "$OUT/components.plist" >/dev/null
n=0
while /usr/libexec/PlistBuddy -c "Set :$n:BundleIsRelocatable false" "$OUT/components.plist" 2>/dev/null; do
    n=$((n + 1))
done

# ponytail: a component package installs fine on its own. productbuild only
# earns its place once the installer needs a title, licence or custom pages.
pkgbuild \
    --root "$ROOT" \
    --component-plist "$OUT/components.plist" \
    --install-location / \
    --scripts "$MACOS_DIR/scripts" \
    --identifier org.feverdreamtv.tsync \
    --version "${BUNDLE_SHORT_VERSION:-0.0.0}" \
    --sign "$INSTALLER_IDENTITY" \
    --timestamp \
    "$PKG" >/dev/null

pkgutil --check-signature "$PKG" >/dev/null
payload=$(pkgutil --payload-files "$PKG")
for dir in "${MANIFESTS[@]}"; do
    grep -qx "./$dir/org.feverdreamtv.tsync.json" <<<"$payload"
done
rm -rf "$ROOT"

if [[ -z "${AC_API_KEY_PATH:-}" ]]; then
    say "No App Store Connect credentials, skipping notarization"
    echo "$PKG"
    exit 0
fi

say "Notarizing (this takes a few minutes)"
# --wait blocks indefinitely by default; bound it so a stalled submission fails
# the build instead of holding a runner.
xcrun notarytool submit "$PKG" \
    --key "$AC_API_KEY_PATH" \
    --key-id "$AC_API_KEY_ID" \
    --issuer "$AC_API_ISSUER_ID" \
    --wait --timeout 30m

xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"

say "Packaged $PKG"
echo "$PKG"
