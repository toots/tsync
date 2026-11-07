#!/usr/bin/env bash
# Regenerate windows/installer from assets/tsync-app.svg: setup's icon, and the
# wizard's side panel and corner logo at 100% and 200% scale. Run after changing
# the logo; the images are committed, so the Windows build needs no rasteriser.
set -euo pipefail

WINDOWS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$WINDOWS_DIR/../assets/tsync-app.svg"
OUT="$WINDOWS_DIR/installer"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
mkdir -p "$OUT"

log "rendering $SVG"
magick -background none -density 768 "$SVG" PNG32:"$WORK/app.png"

log "setup icon"
for size in 16 24 32 48 64 256; do
    magick "$WORK/app.png" -resize "${size}x${size}" PNG32:"$WORK/icon-$size.png"
done
magick "$WORK"/icon-{16,24,32,48,64,256}.png "$OUT/tsync.ico"

# Inno Setup's modern wizard: a 164x314 side panel and a 55x55 corner logo at
# 100%, picked by the display's scale from the sizes listed in tsync.iss.
for scale in 1 2; do
    w=$((164 * scale)) h=$((314 * scale)) mark=$((96 * scale))
    log "side panel ${w}x${h}"
    magick -size "${w}x${h}" xc:'#4263EB' \
        \( "$WORK/app.png" -resize "${mark}x${mark}" \) \
        -gravity north -geometry "+0+$((72 * scale))" -composite \
        -font 'Noto-Sans-Bold' -pointsize $((30 * scale)) -fill white \
        -annotate "+0+$((184 * scale))" 'tsync' \
        -alpha off BMP3:"$OUT/wizard-$scale.bmp"
    small=$((55 * scale))
    log "corner logo ${small}x${small}"
    magick "$WORK/app.png" -resize "${small}x${small}" -background white -flatten \
        -alpha off BMP3:"$OUT/wizard-small-$scale.bmp"
done
log "done: $(ls "$OUT" | tr '\n' ' ')"
