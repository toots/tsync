#!/usr/bin/env bash
# Regenerate TsyncApp/Assets.xcassets from assets/: the Dock icon out of
# tsync-app.svg, and the four menu bar images out of assets/tray. Run after
# changing a logo; the PNGs are committed, so nothing at build time needs a
# rasteriser.
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$MACOS_DIR/../assets"
CATALOG="$MACOS_DIR/TsyncApp/Assets.xcassets"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# qlmanage, not `magick file.svg`: ImageMagick's own SVG renderer draws the
# tail's arc as a run of straight segments, which is plain at 1024. qlmanage
# goes through CoreGraphics. It rasterises at the SVG's declared width, hence
# the substitutions below rather than a -s flag. Downscaling from one oversized
# render is what gives the small sizes their antialiasing.
render() { # svg width out
    qlmanage -t -s "$2" -o "$WORK" "$1" >/dev/null 2>&1
    mv "$WORK/$(basename "$1").png" "$3"
}

## Dock icon

sed 's/width="128" height="128"/width="1024" height="1024"/' \
    "$ASSETS/tsync-app.svg" >"$WORK/app.svg"
render "$WORK/app.svg" 1024 "$WORK/app.png"

# qlmanage renders a thumbnail onto white, so the artwork comes back as an
# opaque square: the rounded corners are filled in and no transparency is left.
# The alpha is redrawn from the shape the SVG already declares -- one rounded
# rect over the whole canvas, rx 28 of 128 -- drawn oversized and scaled down,
# since -draw's own antialiasing is not enough at a radius this large.
#
# Full bleed, no margin: macOS 26 draws every icon edge to edge, so the 824-of-
# 1024 grid the older Dock wanted now reads as an icon two sizes too small.
magick "$WORK/app.png" \
    \( -size 4096x4096 xc:black -fill white \
       -draw 'roundrectangle 0,0 4095,4095 896,896' \
       -alpha off -colorspace gray -resize 1024x1024 \) \
    -alpha off -compose copy_opacity -composite PNG32:"$WORK/app-master.png"

appicon="$CATALOG/AppIcon.appiconset"
mkdir -p "$appicon"
for size in 16 32 64 128 256 512 1024; do
    magick "$WORK/app-master.png" -resize "${size}x${size}" PNG32:"$appicon/icon_$size.png"
done

## Menu bar

# One window for all four states, not each glyph's own bounding box: a per-state
# crop would re-centre the letter every time the status changed, so the t would
# twitch in the menu bar while the mark to its right did the talking. 22 units
# of the 24 grid leaves the glyph at about 80% of the square, which is the
# proportion the SF Symbols beside it keep.
WINDOW='viewBox="2.5 1 22 22"'

for state in idle sync paused error; do
    name="tsync-$state-symbolic"
    out="$CATALOG/$name.imageset"
    mkdir -p "$out"

    sed -e "s/viewBox=\"0 0 24 24\"/$WINDOW/" \
        -e 's/width="24" height="24"/width="360" height="360"/' \
        "$ASSETS/tray/$name.svg" >"$WORK/$state.svg"
    render "$WORK/$state.svg" 360 "$WORK/$state.png"

    # qlmanage renders a thumbnail onto white, and a template image is read for
    # its alpha alone -- so taken as-is these are four opaque squares, which is
    # what the menu bar would draw. The artwork is black on white, so negated
    # luminance IS the alpha we want, antialiased edges included. Recolouring to
    # black afterwards keeps those edges from compositing grey.
    magick "$WORK/$state.png" -colorspace gray \
        \( +clone -negate \) -alpha off -compose copy_opacity -composite \
        -fill black -colorize 100 PNG32:"$WORK/$state-rgba.png"

    # 18pt is the size the system draws its own menu bar extras at.
    magick "$WORK/$state-rgba.png" -resize 18x18 PNG32:"$out/icon_18.png"
    magick "$WORK/$state-rgba.png" -resize 36x36 PNG32:"$out/icon_36.png"

    cat >"$out/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "filename" : "icon_18.png" },
    { "idiom" : "mac", "scale" : "2x", "filename" : "icon_36.png" }
  ],
  "info" : { "version" : 1, "author" : "xcode" },
  "properties" : { "template-rendering-intent" : "template" }
}
JSON
done

echo "==> wrote $CATALOG" >&2
