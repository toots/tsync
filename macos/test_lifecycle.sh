#!/usr/bin/env bash
# macOS lifecycle test for tsync with FileProvider + OCaml daemon.
#
# Usage: ./test_lifecycle.sh [--skip-build] [CASE_NUM...]
#   --skip-build   skip all build/install steps
#   CASE_NUM       run only these cases; omit to run all
#
# Examples:
#   ./test_lifecycle.sh              # build + run all cases
#   ./test_lifecycle.sh 1 3          # build + run cases 1 and 3
#   ./test_lifecycle.sh --skip-build 6 7
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

run_case() {
    [[ ${#CASES[@]} -eq 0 ]] && return 0
    local n="$1"
    for c in "${CASES[@]}"; do [[ "$c" == "$n" ]] && return 0; done
    return 1
}

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GROUP_CONTAINER="$HOME/Library/Group Containers/group.com.toots.tsync"
CONFIG_JSON="$GROUP_CONTAINER/config.json"
[[ -f "$CONFIG_JSON" ]] || { echo "config not found: $CONFIG_JSON"; exit 1; }

BUCKET=$(jq -r '.bucket' "$CONFIG_JSON")
REGION=$(jq -r '.awsRegion' "$CONFIG_JSON")
PREFIX=$(jq -r '.prefix' "$CONFIG_JSON")
DOMAIN=$(jq -r '.domains[0]' "$CONFIG_JSON")
S3_PREFIX="$PREFIX/$DOMAIN"
DOMAIN_SLUG="${DOMAIN// /}"
MOUNT=$(find "$HOME/Library/CloudStorage" -maxdepth 1 -name "*-${DOMAIN_SLUG}" -type d 2>/dev/null | head -1)
[[ -n "$MOUNT" ]] || { echo "mount not found for domain '$DOMAIN' in ~/Library/CloudStorage"; exit 1; }

TSYNC_BIN="$HOME/.local/bin/tsync"
UPLOAD_TIMEOUT=30
LARGE_UPLOAD_TIMEOUT=180
DOWNLOAD_TIMEOUT=60
TS="lifecycle-$(date +%s)"
JOURNAL_PREFIX="$PREFIX/.journal/$DOMAIN"
LAST_SYNC_FILE="$GROUP_CONTAINER/tsync/last-sync-$DOMAIN"

echo "bucket:  $BUCKET"
echo "region:  $REGION"
echo "prefix:  $S3_PREFIX"
echo "domain:  $DOMAIN"
echo "mount:   $MOUNT"
echo "tsync:   $TSYNC_BIN"
echo "run id:  $TS"
echo

# ── Build ─────────────────────────────────────────────────────────────────────
PROJ="$SCRIPT_DIR/tsync.xcodeproj"
DERIVED_DATA="$SCRIPT_DIR/.build-xcode"
PLIST="$HOME/Library/LaunchAgents/com.toots.tsync.plist"

if [[ $SKIP_BUILD -eq 0 ]]; then
    echo "Building and deploying OCaml daemon..."
    "$SCRIPT_DIR/deploy-daemon.sh"

    echo "Building TsyncApp..."
    build_log=$(mktemp)
    xcodebuild -project "$PROJ" -scheme TsyncApp -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" -jobs 12 \
        CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates >"$build_log" 2>&1 \
        || { cat "$build_log"; rm -f "$build_log"; exit 1; }
    rm -f "$build_log"

    echo "Installing TsyncApp..."
    BUILT_APP="$DERIVED_DATA/Build/Products/Release/TsyncApp.app"
    pkill -f TsyncFileProvider 2>/dev/null || true
    pkill -f TsyncApp 2>/dev/null || true
    sleep 1
    rm -rf /Applications/TsyncApp.app
    cp -R "$BUILT_APP" /Applications/
    if [[ -f "$PLIST" ]]; then
        /usr/libexec/PlistBuddy -c \
            "Set :ProgramArguments:0 /Applications/TsyncApp.app/Contents/MacOS/TsyncApp" \
            "$PLIST" 2>/dev/null || true
        launchctl unload "$PLIST" 2>/dev/null || true
        launchctl load -w "$PLIST"
    fi
    sleep 3  # let FileProvider extension register with the system
else
    echo "Skipping build (--skip-build)"
fi
echo

# ── Colours + output helpers ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
PASS=0; FAIL=0
INJECTED_ENTRY=""

pass() { echo -e "  ${GREEN}PASS${RESET}  $1"; (( PASS++ )) || true; }
fail() { echo -e "  ${RED}FAIL${RESET}  $1"; (( FAIL++ )) || true; }
info() { echo -e "  ${YELLOW}....${RESET}  $1"; }
section() { echo; echo "── $1 ──"; }

# ── S3 helpers ────────────────────────────────────────────────────────────────
s3_exists() {
    aws s3api head-object --bucket "$BUCKET" --key "$1" \
        --region "$REGION" &>/dev/null
}

wait_s3_appear() {
    local key="$1" timeout="${2:-$UPLOAD_TIMEOUT}"
    local deadline=$(( $(date +%s) + timeout ))
    while ! s3_exists "$key"; do
        [[ $(date +%s) -lt $deadline ]] || { fail "timeout waiting for s3://$BUCKET/$key to appear"; return 1; }
        sleep 2
    done
}

wait_s3_gone() {
    local key="$1" timeout="${2:-$UPLOAD_TIMEOUT}"
    local deadline=$(( $(date +%s) + timeout ))
    while s3_exists "$key"; do
        [[ $(date +%s) -lt $deadline ]] || { fail "timeout waiting for s3://$BUCKET/$key to disappear"; return 1; }
        sleep 2
    done
}

s3_content_type() {
    aws s3api head-object --bucket "$BUCKET" --key "$1" --region "$REGION" \
        --query 'ContentType' --output text 2>/dev/null
}

# ── FileProvider download wait ────────────────────────────────────────────────
# Reading the file at the CloudStorage path triggers FileProvider to materialise
# it; poll until the file has non-zero size.
wait_downloaded() {
    local path="$1"
    local deadline=$(( $(date +%s) + DOWNLOAD_TIMEOUT ))
    while true; do
        local sz
        sz=$(wc -c < "$path" 2>/dev/null || echo 0)
        [[ "$sz" -gt 0 ]] && return 0
        [[ $(date +%s) -lt $deadline ]] || { fail "timeout waiting for $path to download"; return 1; }
        sleep 2
    done
}

# ── Cleanup on exit ───────────────────────────────────────────────────────────
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
source "$SCRIPT_DIR/../test_lifecycle_cases.sh"
