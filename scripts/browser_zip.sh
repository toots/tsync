#!/bin/sh
# Builds dist/tsync-browser-extension.zip, the package uploaded to the Chrome
# Web Store (passwords/browser §2), from browser/ without its tests, then reads
# it back to check it. Run from the repo root.
set -eu

RUN_NUMBER=${RUN_NUMBER:-0}
DATE=${BUILD_DATE:-$(date -u +%Y%m%d)}
# Chrome reads up to four integers of at most 65535, without leading zeros,
# and the store takes an upload only above the last one.
year=${DATE%????}
monthday=$(echo "${DATE#????}" | sed 's/^0*//')
version="1.$year.$monthday.$RUN_NUMBER"
[ "$RUN_NUMBER" -le 65535 ] || { echo "run number $RUN_NUMBER above 65535" >&2; exit 1; }

out=dist/tsync-browser-extension.zip
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
(cd browser && tar cf - --exclude test .) | (cd "$stage" && tar xf -)
# The store refuses a manifest carrying `key`: it signs with its item's own.
python3 - "$stage/manifest.json" "$version" <<'EOF'
import json, sys
path, version = sys.argv[1:]
manifest = json.load(open(path))
del manifest["key"]
manifest["version"] = version
json.dump(manifest, open(path, "w"), indent=2)
EOF
mkdir -p dist
rm -f "$out"
(cd "$stage" && zip -qrX - .) > "$out"

check=$(mktemp -d)
trap 'rm -rf "$stage" "$check"' EXIT
unzip -q "$out" -d "$check"
python3 - "$check/manifest.json" "$version" <<'EOF'
import json, sys
path, version = sys.argv[1:]
manifest = json.load(open(path))
assert "key" not in manifest, "manifest still carries key"
assert manifest["version"] == version, manifest["version"]
EOF
test ! -e "$check/test"
for script in "$check"/*.js; do node --check "$script"; done
echo "$out: version $version, $(unzip -Z1 "$out" | wc -l) files"
