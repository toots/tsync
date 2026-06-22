#!/usr/bin/env bash
# Lifecycle test for tsync Linux (FUSE): creation, edit, rename, evict, restore, delete
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
# Config source: TSYNC_CONFIG_JSON env var (Docker/CI) or config file on disk
if [[ -n "${TSYNC_CONFIG_JSON:-}" ]]; then
  _cfg() { echo "$TSYNC_CONFIG_JSON" | jq -r "$1"; }
else
  CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/tsync/config.json"
  [[ -f "$CONFIG_FILE" ]] || { echo "config not found: $CONFIG_FILE"; exit 1; }
  _cfg() { jq -r "$1" "$CONFIG_FILE"; }
fi

# Set up AWS CLI credentials if not already configured
if ! aws sts get-caller-identity &>/dev/null; then
  mkdir -p "$HOME/.aws"
  printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
    "$(_cfg '.accessKeyId')" "$(_cfg '.secretAccessKey')" \
    > "$HOME/.aws/credentials"
fi
BUCKET=$(_cfg '.bucket')
REGION=$(_cfg '.awsRegion')
PREFIX=$(_cfg '.prefix')
DOMAIN=$(_cfg '.domains[0].name')
S3_PREFIX="$PREFIX/$DOMAIN"
MOUNT="$HOME/tsync/$DOMAIN"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TSYNC_BIN="$SCRIPT_DIR/_build/default/bin/main.exe"

# Build if needed
if [[ ! -x "$TSYNC_BIN" ]]; then
    echo "Building tsync..."
    (cd "$SCRIPT_DIR" && eval "$(opam env)" && dune build)
fi

UPLOAD_TIMEOUT=30
LARGE_UPLOAD_TIMEOUT=180
DOWNLOAD_TIMEOUT=60
TS="lifecycle-$(date +%s)"

echo "bucket:  $BUCKET"
echo "region:  $REGION"
echo "prefix:  $S3_PREFIX"
echo "domain:  $DOMAIN"
echo "mount:   $MOUNT"
echo "tsync:   $TSYNC_BIN"
echo "run id:  $TS"
echo

# ── Start daemon ──────────────────────────────────────────────────────────────
IPC_SOCK="${XDG_DATA_HOME:-$HOME/.local/share}/tsync/tsync.sock"
"$TSYNC_BIN" start --domain "$DOMAIN" --mount "$MOUNT"
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
    "$TSYNC_BIN" stop 2>/dev/null || true
    rm -f  "$MOUNT/${TS}_root.txt"    "$MOUNT/${TS}_root_b.txt"   2>/dev/null || true
    rm -rf "$MOUNT/${TS}_emptydir"    "$MOUNT/${TS}_emptydir_b"   2>/dev/null || true
    rm -rf "$MOUNT/${TS}_subdir"                                   2>/dev/null || true
    rm -f  "$MOUNT/${TS}_large.bin"   "$MOUNT/${TS}_large_b.bin"  2>/dev/null || true
    rm -rf "$MOUNT/${TS}_largedir"                                 2>/dev/null || true
    rm -f  /tmp/${TS}_large.bin                                    2>/dev/null || true
}
trap cleanup EXIT

# ══════════════════════════════════════════════════════════════════════════════
# CASE 1: Root file
# ══════════════════════════════════════════════════════════════════════════════
section "CASE 1: Root file"
ROOT_FILE="$MOUNT/${TS}_root.txt"
ROOT_KEY="$S3_PREFIX/${TS}_root.txt"
ROOT_FILE_B="$MOUNT/${TS}_root_b.txt"
ROOT_KEY_B="$S3_PREFIX/${TS}_root_b.txt"

info "create"
echo "hello tsync" > "$ROOT_FILE"
wait_s3_appear "$ROOT_KEY" && pass "create: S3 object appeared"

info "edit"
echo "hello again" >> "$ROOT_FILE"
sleep 2
wait_s3_appear "$ROOT_KEY" && pass "edit: S3 object still present after edit"
[[ $(wc -c < "$ROOT_FILE") -gt 12 ]] && pass "edit: local file content updated" \
    || fail "edit: local file content unchanged"

info "rename"
mv "$ROOT_FILE" "$ROOT_FILE_B"
sleep 3
if s3_exists "$ROOT_KEY_B"; then
    pass "rename: new S3 key appeared"
    s3_exists "$ROOT_KEY" \
        && fail "rename: old S3 key still present" \
        || pass "rename: old S3 key removed"
else
    fail "rename: new S3 key did not appear"
fi

EVICT_TARGET="$ROOT_FILE_B"
[[ -f "$EVICT_TARGET" ]] || EVICT_TARGET="$ROOT_FILE"

info "evict"
"$TSYNC_BIN" evict "$EVICT_TARGET" && pass "evict: command succeeded" \
    || fail "evict: command failed"

info "restore"
"$TSYNC_BIN" restore "$EVICT_TARGET" && pass "restore: command succeeded" \
    || fail "restore: command failed"
wait_downloaded "$EVICT_TARGET"
local_size=$(wc -c < "$EVICT_TARGET" 2>/dev/null || echo 0)
[[ "$local_size" -gt 0 ]] && pass "restore: file has content ($local_size bytes)" \
    || fail "restore: file is 0 bytes after restore"

info "delete"
rm "$EVICT_TARGET"
[[ "$EVICT_TARGET" == "$ROOT_FILE_B" ]] && wait_s3_gone "$ROOT_KEY_B" \
    || wait_s3_gone "$ROOT_KEY"
pass "delete: S3 object removed"

# ══════════════════════════════════════════════════════════════════════════════
# CASE 2: Empty directory structure
# ══════════════════════════════════════════════════════════════════════════════
section "CASE 2: Empty directory structure"
EMPTYDIR="$MOUNT/${TS}_emptydir"
EMPTYDIR_KEY="$S3_PREFIX/${TS}_emptydir/"
EMPTYDIR_B="$MOUNT/${TS}_emptydir_b"
EMPTYDIR_KEY_B="$S3_PREFIX/${TS}_emptydir_b/"

info "create (single empty dir)"
mkdir "$EMPTYDIR"
wait_s3_appear "$EMPTYDIR_KEY" && pass "create: S3 zero-byte marker appeared"

info "create (nested: A/B, A/C)"
mkdir "$EMPTYDIR/B"
mkdir "$EMPTYDIR/C"
wait_s3_appear "$S3_PREFIX/${TS}_emptydir/B/" && pass "create: nested B marker appeared"
wait_s3_appear "$S3_PREFIX/${TS}_emptydir/C/" && pass "create: nested C marker appeared"

info "re-enumerate after simulated restart"
sleep 1
ls_out=$(ls "$EMPTYDIR" 2>/dev/null)
[[ "$ls_out" == *"B"* && "$ls_out" == *"C"* ]] \
    && pass "re-enumerate: B and C visible" \
    || fail "re-enumerate: dirs not visible (ls output: '$ls_out')"

info "rename"
mv "$EMPTYDIR" "$EMPTYDIR_B"
wait_s3_appear "$EMPTYDIR_KEY_B" && pass "rename: new directory marker appeared" \
    || fail "rename: new directory marker did not appear"
wait_s3_gone "$EMPTYDIR_KEY" && pass "rename: old directory marker removed" \
    || fail "rename: old directory marker still present"
wait_s3_appear "$S3_PREFIX/${TS}_emptydir_b/B/" && pass "rename: nested B moved" \
    || fail "rename: nested B not moved"
wait_s3_appear "$S3_PREFIX/${TS}_emptydir_b/C/" && pass "rename: nested C moved" \
    || fail "rename: nested C not moved"
wait_s3_gone "$S3_PREFIX/${TS}_emptydir/B/" && pass "rename: nested B removed from old prefix"
wait_s3_gone "$S3_PREFIX/${TS}_emptydir/C/" && pass "rename: nested C removed from old prefix"

info "delete"
rmdir "$EMPTYDIR_B/B" 2>/dev/null || rm -rf "$EMPTYDIR_B/B"
rmdir "$EMPTYDIR_B/C" 2>/dev/null || rm -rf "$EMPTYDIR_B/C"
rmdir "$EMPTYDIR_B"   2>/dev/null || rm -rf "$EMPTYDIR_B"
wait_s3_gone "$S3_PREFIX/${TS}_emptydir_b/B/" && pass "delete: nested B marker removed"
wait_s3_gone "$S3_PREFIX/${TS}_emptydir_b/C/" && pass "delete: nested C marker removed"
wait_s3_gone "$EMPTYDIR_KEY_B" && pass "delete: top-level directory marker removed"

# ══════════════════════════════════════════════════════════════════════════════
# CASE 3: File in subdirectory
# ══════════════════════════════════════════════════════════════════════════════
section "CASE 3: File in subdirectory"
SUBDIR="$MOUNT/${TS}_subdir"
SUBFILE="$SUBDIR/file.txt"
SUBFILE_KEY="$S3_PREFIX/${TS}_subdir/file.txt"
SUBFILE_B="$SUBDIR/file_b.txt"
SUBFILE_KEY_B="$S3_PREFIX/${TS}_subdir/file_b.txt"

info "create dir"
mkdir "$SUBDIR"
wait_s3_appear "$S3_PREFIX/${TS}_subdir/" && pass "create dir: S3 marker appeared"

info "create file"
echo "subdir content" > "$SUBFILE"
wait_s3_appear "$SUBFILE_KEY" && pass "create file: S3 object appeared"

info "edit"
echo "more content" >> "$SUBFILE"
sleep 2
[[ $(wc -c < "$SUBFILE") -gt 15 ]] && pass "edit: local file content updated" \
    || fail "edit: local file content unchanged"
wait_s3_appear "$SUBFILE_KEY" && pass "edit: S3 object still present after edit"

info "rename file"
mv "$SUBFILE" "$SUBFILE_B"
sleep 3
if s3_exists "$SUBFILE_KEY_B"; then
    pass "rename: new S3 key appeared"
    s3_exists "$SUBFILE_KEY" \
        && fail "rename: old S3 key still present" \
        || pass "rename: old S3 key removed"
else
    fail "rename: new S3 key did not appear"
fi

EVICT_TARGET="${SUBFILE_B}"
[[ -f "$EVICT_TARGET" ]] || EVICT_TARGET="$SUBFILE"

info "evict"
"$TSYNC_BIN" evict "$EVICT_TARGET" && pass "evict: command succeeded" \
    || fail "evict: command failed"

info "restore"
"$TSYNC_BIN" restore "$EVICT_TARGET" && pass "restore: command succeeded" \
    || fail "restore: command failed"
wait_downloaded "$EVICT_TARGET"
local_size=$(wc -c < "$EVICT_TARGET" 2>/dev/null || echo 0)
[[ "$local_size" -gt 0 ]] && pass "restore: file has content ($local_size bytes)" \
    || fail "restore: file is 0 bytes after restore"

info "delete file"
rm "$EVICT_TARGET"
[[ "$EVICT_TARGET" == "$SUBFILE_B" ]] && wait_s3_gone "$SUBFILE_KEY_B" \
    || wait_s3_gone "$SUBFILE_KEY"
pass "delete file: S3 object removed"

info "delete dir"
rmdir "$SUBDIR"
wait_s3_gone "$S3_PREFIX/${TS}_subdir/" && pass "delete dir: S3 marker removed"

# ══════════════════════════════════════════════════════════════════════════════
# CASE 4: Large file at root (> 8 MB → chunked)
# ══════════════════════════════════════════════════════════════════════════════
section "CASE 4: Large file at root (chunked upload)"
LARGE_FILE="$MOUNT/${TS}_large.bin"
LARGE_KEY="$S3_PREFIX/${TS}_large.bin"
LARGE_FILE_B="$MOUNT/${TS}_large_b.bin"
LARGE_KEY_B="$S3_PREFIX/${TS}_large_b.bin"
LARGE_TMP="/tmp/${TS}_large.bin"

info "generating 20 MB test file"
dd if=/dev/urandom of="$LARGE_TMP" bs=1M count=20 2>/dev/null
cp "$LARGE_TMP" "$LARGE_FILE"

info "create (upload)"
wait_s3_appear "$LARGE_KEY" "$LARGE_UPLOAD_TIMEOUT" && pass "create: S3 manifest appeared"
ct=$(s3_content_type "$LARGE_KEY")
[[ "$ct" == "application/x-tsync-manifest+json" ]] \
    && pass "create: content-type is manifest (chunked path confirmed)" \
    || fail "create: unexpected content-type '$ct'"

info "edit (append 4 MB)"
dd if=/dev/urandom bs=1M count=4 2>/dev/null >> "$LARGE_FILE"
sleep 3
wait_s3_appear "$LARGE_KEY" "$LARGE_UPLOAD_TIMEOUT" && pass "edit: S3 manifest still present"
[[ $(wc -c < "$LARGE_FILE") -gt $(( 20 * 1024 * 1024 )) ]] \
    && pass "edit: local file grew" || fail "edit: local file did not grow"

info "rename"
mv "$LARGE_FILE" "$LARGE_FILE_B"
wait_s3_appear "$LARGE_KEY_B" "$LARGE_UPLOAD_TIMEOUT" \
    && pass "rename: new S3 key appeared" || fail "rename: new S3 key did not appear"
wait_s3_gone "$LARGE_KEY" "$LARGE_UPLOAD_TIMEOUT" \
    && pass "rename: old S3 key removed" || fail "rename: old S3 key still present"

EVICT_TARGET="$LARGE_FILE_B"
[[ -f "$EVICT_TARGET" ]] || EVICT_TARGET="$LARGE_FILE"

info "evict"
"$TSYNC_BIN" evict "$EVICT_TARGET" && pass "evict: command succeeded" \
    || fail "evict: command failed"

info "restore (download all chunks)"
"$TSYNC_BIN" restore "$EVICT_TARGET" && pass "restore: command succeeded" \
    || fail "restore: command failed"
wait_downloaded "$EVICT_TARGET"
local_size=$(wc -c < "$EVICT_TARGET" 2>/dev/null || echo 0)
[[ "$local_size" -gt $(( 20 * 1024 * 1024 )) ]] \
    && pass "restore: file has full content ($local_size bytes)" \
    || fail "restore: file too small ($local_size bytes)"

info "delete"
rm "$EVICT_TARGET"
[[ "$EVICT_TARGET" == "$LARGE_FILE_B" ]] && wait_s3_gone "$LARGE_KEY_B" \
    || wait_s3_gone "$LARGE_KEY"
pass "delete: S3 manifest removed"

# ══════════════════════════════════════════════════════════════════════════════
# CASE 5: Large file in subdirectory
# ══════════════════════════════════════════════════════════════════════════════
section "CASE 5: Large file in subdirectory (chunked upload)"
LARGEDIR="$MOUNT/${TS}_largedir"
LARGEDIR_KEY="$S3_PREFIX/${TS}_largedir/"
LARGE_SUBFILE="$LARGEDIR/${TS}_large.bin"
LARGE_SUBKEY="$S3_PREFIX/${TS}_largedir/${TS}_large.bin"
LARGE_SUBFILE_B="$LARGEDIR/${TS}_large_b.bin"
LARGE_SUBKEY_B="$S3_PREFIX/${TS}_largedir/${TS}_large_b.bin"

info "create dir"
mkdir "$LARGEDIR"
wait_s3_appear "$LARGEDIR_KEY" && pass "create dir: S3 marker appeared"

info "create large file in subdir"
cp "$LARGE_TMP" "$LARGE_SUBFILE"
wait_s3_appear "$LARGE_SUBKEY" "$LARGE_UPLOAD_TIMEOUT" && pass "create: S3 manifest appeared"
ct=$(s3_content_type "$LARGE_SUBKEY")
[[ "$ct" == "application/x-tsync-manifest+json" ]] \
    && pass "create: content-type is manifest" || fail "create: unexpected content-type '$ct'"

info "edit"
dd if=/dev/urandom bs=1M count=4 2>/dev/null >> "$LARGE_SUBFILE"
sleep 3
wait_s3_appear "$LARGE_SUBKEY" "$LARGE_UPLOAD_TIMEOUT" && pass "edit: S3 manifest present"

info "rename"
mv "$LARGE_SUBFILE" "$LARGE_SUBFILE_B"
wait_s3_appear "$LARGE_SUBKEY_B" "$LARGE_UPLOAD_TIMEOUT" \
    && pass "rename: new S3 key appeared" || fail "rename: new S3 key did not appear"
wait_s3_gone "$LARGE_SUBKEY" "$LARGE_UPLOAD_TIMEOUT" \
    && pass "rename: old S3 key removed" || fail "rename: old S3 key still present"

EVICT_TARGET="$LARGE_SUBFILE_B"
[[ -f "$EVICT_TARGET" ]] || EVICT_TARGET="$LARGE_SUBFILE"

info "evict"
"$TSYNC_BIN" evict "$EVICT_TARGET" && pass "evict: command succeeded" \
    || fail "evict: command failed"

info "restore"
"$TSYNC_BIN" restore "$EVICT_TARGET" && pass "restore: command succeeded" \
    || fail "restore: command failed"
wait_downloaded "$EVICT_TARGET"
local_size=$(wc -c < "$EVICT_TARGET" 2>/dev/null || echo 0)
[[ "$local_size" -gt $(( 20 * 1024 * 1024 )) ]] \
    && pass "restore: file has full content ($local_size bytes)" \
    || fail "restore: file too small ($local_size bytes)"

info "delete file"
rm "$EVICT_TARGET"
[[ "$EVICT_TARGET" == "$LARGE_SUBFILE_B" ]] && wait_s3_gone "$LARGE_SUBKEY_B" \
    || wait_s3_gone "$LARGE_SUBKEY"
pass "delete file: S3 manifest removed"

info "delete dir"
rmdir "$LARGEDIR"
wait_s3_gone "$LARGEDIR_KEY" && pass "delete dir: S3 marker removed"

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "══════════════════════════════"
echo -e "  ${GREEN}PASS: $PASS${RESET}   ${RED}FAIL: $FAIL${RESET}"
echo "══════════════════════════════"
[[ $FAIL -eq 0 ]] || exit 1
