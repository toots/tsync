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

# ══════════════════════════════════════════════════════════════════════════════
# CASE 1: Root file
# ══════════════════════════════════════════════════════════════════════════════
if run_case 1; then
section "CASE 1: Root file"
ROOT_FILE="$MOUNT/${TS}_root.txt"
ROOT_KEY="$S3_PREFIX/${TS}_root.txt"
ROOT_FILE_B="$MOUNT/${TS}_root_b.txt"
ROOT_KEY_B="$S3_PREFIX/${TS}_root_b.txt"

# Create
info "create"
echo "hello tsync" > "$ROOT_FILE"
wait_s3_appear "$ROOT_KEY" && pass "create: S3 object appeared"

# Edit
info "edit"
echo "hello again" >> "$ROOT_FILE"
# content changes → new upload; wait for S3 to reflect update (etag changes)
sleep 2  # give FP time to notice the change
wait_s3_appear "$ROOT_KEY" && pass "edit: S3 object still present after edit"
# Verify content size grew (local check; S3 size would need head-object)
[[ $(wc -c < "$ROOT_FILE") -gt 12 ]] && pass "edit: local file content updated" \
    || fail "edit: local file content unchanged"

# Rename
info "rename"
mv "$ROOT_FILE" "$ROOT_FILE_B"
# Current implementation: modifyItem with .filename change doesn't rekey in S3.
# So old key stays; new key may or may not appear. Test both.
sleep 3
if s3_exists "$ROOT_KEY_B"; then
    pass "rename: new S3 key appeared"
    if ! s3_exists "$ROOT_KEY"; then
        pass "rename: old S3 key removed"
    else
        fail "rename: old S3 key still present (copy-without-delete bug)"
    fi
else
    fail "rename: new S3 key did not appear (rename not re-keyed in S3)"
    # Restore old name so evict/restore can proceed
    cp "$ROOT_FILE_B" "$ROOT_FILE" 2>/dev/null || true
fi

# Use whichever file exists for evict/restore
EVICT_TARGET="$ROOT_FILE_B"
[[ -f "$EVICT_TARGET" ]] || EVICT_TARGET="$ROOT_FILE"

# Evict
info "evict"
"$TSYNC_BIN" evict "$EVICT_TARGET" && pass "evict: command succeeded" \
    || fail "evict: command failed"

# Restore
info "restore"
"$TSYNC_BIN" restore "$EVICT_TARGET" && pass "restore: command succeeded" \
    || fail "restore: command failed"
wait_downloaded "$EVICT_TARGET"
local_size=$(wc -c < "$EVICT_TARGET" 2>/dev/null || echo 0)
[[ "$local_size" -gt 0 ]] && pass "restore: file has content ($local_size bytes)" \
    || fail "restore: file is 0 bytes after restore"

# Delete
info "delete"
rm "$EVICT_TARGET"
[[ "$EVICT_TARGET" == "$ROOT_FILE_B" ]] && wait_s3_gone "$ROOT_KEY_B" \
    || wait_s3_gone "$ROOT_KEY"
pass "delete: S3 object removed"

fi # run_case 1

# ══════════════════════════════════════════════════════════════════════════════
# CASE 2: Empty directory structure (A/B/C all empty)
# ══════════════════════════════════════════════════════════════════════════════
if run_case 2; then
section "CASE 2: Empty directory structure"
EMPTYDIR="$MOUNT/${TS}_emptydir"
EMPTYDIR_KEY="$S3_PREFIX/${TS}_emptydir/"
EMPTYDIR_B="$MOUNT/${TS}_emptydir_b"
EMPTYDIR_KEY_B="$S3_PREFIX/${TS}_emptydir_b/"

# Create single empty dir
info "create (single empty dir)"
mkdir "$EMPTYDIR"
wait_s3_appear "$EMPTYDIR_KEY" && pass "create: S3 zero-byte marker appeared"

# Create nested empty dirs inside
info "create (nested: A/B, A/C)"
mkdir "$EMPTYDIR/B"
mkdir "$EMPTYDIR/C"
wait_s3_appear "$S3_PREFIX/${TS}_emptydir/B/" && pass "create: nested B marker appeared"
wait_s3_appear "$S3_PREFIX/${TS}_emptydir/C/" && pass "create: nested C marker appeared"

# Simulate restart: verify dirs re-enumerate after fresh listing
info "re-enumerate after simulated restart"
sleep 1
ls_out=$(ls "$EMPTYDIR" 2>/dev/null)
[[ "$ls_out" == *"B"* && "$ls_out" == *"C"* ]] \
    && pass "re-enumerate: B and C visible" \
    || fail "re-enumerate: dirs not visible (ls output: '$ls_out')"

# Rename top-level empty dir (renameDirectory recursively moves all objects)
info "rename"
mv "$EMPTYDIR" "$EMPTYDIR_B"
wait_s3_appear "$EMPTYDIR_KEY_B" && pass "rename: new directory marker appeared" \
    || fail "rename: new directory marker did not appear"
wait_s3_gone "$EMPTYDIR_KEY" && pass "rename: old directory marker removed" \
    || fail "rename: old directory marker still present on S3"
wait_s3_appear "$S3_PREFIX/${TS}_emptydir_b/B/" && pass "rename: nested B moved to new prefix" \
    || fail "rename: nested B not moved"
wait_s3_appear "$S3_PREFIX/${TS}_emptydir_b/C/" && pass "rename: nested C moved to new prefix" \
    || fail "rename: nested C not moved"
wait_s3_gone "$S3_PREFIX/${TS}_emptydir/B/" && pass "rename: nested B removed from old prefix" \
    || fail "rename: nested B still at old prefix"
wait_s3_gone "$S3_PREFIX/${TS}_emptydir/C/" && pass "rename: nested C removed from old prefix" \
    || fail "rename: nested C still at old prefix"

# Delete (macOS calls deleteItem only for top-level dir; S3Store.delete now recurses)
info "delete"
rmdir "$EMPTYDIR_B/B" 2>/dev/null || rm -rf "$EMPTYDIR_B/B"
rmdir "$EMPTYDIR_B/C" 2>/dev/null || rm -rf "$EMPTYDIR_B/C"
rmdir "$EMPTYDIR_B" 2>/dev/null || rm -rf "$EMPTYDIR_B"
wait_s3_gone "$S3_PREFIX/${TS}_emptydir_b/B/" && pass "delete: nested B marker removed"
wait_s3_gone "$S3_PREFIX/${TS}_emptydir_b/C/" && pass "delete: nested C marker removed"
wait_s3_gone "$EMPTYDIR_KEY_B" && pass "delete: top-level directory marker removed"

fi # run_case 2

# ══════════════════════════════════════════════════════════════════════════════
# CASE 3: File in subdirectory
# ══════════════════════════════════════════════════════════════════════════════
if run_case 3; then
section "CASE 3: File in subdirectory"
SUBDIR="$MOUNT/${TS}_subdir"
SUBFILE="$SUBDIR/file.txt"
SUBFILE_KEY="$S3_PREFIX/${TS}_subdir/file.txt"
SUBFILE_B="$SUBDIR/file_b.txt"
SUBFILE_KEY_B="$S3_PREFIX/${TS}_subdir/file_b.txt"

# Create dir + file
info "create dir"
mkdir "$SUBDIR"
wait_s3_appear "$S3_PREFIX/${TS}_subdir/" && pass "create dir: S3 marker appeared"

info "create file"
echo "subdir content" > "$SUBFILE"
wait_s3_appear "$SUBFILE_KEY" && pass "create file: S3 object appeared"

# Edit
info "edit"
echo "more content" >> "$SUBFILE"
sleep 2
[[ $(wc -c < "$SUBFILE") -gt 15 ]] && pass "edit: local file content updated" \
    || fail "edit: local file content unchanged"
wait_s3_appear "$SUBFILE_KEY" && pass "edit: S3 object still present after edit"

# Rename file (within same dir)
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

# Evict
info "evict"
"$TSYNC_BIN" evict "$EVICT_TARGET" && pass "evict: command succeeded" \
    || fail "evict: command failed"

# Restore
info "restore"
"$TSYNC_BIN" restore "$EVICT_TARGET" && pass "restore: command succeeded" \
    || fail "restore: command failed"
wait_downloaded "$EVICT_TARGET"
local_size=$(wc -c < "$EVICT_TARGET" 2>/dev/null || echo 0)
[[ "$local_size" -gt 0 ]] && pass "restore: file has content ($local_size bytes)" \
    || fail "restore: file is 0 bytes after restore"

# Delete file, then dir
info "delete file"
rm "$EVICT_TARGET"
[[ "$EVICT_TARGET" == "$SUBFILE_B" ]] && wait_s3_gone "$SUBFILE_KEY_B" \
    || wait_s3_gone "$SUBFILE_KEY"
pass "delete file: S3 object removed"

info "delete dir"
rmdir "$SUBDIR"
wait_s3_gone "$S3_PREFIX/${TS}_subdir/" && pass "delete dir: S3 marker removed"

fi # run_case 3

# ══════════════════════════════════════════════════════════════════════════════
# CASE 4: Large file at root (> 8 MB → chunked manifest path)
# ══════════════════════════════════════════════════════════════════════════════
if run_case 4; then
section "CASE 4: Large file at root (chunked upload)"
LARGE_FILE="$MOUNT/${TS}_large.bin"
LARGE_KEY="$S3_PREFIX/${TS}_large.bin"
LARGE_FILE_B="$MOUNT/${TS}_large_b.bin"
LARGE_KEY_B="$S3_PREFIX/${TS}_large_b.bin"
LARGE_TMP="/tmp/${TS}_large.bin"

# Generate a 20 MB file locally first (faster than writing via FUSE)
info "generating 20 MB test file"
dd if=/dev/urandom of="$LARGE_TMP" bs=1m count=20 2>/dev/null
cp "$LARGE_TMP" "$LARGE_FILE"

# Create
info "create (upload)"
wait_s3_appear "$LARGE_KEY" "$LARGE_UPLOAD_TIMEOUT" && pass "create: S3 manifest appeared"
ct=$(s3_content_type "$LARGE_KEY")
[[ "$ct" == "application/x-tsync-manifest+json" ]] \
    && pass "create: content-type is manifest (chunked path confirmed)" \
    || fail "create: unexpected content-type '$ct' (expected manifest)"

# Edit (append 4 MB — modifies only the last chunk)
info "edit (append 4 MB, partial re-upload)"
dd if=/dev/urandom bs=1m count=4 2>/dev/null >> "$LARGE_FILE"
sleep 3
wait_s3_appear "$LARGE_KEY" "$LARGE_UPLOAD_TIMEOUT" && pass "edit: S3 manifest still present after edit"
[[ $(wc -c < "$LARGE_FILE") -gt $(( 20 * 1024 * 1024 )) ]] \
    && pass "edit: local file grew" \
    || fail "edit: local file did not grow"

# Rename
info "rename"
mv "$LARGE_FILE" "$LARGE_FILE_B"
wait_s3_appear "$LARGE_KEY_B" "$LARGE_UPLOAD_TIMEOUT" \
    && pass "rename: new S3 key appeared" \
    || fail "rename: new S3 key did not appear"
wait_s3_gone "$LARGE_KEY" "$LARGE_UPLOAD_TIMEOUT" \
    && pass "rename: old S3 key removed" \
    || fail "rename: old S3 key still present"

EVICT_TARGET="$LARGE_FILE_B"
[[ -f "$EVICT_TARGET" ]] || EVICT_TARGET="$LARGE_FILE"

# Evict
info "evict"
"$TSYNC_BIN" evict "$EVICT_TARGET" && pass "evict: command succeeded" \
    || fail "evict: command failed"

# Restore
info "restore (download all chunks)"
"$TSYNC_BIN" restore "$EVICT_TARGET" && pass "restore: command succeeded" \
    || fail "restore: command failed"
wait_downloaded "$EVICT_TARGET"
local_size=$(wc -c < "$EVICT_TARGET" 2>/dev/null || echo 0)
[[ "$local_size" -gt $(( 20 * 1024 * 1024 )) ]] \
    && pass "restore: file has full content ($local_size bytes)" \
    || fail "restore: file too small after restore ($local_size bytes)"

# Delete
info "delete"
rm "$EVICT_TARGET"
[[ "$EVICT_TARGET" == "$LARGE_FILE_B" ]] && wait_s3_gone "$LARGE_KEY_B" "$UPLOAD_TIMEOUT" \
    || wait_s3_gone "$LARGE_KEY" "$UPLOAD_TIMEOUT"
pass "delete: S3 manifest removed"

fi # run_case 4

# ══════════════════════════════════════════════════════════════════════════════
# CASE 5: Large file in subdirectory (chunked)
# ══════════════════════════════════════════════════════════════════════════════
if run_case 5; then
section "CASE 5: Large file in subdirectory (chunked upload)"
# Generate temp file if case 4 was skipped
LARGE_TMP="${LARGE_TMP:-/tmp/${TS}_large.bin}"
[[ -f "$LARGE_TMP" ]] || { info "generating 20 MB test file"; dd if=/dev/urandom of="$LARGE_TMP" bs=1m count=20 2>/dev/null; }
LARGEDIR="$MOUNT/${TS}_largedir"
LARGEDIR_KEY="$S3_PREFIX/${TS}_largedir/"
LARGE_SUBFILE="$LARGEDIR/${TS}_large.bin"
LARGE_SUBKEY="$S3_PREFIX/${TS}_largedir/${TS}_large.bin"
LARGE_SUBFILE_B="$LARGEDIR/${TS}_large_b.bin"
LARGE_SUBKEY_B="$S3_PREFIX/${TS}_largedir/${TS}_large_b.bin"

# Create dir
info "create dir"
mkdir "$LARGEDIR"
wait_s3_appear "$LARGEDIR_KEY" && pass "create dir: S3 marker appeared"

# Create large file in subdir (reuse temp file)
info "create large file in subdir"
cp "$LARGE_TMP" "$LARGE_SUBFILE"
wait_s3_appear "$LARGE_SUBKEY" "$LARGE_UPLOAD_TIMEOUT" && pass "create: S3 manifest appeared"
ct=$(s3_content_type "$LARGE_SUBKEY")
[[ "$ct" == "application/x-tsync-manifest+json" ]] \
    && pass "create: content-type is manifest (chunked path confirmed)" \
    || fail "create: unexpected content-type '$ct'"

# Edit
info "edit"
dd if=/dev/urandom bs=1m count=4 2>/dev/null >> "$LARGE_SUBFILE"
sleep 3
wait_s3_appear "$LARGE_SUBKEY" "$LARGE_UPLOAD_TIMEOUT" && pass "edit: S3 manifest present after edit"

# Rename
info "rename"
mv "$LARGE_SUBFILE" "$LARGE_SUBFILE_B"
wait_s3_appear "$LARGE_SUBKEY_B" "$LARGE_UPLOAD_TIMEOUT" \
    && pass "rename: new S3 key appeared" \
    || fail "rename: new S3 key did not appear"
wait_s3_gone "$LARGE_SUBKEY" "$LARGE_UPLOAD_TIMEOUT" \
    && pass "rename: old S3 key removed" \
    || fail "rename: old S3 key still present"

EVICT_TARGET="$LARGE_SUBFILE_B"
[[ -f "$EVICT_TARGET" ]] || EVICT_TARGET="$LARGE_SUBFILE"

# Evict
info "evict"
"$TSYNC_BIN" evict "$EVICT_TARGET" && pass "evict: command succeeded" \
    || fail "evict: command failed"

# Restore
info "restore"
"$TSYNC_BIN" restore "$EVICT_TARGET" && pass "restore: command succeeded" \
    || fail "restore: command failed"
wait_downloaded "$EVICT_TARGET"
local_size=$(wc -c < "$EVICT_TARGET" 2>/dev/null || echo 0)
[[ "$local_size" -gt $(( 20 * 1024 * 1024 )) ]] \
    && pass "restore: file has full content ($local_size bytes)" \
    || fail "restore: file too small after restore ($local_size bytes)"

# Delete file, then dir
info "delete file"
rm "$EVICT_TARGET"
[[ "$EVICT_TARGET" == "$LARGE_SUBFILE_B" ]] && wait_s3_gone "$LARGE_SUBKEY_B" "$UPLOAD_TIMEOUT" \
    || wait_s3_gone "$LARGE_SUBKEY" "$UPLOAD_TIMEOUT"
pass "delete file: S3 manifest removed"

info "delete dir"
rmdir "$LARGEDIR"
wait_s3_gone "$LARGEDIR_KEY" && pass "delete dir: S3 marker removed"

fi # run_case 5

# ══════════════════════════════════════════════════════════════════════════════
# CASE 6: Change journal — verify entries written to S3 on every mutation
# ══════════════════════════════════════════════════════════════════════════════
if run_case 6; then
section "CASE 6: Change journal"

# Returns the lexicographically latest S3 key under JOURNAL_PREFIX, or empty.
latest_journal_key() {
    aws s3api list-objects-v2 \
        --bucket "$BUCKET" --prefix "$JOURNAL_PREFIX/" \
        --region "$REGION" \
        --query 'sort_by(Contents[?Key!=`null`], &Key)[-1].Key' \
        --output text 2>/dev/null \
    | grep -v '^None$' || true
}

# Waits until a journal key newer than $1 appears (or any key if $1 is empty).
wait_journal_after() {
    local marker="$1" timeout="${2:-$UPLOAD_TIMEOUT}"
    local deadline=$(( $(date +%s) + timeout ))
    while true; do
        local latest
        latest=$(latest_journal_key)
        if [[ -n "$latest" ]] && { [[ -z "$marker" ]] || [[ "$latest" > "$marker" ]]; }; then
            echo "$latest"; return 0
        fi
        [[ $(date +%s) -lt $deadline ]] || return 1
        sleep 1
    done
}

# Reads and prints an S3 journal entry's body.
read_journal_entry() {
    aws s3 cp "s3://$BUCKET/$1" - --region "$REGION" 2>/dev/null
}

JFILE="$MOUNT/${TS}_jtest.txt"
JKEY="$S3_PREFIX/${TS}_jtest.txt"
JFILE_B="$MOUNT/${TS}_jtest_b.txt"
JKEY_B="$S3_PREFIX/${TS}_jtest_b.txt"
JDIR="$MOUNT/${TS}_jdir"
JDIR_KEY="$S3_PREFIX/${TS}_jdir/"

info "create → expect 'put' journal entry"
marker=$(latest_journal_key)
echo "journal test" > "$JFILE"
wait_s3_appear "$JKEY"
if entry_key=$(wait_journal_after "$marker"); then
    body=$(read_journal_entry "$entry_key")
    if echo "$body" | grep -q '"op":"put"' && echo "$body" | grep -q "${TS}_jtest.txt"; then
        pass "journal: put entry written on create"
    else
        fail "journal: put entry wrong content (got: $body)"
    fi
else
    fail "journal: no entry after create (timeout)"
fi

info "rename → expect 'rename' journal entry"
marker=$(latest_journal_key)
mv "$JFILE" "$JFILE_B"
wait_s3_appear "$JKEY_B"
if entry_key=$(wait_journal_after "$marker"); then
    body=$(read_journal_entry "$entry_key")
    if echo "$body" | grep -q '"op":"rename"' \
        && echo "$body" | grep -q '"src"' \
        && echo "$body" | grep -q "${TS}_jtest"; then
        pass "journal: rename entry written with src and key"
    else
        fail "journal: rename entry wrong content (got: $body)"
    fi
else
    fail "journal: no entry after rename (timeout)"
fi

info "delete → expect 'delete' journal entry"
marker=$(latest_journal_key)
rm "$JFILE_B"
wait_s3_gone "$JKEY_B"
if entry_key=$(wait_journal_after "$marker"); then
    body=$(read_journal_entry "$entry_key")
    if echo "$body" | grep -q '"op":"delete"'; then
        pass "journal: delete entry written"
    else
        fail "journal: delete entry wrong content (got: $body)"
    fi
else
    fail "journal: no entry after delete (timeout)"
fi

info "mkdir → expect 'mkdir' journal entry"
marker=$(latest_journal_key)
mkdir "$JDIR"
wait_s3_appear "$JDIR_KEY"
if entry_key=$(wait_journal_after "$marker"); then
    body=$(read_journal_entry "$entry_key")
    if echo "$body" | grep -q '"op":"mkdir"'; then
        pass "journal: mkdir entry written"
    else
        fail "journal: mkdir entry wrong content (got: $body)"
    fi
else
    fail "journal: no entry after mkdir (timeout)"
fi

info "rmdir → expect 'rmdir' journal entry"
marker=$(latest_journal_key)
rmdir "$JDIR"
wait_s3_gone "$JDIR_KEY"
if entry_key=$(wait_journal_after "$marker"); then
    body=$(read_journal_entry "$entry_key")
    if echo "$body" | grep -q '"op":"rmdir"'; then
        pass "journal: rmdir entry written"
    else
        fail "journal: rmdir entry wrong content (got: $body)"
    fi
else
    fail "journal: no entry after rmdir (timeout)"
fi

fi # run_case 6

# ══════════════════════════════════════════════════════════════════════════════
# CASE 7: tsync sync
# ══════════════════════════════════════════════════════════════════════════════
if run_case 7; then
section "CASE 7: tsync sync"

SFILE="$MOUNT/${TS}_sync.txt"
SKEY="$S3_PREFIX/${TS}_sync.txt"

# Helper: check if a file shows as "cloud" (evicted) in tsync ls output.
is_cloud() {
    "$TSYNC_BIN" ls "$MOUNT" 2>/dev/null | grep "$(basename "$1")" | grep -q "cloud"
}

info "create and restore file so it is locally available"
echo "sync test" > "$SFILE"
wait_s3_appear "$SKEY"
"$TSYNC_BIN" restore "$SFILE"
wait_downloaded "$SFILE"
is_cloud "$SFILE" \
    && fail "sync setup: file should be local after restore" \
    || pass "sync setup: file is local after restore"

info "seed last-sync with current timestamp so incremental path is taken"
# Use a timestamp that's after any existing journal entry but before the injected one.
# oldest_ms <= last_sync_ms means incremental; we'll set last-sync to now.
NOW_MS=$(( $(date +%s) * 1000 ))
echo "$JOURNAL_PREFIX/$(printf '%013d' "$NOW_MS")-self-init" > "$LAST_SYNC_FILE"

info "inject foreign journal entry referencing the file (timestamp after last-sync)"
sleep 1   # ensure injected timestamp > last-sync timestamp
FOREIGN_UUID="00000000-0000-0000-0000-000000000001"
ENTRY_MS=$(( $(date +%s) * 1000 ))
ENTRY_FILENAME="$(printf '%013d' "$ENTRY_MS")-$FOREIGN_UUID"
INJECTED_ENTRY="$JOURNAL_PREFIX/$ENTRY_FILENAME"
printf '{"op":"put","key":"%s","size":9}\n' "${TS}_sync.txt" \
    | aws s3 cp - "s3://$BUCKET/$INJECTED_ENTRY" \
        --region "$REGION" --content-type "application/x-ndjson"
pass "sync: foreign journal entry injected"

info "tsync sync — incremental, should evict file via foreign entry"
"$TSYNC_BIN" sync
is_cloud "$SFILE" \
    && pass "sync: file evicted by foreign journal entry" \
    || fail "sync: file still local after sync (eviction not triggered)"

info "last-sync state file updated"
[[ -f "$LAST_SYNC_FILE" ]] \
    && pass "sync: last-sync file exists" \
    || fail "sync: last-sync file missing"
stored_key=$(cat "$LAST_SYNC_FILE")
[[ "$stored_key" == *"$ENTRY_FILENAME"* || "$stored_key" > "$JOURNAL_PREFIX/$(printf '%013d' "$NOW_MS")" ]] \
    && pass "sync: last-sync advanced past injected entry" \
    || fail "sync: last-sync not advanced (got: $stored_key)"

info "restore file, then sync again — own UUID not evicted"
"$TSYNC_BIN" restore "$SFILE"
wait_downloaded "$SFILE"
# Write own file (extension writes journal entry with our UUID)
echo "updated" > "$SFILE"
wait_s3_appear "$SKEY"
"$TSYNC_BIN" sync
is_cloud "$SFILE" \
    && fail "sync: own-UUID entry incorrectly evicted file" \
    || pass "sync: own-UUID entry filtered (file stays local)"

info "simulate journal gap → full resync"
echo "$JOURNAL_PREFIX/0000000000001-fake" > "$LAST_SYNC_FILE"
"$TSYNC_BIN" sync
new_stored=$(cat "$LAST_SYNC_FILE" 2>/dev/null || true)
new_filename="${new_stored##*/}"
new_ms="${new_filename:0:13}"
now_ms=$(( $(date +%s) * 1000 ))
diff=$(( now_ms - new_ms ))
[[ "$diff" -lt 120000 ]] \
    && pass "sync: full resync updated last-sync to recent timestamp" \
    || fail "sync: full resync last-sync not recent (diff: ${diff}ms, key: $new_stored)"

fi # run_case 7

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo
echo "══════════════════════════════"
echo -e "  ${GREEN}PASS: $PASS${RESET}   ${RED}FAIL: $FAIL${RESET}"
echo "══════════════════════════════"
[[ $FAIL -eq 0 ]] || exit 1
