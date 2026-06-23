#!/usr/bin/env bash
# Lifecycle test for tsync: creation, edit, rename, evict, restore, delete
# Covers: root file, empty directory structure, file in subdirectory
#
# Usage: ./test_lifecycle.sh [--skip-build] [CASE_NUM...]
#   --skip-build   skip xcodebuild + install step
#   CASE_NUM       run only these cases (e.g. 1 3 6); omit to run all
#
# Examples:
#   ./test_lifecycle.sh              # build + run all cases
#   ./test_lifecycle.sh 1 3          # build + run cases 1 and 3
#   ./test_lifecycle.sh --skip-build 6 7   # skip build, run cases 6 and 7
set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
SKIP_BUILD=0
CASES=()
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        [0-9]*) CASES+=("$arg") ;;
        *) echo "unknown argument: $arg"; exit 1 ;;
    esac
done

# Returns 0 (true) if the given case number should run.
run_case() {
    [[ ${#CASES[@]} -eq 0 ]] && return 0
    local n="$1"
    for c in "${CASES[@]}"; do [[ "$c" == "$n" ]] && return 0; done
    return 1
}

# ── Config (read from group container, no hardcoded secrets) ──────────────────
CONFIG_JSON="$HOME/Library/Group Containers/group.com.toots.tsync/config.json"
[[ -f "$CONFIG_JSON" ]] || { echo "config not found: $CONFIG_JSON"; exit 1; }
BUCKET=$(jq -r '.bucket' "$CONFIG_JSON")
REGION=$(jq -r '.awsRegion' "$CONFIG_JSON")
PREFIX=$(jq -r '.prefix' "$CONFIG_JSON")
DOMAIN=$(jq -r '.domains[0].name' "$CONFIG_JSON")
S3_PREFIX="$PREFIX/$DOMAIN"
DOMAIN_SLUG="${DOMAIN// /}"   # "Music Production" → "MusicProduction"
MOUNT=$(find "$HOME/Library/CloudStorage" -maxdepth 1 -name "*-${DOMAIN_SLUG}" -type d | head -1)
[[ -n "$MOUNT" ]] || { echo "mount not found for domain '$DOMAIN'"; exit 1; }
DERIVED_DATA="$(cd "$(dirname "$0")" && pwd)/.build-xcode"
TSYNC_BIN="$DERIVED_DATA/Build/Products/Release/tsync.app/Contents/MacOS/tsync"
PLIST="$HOME/Library/LaunchAgents/com.toots.tsync.plist"
UPLOAD_TIMEOUT=30    # seconds to wait for FileProvider to upload to S3 (small files)
LARGE_UPLOAD_TIMEOUT=180 # seconds for large (chunked) files
DOWNLOAD_TIMEOUT=60  # seconds to wait for FileProvider to download from S3
TS="lifecycle-$(date +%s)"  # unique prefix to avoid collisions

echo "bucket:  $BUCKET"
echo "region:  $REGION"
echo "prefix:  $S3_PREFIX"
echo "domain:  $DOMAIN"
echo "mount:   $MOUNT"
echo "tsync:   $TSYNC_BIN"
echo "install: $DERIVED_DATA/Build/Products/Release/TsyncApp.app"
echo "run id:  $TS"
echo

# ── Build and restart ─────────────────────────────────────────────────────────
PROJ="$(cd "$(dirname "$0")" && pwd)/tsync.xcodeproj"

if [[ $SKIP_BUILD -eq 0 ]]; then
    build_log=$(mktemp)

    echo "Building tsync CLI..."
    xcodebuild -project "$PROJ" -scheme tsync -configuration Release \
        -derivedDataPath "$DERIVED_DATA" -jobs 12 \
        CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates >"$build_log" 2>&1 \
        || { cat "$build_log"; rm -f "$build_log"; exit 1; }

    echo "Building TsyncApp..."
    xcodebuild -project "$PROJ" -scheme TsyncApp -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" -jobs 12 \
        CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates >"$build_log" 2>&1 \
        || { cat "$build_log"; rm -f "$build_log"; exit 1; }

    rm -f "$build_log"

    echo "Installing and restarting TsyncApp..."
    BUILT_APP="$DERIVED_DATA/Build/Products/Release/TsyncApp.app"
    BUILT_BIN="$BUILT_APP/Contents/MacOS/TsyncApp"
    BUILT_APPEX="$BUILT_APP/Contents/PlugIns/TsyncFileProvider.appex"
    launchctl unload "$PLIST" 2>/dev/null || true
    pkill -f TsyncFileProvider 2>/dev/null || true
    pkill -f TsyncApp 2>/dev/null || true
    sleep 2
    # Install into /Applications so macOS FileProvider daemon picks up the new extension
    rm -rf /Applications/TsyncApp.app
    cp -R "$BUILT_APP" /Applications/
    # Restore LaunchAgent to the canonical /Applications path
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 /Applications/TsyncApp.app/Contents/MacOS/TsyncApp" "$PLIST"
    launchctl load -w "$PLIST"
    # Wait until the IPC socket appears (TsyncApp running) before proceeding
    echo -n "Waiting for TsyncApp IPC..."
    IPC_SOCK="$HOME/Library/Group Containers/group.com.toots.tsync/tsync.sock"
    deadline=$(( $(date +%s) + 30 ))
    until [[ -S "$IPC_SOCK" ]]; do
        [[ $(date +%s) -lt $deadline ]] || { echo " timeout"; exit 1; }
        sleep 1; echo -n "."
    done
    echo " ready"
    sleep 2  # give the extension time to finish loading after IPC is up
else
    echo "Skipping build (--skip-build)"
fi
echo

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
PASS=0; FAIL=0

pass() { echo -e "  ${GREEN}PASS${RESET}  $1"; (( PASS++ )) || true; }
fail() { echo -e "  ${RED}FAIL${RESET}  $1"; (( FAIL++ )) || true; }
info() { echo -e "  ${YELLOW}....${RESET}  $1"; }
section() { echo; echo "── $1 ──"; }

# ── S3 helpers ────────────────────────────────────────────────────────────────
s3_exists() {
    aws s3api head-object --bucket "$BUCKET" --key "$1" \
        --region "$REGION" &>/dev/null
}

# Poll until S3 object appears (upload propagation)
wait_s3_appear() {
    local key="$1" timeout="${2:-$UPLOAD_TIMEOUT}"
    local deadline=$(( $(date +%s) + timeout ))
    while ! s3_exists "$key"; do
        [[ $(date +%s) -lt $deadline ]] || { fail "timeout waiting for s3://$BUCKET/$key to appear"; return 1; }
        sleep 2
    done
}

# Poll until S3 object disappears (delete propagation; versioning moves to trash)
wait_s3_gone() {
    local key="$1" timeout="${2:-$UPLOAD_TIMEOUT}"
    local deadline=$(( $(date +%s) + timeout ))
    while s3_exists "$key"; do
        [[ $(date +%s) -lt $deadline ]] || { fail "timeout waiting for s3://$BUCKET/$key to disappear"; return 1; }
        sleep 2
    done
}

# Check that a key's Content-Type matches (confirms chunked manifest path for large files)
s3_content_type() {
    aws s3api head-object --bucket "$BUCKET" --key "$1" --region "$REGION" \
        --query 'ContentType' --output text 2>/dev/null
}

# ── FileProvider download wait ────────────────────────────────────────────────
wait_downloaded() {
    local path="$1"
    "$TSYNC_BIN" wait --timeout "$DOWNLOAD_TIMEOUT" "$path" &>/dev/null \
        || { fail "timeout waiting for $path to download"; return 1; }
}

# ── Cleanup on exit ───────────────────────────────────────────────────────────
JOURNAL_PREFIX="$PREFIX/.journal/$DOMAIN"
GROUP_CONTAINER="$HOME/Library/Group Containers/group.com.toots.tsync"
LAST_SYNC_FILE="$GROUP_CONTAINER/last-sync-$DOMAIN"
INJECTED_ENTRY=""   # set later; used in cleanup

cleanup() {
    info "cleaning up..."
    rm -f  "$MOUNT/${TS}_root.txt"        2>/dev/null || true
    rm -f  "$MOUNT/${TS}_root_b.txt"      2>/dev/null || true
    rm -rf "$MOUNT/${TS}_emptydir"        2>/dev/null || true
    rm -rf "$MOUNT/${TS}_emptydir_b"      2>/dev/null || true
    rm -rf "$MOUNT/${TS}_subdir"          2>/dev/null || true
    rm -f  "$MOUNT/${TS}_large.bin"       2>/dev/null || true
    rm -f  "$MOUNT/${TS}_large_b.bin"     2>/dev/null || true
    rm -rf "$MOUNT/${TS}_largedir"        2>/dev/null || true
    rm -f  /tmp/${TS}_large.bin           2>/dev/null || true
    rm -f  "$MOUNT/${TS}_jtest.txt"       2>/dev/null || true
    rm -f  "$MOUNT/${TS}_jtest_b.txt"     2>/dev/null || true
    rm -rf "$MOUNT/${TS}_jdir"            2>/dev/null || true
    rm -f  "$MOUNT/${TS}_sync.txt"        2>/dev/null || true
    [[ -n "$INJECTED_ENTRY" ]] && \
        aws s3 rm "s3://$BUCKET/$INJECTED_ENTRY" --region "$REGION" 2>/dev/null || true
}
trap cleanup EXIT

# ── Run shared cases ──────────────────────────────────────────────────────────
source "$(cd "$(dirname "$0")" && pwd)/../test_lifecycle_cases.sh"
