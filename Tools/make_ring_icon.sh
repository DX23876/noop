#!/usr/bin/env bash
# Regenerate StrandiOS's primary app icon from docs/assets/icon-source.svg.
#
# icon-source.svg is a full-bleed variant of docs/assets/logo.svg (the three-ring GitHub mark):
# no rounded corners, no border stroke, background filling the entire square edge to edge. iOS
# applies its own corner mask and shadow at render time, so icon source art should always be a
# plain full-bleed square — pre-rounding it (like logo.svg's rx=116 rect) leaves the four corners
# uncovered, and flattening tools then bake that as OPAQUE WHITE rather than transparent (verified
# by rasterizing logo.svg directly: its corner pixels come out 255,255,255,255). Filling the whole
# square here makes that failure mode structurally impossible instead of patching it after the fact.
#
# No ImageMagick/cairosvg/rsvg-convert dependency — just the macOS tools already on this machine:
# qlmanage (QuickLook) rasterizes the SVG, then a JPEG round-trip via sips strips the alpha channel
# entirely (App icons must be flat RGB, no alpha; JPEG has no alpha channel to preserve, so the
# round-trip forces one cleanly rather than requiring a raw pixel edit).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="docs/assets/icon-source.svg"
OUT="StrandiOS/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

qlmanage -t -s 1024 -o "$TMP" "$SRC" >/dev/null
sips -s format jpeg -s formatOptions 100 "$TMP/icon-source.svg.png" --out "$TMP/flat.jpg" >/dev/null
sips -s format png "$TMP/flat.jpg" --out "$OUT" >/dev/null

echo "Wrote $OUT"
file "$OUT"
