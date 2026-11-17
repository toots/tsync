#!/usr/bin/env bash
# Renders App/Assets.xcassets' icon from assets/tsync-app.svg (ios-app.md §2).
# iOS wants one opaque square and rounds the corners itself, so the SVG's own
# rounding is dropped. qlmanage draws through CoreGraphics, at the SVG's width.
set -euo pipefail
APP="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sed -e 's/width="128" height="128"/width="1024" height="1024"/' -e 's/ rx="28"//' \
    "$APP/../../assets/tsync-app.svg" >"$WORK/icon.svg"
qlmanage -t -s 1024 -o "$WORK" "$WORK/icon.svg" >/dev/null 2>&1
magick "$WORK/icon.svg.png" -alpha off -resize 1024x1024 PNG24:"$APP/App/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
