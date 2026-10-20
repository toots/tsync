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
#   PROFILE_CREDENTIALS optional .provisionprofile embedded in the AutoFill
#                   credential provider extension
#   PROFILE_DAEMON  optional .provisionprofile embedded in the owner's wrapper;
#                   without it the daemon claims no App Group (file-provider §3.1)
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
command -v xcodegen >/dev/null || {
    echo "xcodegen not found: brew install xcodegen" >&2
    exit 1
}

# The .xcodeproj is generated and gitignored, so a build against a stale one is
# a build of whatever project.yml said last time it was run by hand. A file
# added since -- Assets.xcassets was one -- is simply absent from the bundle,
# and the app comes out with no icon rather than with an error.
say "Generating project"
(cd "$MACOS_DIR" && xcodegen generate --quiet)

# The final signature is always applied here, because the daemon and its dylibs
# are injected after the Xcode build and would invalidate an earlier seal. What
# xcodebuild is asked to do differs by identity:
#
#   release  — a Developer ID identity and explicit profiles are supplied, so
#              xcodebuild signs nothing and everything is done manually below.
#   local    — fall back to Xcode's automatic signing, which provisions and
#              embeds a development profile. SMAppService rejects a bundled
#              LaunchAgent whose app has no Team ID, so an ad-hoc build cannot
#              register the daemon agent; borrowing the Apple Development
#              identity is what makes a local install behave like a real one.
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    dev_identity=$(security find-identity -v -p codesigning \
        | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
    if [[ -n "$dev_identity" ]]; then
        SIGN_IDENTITY="$dev_identity"
        XCODE_SIGNING=(CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
    else
        say "No Apple Development identity: signing ad-hoc."
        say "The daemon agent will not register; use 'make deploy-daemon'-style"
        say "manual runs, or add an identity to test the real install path."
        XCODE_SIGNING=(CODE_SIGNING_ALLOWED=NO)
    fi
else
    XCODE_SIGNING=(CODE_SIGNING_ALLOWED=NO)
fi

XCODE_FLAGS=(
    -project "$MACOS_DIR/tsync.xcodeproj"
    -scheme TsyncApp
    -configuration "$CONFIGURATION"
    -destination 'platform=macOS'
    "${XCODE_SIGNING[@]}"
)

say "Building OCaml daemon"
# lwt records -lev with no -L, and Homebrew's lib dir is not on the default
# linker search path. Without this the daemon fails to link on a Mac whose libev
# came from Homebrew.
if BREW_PREFIX="$(brew --prefix 2>/dev/null)"; then
    export LIBRARY_PATH="$BREW_PREFIX/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
fi
(cd "$REPO" && eval "$(opam env)" && dune build bin/tsync.exe)

say "Building $CONFIGURATION app"
BUILT_PRODUCTS=$(xcodebuild "${XCODE_FLAGS[@]}" -showBuildSettings 2>/dev/null \
    | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')
APP="$BUILT_PRODUCTS/TsyncApp.app"

# Quiet locally, streamed on CI: a captured log tells you nothing about a build
# that never finishes.
if [[ -n "${CI:-}" ]]; then
    xcodebuild "${XCODE_FLAGS[@]}" -jobs "${JOBS:-12}"
else
    build_log=$(mktemp)
    xcodebuild "${XCODE_FLAGS[@]}" -jobs "${JOBS:-12}" >"$build_log" 2>&1 \
        || { cat "$build_log" >&2; rm -f "$build_log"; exit 1; }
    rm -f "$build_log"
fi

# file-provider §3.1: the owner runs from a wrapper bundle, the only place a
# command-line program can hold the profile its App Group claim needs.
say "Embedding daemon"
DAEMON_APP="$APP/Contents/Library/Helpers/tsyncd.app"
DAEMON="$DAEMON_APP/Contents/MacOS/tsync"
rm -rf "$DAEMON_APP" "$APP/Contents/MacOS/tsync" "$APP/Contents/libs"
mkdir -p "$DAEMON_APP/Contents/MacOS"
cp "$MACOS_DIR/TsyncDaemon/Info.plist" "$DAEMON_APP/Contents/Info.plist"
cp "$REPO/_build/default/bin/tsync.exe" "$DAEMON"
chmod +x "$DAEMON"
# The CLI link and existing paths to the app's binary keep working.
ln -s ../Library/Helpers/tsyncd.app/Contents/MacOS/tsync "$APP/Contents/MacOS/tsync"
# Shipped in the bundle so the installer's postinstall and deploy.sh share one
# implementation, and so it can be re-run to repair the agent.
mkdir -p "$APP/Contents/Resources"
cp "$MACOS_DIR/install-agent.sh" "$APP/Contents/Resources/install-agent.sh"
chmod +x "$APP/Contents/Resources/install-agent.sh"

# The daemon links Homebrew dylibs (openssl, gmp, pcre2, libev) that are
# not present on a user's machine. Copy them in and rewrite the install names.
say "Bundling dylibs"
dylibbundler -cd -of -b \
    -x "$DAEMON" \
    -d "$DAEMON_APP/Contents/libs" \
    -p "@executable_path/../libs" >/dev/null

if [[ -n "${BUNDLE_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" \
        "$DAEMON_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" \
        "$APP/Contents/PlugIns/TsyncFileProvider.appex/Contents/Info.plist"
    [[ -n "${PROFILE_CREDENTIALS:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUNDLE_VERSION" \
        "$APP/Contents/PlugIns/TsyncCredentials.appex/Contents/Info.plist"
fi
if [[ -n "${BUNDLE_SHORT_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUNDLE_SHORT_VERSION" \
        "$DAEMON_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUNDLE_SHORT_VERSION" \
        "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUNDLE_SHORT_VERSION" \
        "$APP/Contents/PlugIns/TsyncFileProvider.appex/Contents/Info.plist"
    [[ -n "${PROFILE_CREDENTIALS:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUNDLE_SHORT_VERSION" \
        "$APP/Contents/PlugIns/TsyncCredentials.appex/Contents/Info.plist"
fi

APPEX="$APP/Contents/PlugIns/TsyncFileProvider.appex"
[[ -n "${PROFILE_APP:-}" ]] && cp "$PROFILE_APP" "$APP/Contents/embedded.provisionprofile"
[[ -n "${PROFILE_APPEX:-}" ]] && cp "$PROFILE_APPEX" "$APPEX/Contents/embedded.provisionprofile"
# A claim its profile does not authorise is refused at launch, after the whole
# release, or leaves a bundle the system silently ignores (pitfalls B-11.12,
# B-11.13): check the identifier, every App Group and the AutoFill claim here.
check_profile() {
    local name="$1" profile="$2" entitlements="$3"
    local profile_plist
    profile_plist=$(mktemp)
    security cms -D -i "$profile" >"$profile_plist"
    local profile_id allowed autofill claimed_id claimed claims_autofill
    profile_id=$(/usr/libexec/PlistBuddy \
        -c "Print :Entitlements:com.apple.application-identifier" "$profile_plist" 2>/dev/null || true)
    allowed=$(/usr/libexec/PlistBuddy \
        -c "Print :Entitlements:com.apple.security.application-groups" "$profile_plist" 2>/dev/null || true)
    autofill=$(/usr/libexec/PlistBuddy \
        -c "Print :Entitlements:com.apple.developer.authentication-services.autofill-credential-provider" \
        "$profile_plist" 2>/dev/null || true)
    rm -f "$profile_plist"
    claimed_id=$(/usr/libexec/PlistBuddy -c "Print :com.apple.application-identifier" "$entitlements")
    [[ "$profile_id" == "$claimed_id" ]] || {
        echo "$name is for $profile_id, the bundle claims $claimed_id" >&2
        exit 1
    }
    claimed=$(/usr/libexec/PlistBuddy \
        -c "Print :com.apple.security.application-groups" "$entitlements" 2>/dev/null | sed '1d;$d')
    for group in $claimed; do
        grep -qxF "    $group" <<<"$allowed" || {
            echo "$name does not authorise App Group $group" >&2
            echo "it authorises: $(sed '1d;$d' <<<"$allowed" | xargs)" >&2
            exit 1
        }
    done
    claims_autofill=$(/usr/libexec/PlistBuddy \
        -c "Print :com.apple.developer.authentication-services.autofill-credential-provider" \
        "$entitlements" 2>/dev/null || true)
    [[ "$claims_autofill" != "true" || "$autofill" == "true" ]] || {
        echo "$name does not authorise the AutoFill credential provider" >&2
        exit 1
    }
}

# The AutoFill entitlement is restricted: a build without its profile would
# carry an extension the system refuses, so it carries none (passwords/macos §1).
CREDENTIALS_APPEX="$APP/Contents/PlugIns/TsyncCredentials.appex"
if [[ -n "${PROFILE_CREDENTIALS:-}" ]]; then
    check_profile PROFILE_CREDENTIALS "$PROFILE_CREDENTIALS" \
        "$MACOS_DIR/TsyncCredentials/TsyncCredentials.release.entitlements"
    cp "$PROFILE_CREDENTIALS" "$CREDENTIALS_APPEX/Contents/embedded.provisionprofile"
else
    rm -rf "$CREDENTIALS_APPEX"
fi
# An App Group claim no profile authorises keeps the daemon from launching, so
# the claim is made only with the profile.
DAEMON_SIGNING=()
if [[ -n "${PROFILE_DAEMON:-}" ]]; then
    check_profile PROFILE_DAEMON "$PROFILE_DAEMON" "$MACOS_DIR/TsyncDaemon/tsyncd.entitlements"
    cp "$PROFILE_DAEMON" "$DAEMON_APP/Contents/embedded.provisionprofile"
    DAEMON_SIGNING=(--entitlements "$MACOS_DIR/TsyncDaemon/tsyncd.entitlements")
fi

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

# When Xcode signed the bundle it merged the source entitlements with ones it
# derives from the provisioning profile — com.apple.application-identifier above
# all, which the profile is matched against. Re-signing from the source file
# alone would drop them and break the App Group. Prefer what is already sealed
# in, and fall back to the source for an unsigned (CODE_SIGNING_ALLOWED=NO) build.
effective_entitlements() {
    local bundle="$1" fallback="$2"
    local out="${TMPDIR:-/tmp}/$(basename "$bundle").entitlements"
    if codesign -d --entitlements - --xml "$bundle" >"$out" 2>/dev/null \
        && [[ -s "$out" ]]; then
        echo "$out"
    else
        echo "$fallback"
    fi
}

APPEX_ENTITLEMENTS=$(effective_entitlements "$APPEX" \
    "$MACOS_DIR/TsyncFileProvider/TsyncFileProvider.entitlements")
# The AutoFill entitlement only its profile authorises: the project's file
# leaves it out so Xcode's automatic signing works, and the release signature
# adds it.
CREDENTIALS_ENTITLEMENTS="$MACOS_DIR/TsyncCredentials/TsyncCredentials.release.entitlements"
APP_ENTITLEMENTS=$(effective_entitlements "$APP" \
    "$MACOS_DIR/TsyncApp/TsyncApp.entitlements")
# pitfall B-11.14: the system lists an AutoFill extension only when its app
# holds the entitlement too, under a profile naming the app's identifier.
if [[ -d "$CREDENTIALS_APPEX" ]]; then
    : "${PROFILE_APP:?the AutoFill extension needs PROFILE_APP authorising AutoFill}"
    profile_plist=$(mktemp)
    security cms -D -i "$PROFILE_APP" >"$profile_plist"
    app_id=$(/usr/libexec/PlistBuddy \
        -c "Print :Entitlements:com.apple.application-identifier" "$profile_plist")
    team=$(/usr/libexec/PlistBuddy \
        -c "Print :Entitlements:com.apple.developer.team-identifier" "$profile_plist")
    autofill=$(/usr/libexec/PlistBuddy \
        -c "Print :Entitlements:com.apple.developer.authentication-services.autofill-credential-provider" \
        "$profile_plist" 2>/dev/null || true)
    rm -f "$profile_plist"
    [[ "$autofill" == "true" ]] || {
        echo "PROFILE_APP does not authorise the AutoFill credential provider" >&2
        exit 1
    }
    app_entitlements="${TMPDIR:-/tmp}/TsyncApp.release.entitlements"
    cp "$APP_ENTITLEMENTS" "$app_entitlements"
    for claim in "com.apple.application-identifier string $app_id" \
        "com.apple.developer.team-identifier string $team" \
        "com.apple.developer.authentication-services.autofill-credential-provider bool true"; do
        read -r key type value <<<"$claim"
        /usr/libexec/PlistBuddy -c "Delete :$key" "$app_entitlements" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$app_entitlements"
    done
    APP_ENTITLEMENTS="$app_entitlements"
fi

for dylib in "$DAEMON_APP/Contents/libs"/*.dylib; do
    sign "$dylib"
done
# Signing the wrapper signs its executable; bash 3.2 refuses an empty array
# under set -u, hence the guard.
sign ${DAEMON_SIGNING[@]+"${DAEMON_SIGNING[@]}"} "$DAEMON_APP"
sign --entitlements "$APPEX_ENTITLEMENTS" "$APPEX"
[[ -d "$CREDENTIALS_APPEX" ]] \
    && sign --entitlements "$CREDENTIALS_ENTITLEMENTS" "$CREDENTIALS_APPEX"
sign --entitlements "$APP_ENTITLEMENTS" "$APP"

codesign --verify --deep --strict "$APP"

say "Built $APP"
echo "$APP"
