#!/usr/bin/env bash
# Build a complete, self-contained TsyncApp.app: the Swift app + FileProvider
# extension, with the OCaml daemon and its Homebrew dylibs embedded.
#
# Prints the path of the built .app on stdout.
#
# Environment:
#   CONFIGURATION   Release (default) or Debug
#   SIGN_IDENTITY   codesign identity; "-" (ad-hoc, default) is enough locally.
#                   package.sh overrides this with the Developer ID identity.
#   PROFILE_APP     optional .provisionprofile embedded in the app
#   PROFILE_APPEX   optional .provisionprofile embedded in the extension
#   BUNDLE_VERSION / BUNDLE_SHORT_VERSION  optional CFBundleVersion overrides
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$MACOS_DIR/.." && pwd)"

CONFIGURATION="${CONFIGURATION:-Release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

say() { echo "==> $*" >&2; }

command -v dylibbundler >/dev/null || {
    echo "dylibbundler not found: brew install dylibbundler" >&2
    exit 1
}

# Signing is done here rather than by xcodebuild: the daemon and its dylibs are
# injected after the Xcode build, which would invalidate any earlier signature.
XCODE_FLAGS=(
    -project "$MACOS_DIR/tsync.xcodeproj"
    -scheme TsyncApp
    -configuration "$CONFIGURATION"
    -destination 'platform=macOS'
    CODE_SIGNING_ALLOWED=NO
)

say "Building OCaml daemon"
(cd "$REPO" && eval "$(opam env)" && dune build bin/tsync.exe)

say "Building $CONFIGURATION app"
BUILT_PRODUCTS=$(xcodebuild "${XCODE_FLAGS[@]}" -showBuildSettings 2>/dev/null \
    | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')
APP="$BUILT_PRODUCTS/TsyncApp.app"

build_log=$(mktemp)
xcodebuild "${XCODE_FLAGS[@]}" -jobs "${JOBS:-12}" >"$build_log" 2>&1 \
    || { cat "$build_log" >&2; rm -f "$build_log"; exit 1; }
rm -f "$build_log"

say "Embedding daemon"
cp "$REPO/_build/default/bin/tsync.exe" "$APP/Contents/MacOS/tsync"
chmod +x "$APP/Contents/MacOS/tsync"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp "$MACOS_DIR/LaunchAgents/org.feverdreamtv.tsync.daemon.plist" \
    "$APP/Contents/Library/LaunchAgents/"

# The daemon links Homebrew dylibs (openssl, gmp, pcre2, libev, xxhash) that are
# not present on a user's machine. Copy them in and rewrite the install names.
say "Bundling dylibs"
rm -rf "$APP/Contents/libs"
dylibbundler -cd -of -b \
    -x "$APP/Contents/MacOS/tsync" \
    -d "$APP/Contents/libs" \
    -p "@executable_path/../libs" >/dev/null

if [[ -n "${BUNDLE_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" \
        "$APP/Contents/PlugIns/TsyncFileProvider.appex/Contents/Info.plist"
fi
if [[ -n "${BUNDLE_SHORT_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUNDLE_SHORT_VERSION" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUNDLE_SHORT_VERSION" \
        "$APP/Contents/PlugIns/TsyncFileProvider.appex/Contents/Info.plist"
fi

APPEX="$APP/Contents/PlugIns/TsyncFileProvider.appex"
[[ -n "${PROFILE_APP:-}" ]] && cp "$PROFILE_APP" "$APP/Contents/embedded.provisionprofile"
[[ -n "${PROFILE_APPEX:-}" ]] && cp "$PROFILE_APPEX" "$APPEX/Contents/embedded.provisionprofile"

# Inside-out: nested code must be sealed before the enclosing bundle.
say "Signing with identity: $SIGN_IDENTITY"
# Ad-hoc signatures carry neither a secure timestamp nor a Team ID, and the
# hardened runtime's library validation rejects the bundled dylibs without one.
# Both are enabled as soon as a real identity is used.
SIGN_FLAGS=(--timestamp --options runtime)
[[ "$SIGN_IDENTITY" == "-" ]] && SIGN_FLAGS=(--timestamp=none)

sign() {
    codesign --force "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$@"
}

for dylib in "$APP/Contents/libs"/*.dylib; do
    sign "$dylib"
done
sign "$APP/Contents/MacOS/tsync"
sign --entitlements "$MACOS_DIR/TsyncFileProvider/TsyncFileProvider.entitlements" "$APPEX"
sign --entitlements "$MACOS_DIR/TsyncApp/TsyncApp.entitlements" "$APP"

codesign --verify --deep --strict "$APP"

say "Built $APP"
echo "$APP"
