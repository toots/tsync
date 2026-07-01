#!/usr/bin/env bash
# Linux lifecycle test wrapper — sets up env, starts daemon, sources shared cases.
set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
SKIP_BUILD=false
CASES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true ;;
    [0-9]*) CASES+=("$1") ;;
  esac
  shift
done
run_case() { [[ ${#CASES[@]} -eq 0 ]] || printf '%s\n' "${CASES[@]}" | grep -qx "$1"; }

# ── Config ────────────────────────────────────────────────────────────────────
if [[ -n "${TSYNC_CONFIG_JSON:-}" ]]; then
  _cfg() { echo "$TSYNC_CONFIG_JSON" | jq -r "$1"; }
else
  CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/tsync/config.json"
  [[ -f "$CONFIG_FILE" ]] || { echo "config not found: $CONFIG_FILE"; exit 1; }
  _cfg() { jq -r "$1" "$CONFIG_FILE"; }
fi

if ! aws sts get-caller-identity &>/dev/null; then
  mkdir -p "$HOME/.aws"
  printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
    "$(_cfg '.accessKeyId')" "$(_cfg '.secretAccessKey')" \
    > "$HOME/.aws/credentials"
fi

BUCKET=$(_cfg '.bucket')
REGION=$(_cfg '.awsRegion')
PREFIX=$(_cfg '.prefix')
DOMAIN=$(_cfg '.domains[0]')
S3_PREFIX="$PREFIX/$DOMAIN"
MOUNT="$HOME/tsync/$DOMAIN"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TSYNC_BIN="$SCRIPT_DIR/_build/default/bin/main.exe"

# ── Build ─────────────────────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == "false" ]] && [[ ! -x "$TSYNC_BIN" ]]; then
    echo "Building tsync..."
    (cd "$SCRIPT_DIR" && eval "$(opam env)" && dune build)
fi

UPLOAD_TIMEOUT=30
LARGE_UPLOAD_TIMEOUT=180
DOWNLOAD_TIMEOUT=60
TS="lifecycle-$(date +%s)"
JOURNAL_PREFIX="$PREFIX/.journal/$DOMAIN"
LAST_SYNC_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/tsync/last-sync-$DOMAIN"

echo "bucket:  $BUCKET"
echo "region:  $REGION"
echo "prefix:  $S3_PREFIX"
echo "domain:  $DOMAIN"
echo "mount:   $MOUNT"
echo "tsync:   $TSYNC_BIN"
echo "run id:  $TS"
echo

# ── Start daemon ──────────────────────────────────────────────────────────────
mkdir -p "$MOUNT"
IPC_SOCK="${XDG_DATA_HOME:-$HOME/.local/share}/tsync/tsync.sock"
"$TSYNC_BIN" start --domain "$DOMAIN" --mount "$MOUNT" &
DAEMON_PID=$!
echo -n "Waiting for daemon IPC..."
deadline=$(( $(date +%s) + 30 ))
until [[ -S "$IPC_SOCK" ]]; do
    [[ $(date +%s) -lt $deadline ]] || { echo " timeout"; exit 1; }
    sleep 1; echo -n "."
done
echo " ready"
sleep 1
echo

# ── Colours ───────────────────────────────────────────────────────────────────
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
        [[ $(date +%s) -lt $deadline ]] || { fail "timeout waiting for s3://$BUCKET/$key"; return 1; }
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

wait_downloaded() {
    local path="$1"
    "$TSYNC_BIN" wait --timeout "$DOWNLOAD_TIMEOUT" "$path" &>/dev/null \
        || { fail "timeout waiting for $path to download"; return 1; }
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
    info "cleaning up..."
    "$TSYNC_BIN" stop 2>/dev/null || kill "$DAEMON_PID" 2>/dev/null || true
    rm -f  "$MOUNT/${TS}_root.txt"     "$MOUNT/${TS}_root_b.txt"   2>/dev/null || true
    rm -rf "$MOUNT/${TS}_emptydir"     "$MOUNT/${TS}_emptydir_b"   2>/dev/null || true
    rm -rf "$MOUNT/${TS}_subdir"                                    2>/dev/null || true
    rm -f  "$MOUNT/${TS}_large.bin"    "$MOUNT/${TS}_large_b.bin"  2>/dev/null || true
    rm -rf "$MOUNT/${TS}_largedir"                                  2>/dev/null || true
    rm -f  /tmp/${TS}_large.bin                                     2>/dev/null || true
    rm -f  "$MOUNT/${TS}_jtest.txt"    "$MOUNT/${TS}_jtest_b.txt"  2>/dev/null || true
    rm -rf "$MOUNT/${TS}_jdir"                                      2>/dev/null || true
    rm -f  "$MOUNT/${TS}_sync.txt"                                  2>/dev/null || true
    [[ -n "$INJECTED_ENTRY" ]] && \
        aws s3 rm "s3://$BUCKET/$INJECTED_ENTRY" --region "$REGION" 2>/dev/null || true
}
trap cleanup EXIT

# ── Run shared cases ──────────────────────────────────────────────────────────
source "$SCRIPT_DIR/../test_lifecycle_cases.sh"
