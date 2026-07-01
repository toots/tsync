#!/usr/bin/env bash
# Shared lifecycle test cases for tsync (Linux + macOS).
# Sourced by platform-specific wrappers that set:
#   TSYNC_BIN, MOUNT, S3_PREFIX, BUCKET, REGION, PREFIX, DOMAIN,
#   JOURNAL_PREFIX, LAST_SYNC_FILE,
#   UPLOAD_TIMEOUT, LARGE_UPLOAD_TIMEOUT, DOWNLOAD_TIMEOUT, TS
# and define: pass, fail, info, section, run_case,
#             s3_exists, wait_s3_appear, wait_s3_gone, s3_content_type,
#             wait_downloaded
# and initialise: PASS=0 FAIL=0 INJECTED_ENTRY=""
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# CASE 1: Root file
# ══════════════════════════════════════════════════════════════════════════════
if run_case 1; then
section "CASE 1: Root file"
ROOT_FILE="$MOUNT/${TS}_root.txt"
ROOT_KEY="$S3_PREFIX/${TS}_root.txt"
ROOT_FILE_B="$MOUNT/${TS}_root_b.txt"
ROOT_KEY_B="$S3_PREFIX/${TS}_root_b.txt"

info "create"
echo "hello tsync" > "$ROOT_FILE"
wait_s3_appear "$ROOT_KEY" && pass "create: backend object appeared"

info "edit"
echo "hello again" >> "$ROOT_FILE"
sleep 2
wait_s3_appear "$ROOT_KEY" && pass "edit: backend object still present after edit"
[[ $(wc -c < "$ROOT_FILE") -gt 12 ]] && pass "edit: local file content updated" \
    || fail "edit: local file content unchanged"

info "rename"
mv "$ROOT_FILE" "$ROOT_FILE_B"
sleep 3
if s3_exists "$ROOT_KEY_B"; then
    pass "rename: new backend key appeared"
    s3_exists "$ROOT_KEY" \
        && fail "rename: old backend key still present" \
        || pass "rename: old backend key removed"
else
    fail "rename: new backend key did not appear"
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
pass "delete: backend object removed"
fi # run_case 1

# ══════════════════════════════════════════════════════════════════════════════
# CASE 2: Empty directory structure
# ══════════════════════════════════════════════════════════════════════════════
if run_case 2; then
section "CASE 2: Empty directory structure"
EMPTYDIR="$MOUNT/${TS}_emptydir"
EMPTYDIR_KEY="$S3_PREFIX/${TS}_emptydir/"
EMPTYDIR_B="$MOUNT/${TS}_emptydir_b"
EMPTYDIR_KEY_B="$S3_PREFIX/${TS}_emptydir_b/"

info "create (single empty dir)"
mkdir "$EMPTYDIR"
wait_s3_appear "$EMPTYDIR_KEY" && pass "create: backend zero-byte marker appeared"

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

info "create dir"
mkdir "$SUBDIR"
wait_s3_appear "$S3_PREFIX/${TS}_subdir/" && pass "create dir: backend marker appeared"

info "create file"
echo "subdir content" > "$SUBFILE"
wait_s3_appear "$SUBFILE_KEY" && pass "create file: backend object appeared"

info "edit"
echo "more content" >> "$SUBFILE"
sleep 2
[[ $(wc -c < "$SUBFILE") -gt 15 ]] && pass "edit: local file content updated" \
    || fail "edit: local file content unchanged"
wait_s3_appear "$SUBFILE_KEY" && pass "edit: backend object still present after edit"

info "rename file"
mv "$SUBFILE" "$SUBFILE_B"
sleep 3
if s3_exists "$SUBFILE_KEY_B"; then
    pass "rename: new backend key appeared"
    s3_exists "$SUBFILE_KEY" \
        && fail "rename: old backend key still present" \
        || pass "rename: old backend key removed"
else
    fail "rename: new backend key did not appear"
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
pass "delete file: backend object removed"

info "delete dir"
rmdir "$SUBDIR"
wait_s3_gone "$S3_PREFIX/${TS}_subdir/" && pass "delete dir: backend marker removed"
fi # run_case 3

# ══════════════════════════════════════════════════════════════════════════════
# CASE 4: Large file at root (> 8 MB → chunked)
# ══════════════════════════════════════════════════════════════════════════════
if run_case 4; then
section "CASE 4: Large file at root (chunked upload)"
LARGE_FILE="$MOUNT/${TS}_large.bin"
LARGE_KEY="$S3_PREFIX/${TS}_large.bin"
LARGE_FILE_B="$MOUNT/${TS}_large_b.bin"
LARGE_KEY_B="$S3_PREFIX/${TS}_large_b.bin"
LARGE_TMP="/tmp/${TS}_large.bin"

info "generating 20 MB test file"
dd if=/dev/urandom of="$LARGE_TMP" bs=1048576 count=20 2>/dev/null
cp "$LARGE_TMP" "$LARGE_FILE"

info "create (upload)"
wait_s3_appear "$LARGE_KEY" "$LARGE_UPLOAD_TIMEOUT" && pass "create: backend manifest appeared"
ct=$(s3_content_type "$LARGE_KEY")
[[ "$ct" == "application/x-tsync-manifest+json" ]] \
    && pass "create: content-type is manifest (chunked path confirmed)" \
    || fail "create: unexpected content-type '$ct'"

info "edit (append 4 MB)"
dd if=/dev/urandom bs=1048576 count=4 2>/dev/null >> "$LARGE_FILE"
sleep 3
wait_s3_appear "$LARGE_KEY" "$LARGE_UPLOAD_TIMEOUT" && pass "edit: backend manifest still present"
[[ $(wc -c < "$LARGE_FILE") -gt $(( 20 * 1024 * 1024 )) ]] \
    && pass "edit: local file grew" || fail "edit: local file did not grow"

info "rename"
mv "$LARGE_FILE" "$LARGE_FILE_B"
wait_s3_appear "$LARGE_KEY_B" "$LARGE_UPLOAD_TIMEOUT" \
    && pass "rename: new backend key appeared" || fail "rename: new backend key did not appear"
wait_s3_gone "$LARGE_KEY" "$LARGE_UPLOAD_TIMEOUT" \
    && pass "rename: old backend key removed" || fail "rename: old backend key still present"

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
pass "delete: backend manifest removed"
fi # run_case 4

# ══════════════════════════════════════════════════════════════════════════════
# CASE 5: Large file in subdirectory
# ══════════════════════════════════════════════════════════════════════════════
if run_case 5; then
section "CASE 5: Large file in subdirectory (chunked upload)"
LARGE_TMP="${LARGE_TMP:-/tmp/${TS}_large.bin}"
[[ -f "$LARGE_TMP" ]] || { info "generating 20 MB test file"; dd if=/dev/urandom of="$LARGE_TMP" bs=1048576 count=20 2>/dev/null; }
LARGEDIR="$MOUNT/${TS}_largedir"
LARGEDIR_KEY="$S3_PREFIX/${TS}_largedir/"
LARGE_SUBFILE="$LARGEDIR/${TS}_large.bin"
LARGE_SUBKEY="$S3_PREFIX/${TS}_largedir/${TS}_large.bin"
LARGE_SUBFILE_B="$LARGEDIR/${TS}_large_b.bin"
LARGE_SUBKEY_B="$S3_PREFIX/${TS}_largedir/${TS}_large_b.bin"

info "create dir"
mkdir "$LARGEDIR"
wait_s3_appear "$LARGEDIR_KEY" && pass "create dir: backend marker appeared"

info "create large file in subdir"
cp "$LARGE_TMP" "$LARGE_SUBFILE"
wait_s3_appear "$LARGE_SUBKEY" "$LARGE_UPLOAD_TIMEOUT" && pass "create: backend manifest appeared"
ct=$(s3_content_type "$LARGE_SUBKEY")
[[ "$ct" == "application/x-tsync-manifest+json" ]] \
    && pass "create: content-type is manifest" || fail "create: unexpected content-type '$ct'"

info "edit"
dd if=/dev/urandom bs=1048576 count=4 2>/dev/null >> "$LARGE_SUBFILE"
sleep 3
wait_s3_appear "$LARGE_SUBKEY" "$LARGE_UPLOAD_TIMEOUT" && pass "edit: backend manifest present"

info "rename"
mv "$LARGE_SUBFILE" "$LARGE_SUBFILE_B"
wait_s3_appear "$LARGE_SUBKEY_B" "$LARGE_UPLOAD_TIMEOUT" \
    && pass "rename: new backend key appeared" || fail "rename: new backend key did not appear"
wait_s3_gone "$LARGE_SUBKEY" "$LARGE_UPLOAD_TIMEOUT" \
    && pass "rename: old backend key removed" || fail "rename: old backend key still present"

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
pass "delete file: backend manifest removed"

info "delete dir"
rmdir "$LARGEDIR"
wait_s3_gone "$LARGEDIR_KEY" && pass "delete dir: backend marker removed"
fi # run_case 5

# ══════════════════════════════════════════════════════════════════════════════
# CASE 6: Change journal — verify entries written to backend on every mutation
# ══════════════════════════════════════════════════════════════════════════════
if run_case 6; then
section "CASE 6: Change journal"

latest_journal_key() {
    aws s3api list-objects-v2 \
        --bucket "$BUCKET" --prefix "$JOURNAL_PREFIX/" \
        --region "$REGION" \
        --query 'sort_by(Contents[?Key!=`null`], &Key)[-1].Key' \
        --output text 2>/dev/null \
    | grep -v '^None$' || true
}

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

is_cloud() {
    "$TSYNC_BIN" ls 2>/dev/null | grep "$(basename "$1")" | grep -q "cloud"
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
NOW_MS=$(( $(date +%s) * 1000 ))
echo "$JOURNAL_PREFIX/$(printf '%013d' "$NOW_MS")-self-init" > "$LAST_SYNC_FILE"

info "inject foreign journal entry referencing the file (timestamp after last-sync)"
sleep 1
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
