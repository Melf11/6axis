#!/bin/bash
# Regenerates the images of the product page (website/assets) from the app's demo runs.
#   scripts/screenshots.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/website/assets"
TMP="$(mktemp -d)"
mkdir -p "$OUT"
[ -d "$ROOT/build/6axis.app" ] || "$ROOT/scripts/build-app.sh" debug
BIN="$ROOT/build/6axis.app/Contents/MacOS/SixAxis"

SIXAXIS_DEMO=1 SIXAXIS_SNAPSHOTS="$TMP/ui" "$BIN" >/dev/null 2>&1 || true
SIXAXIS_DEMO=1 SIXAXIS_DRAWING_DEMO="$TMP/drawing" "$BIN" >/dev/null 2>&1 || true

copy() { [ -f "$1" ] && sips -Z "$3" "$1" --out "$OUT/$2" >/dev/null && echo "  $2"; }
echo "website/assets:"
cp "$TMP/drawing/hero.svg" "$OUT/hero.svg" && echo "  hero.svg"
copy "$TMP/ui/09-final.png" model.png 1800
copy "$TMP/ui/04-sketch.png" sketch.png 1800
copy "$TMP/ui/11-marking.png" marking.png 1800
copy "$TMP/drawing/sheet-1.png" drawing.png 1800
copy "$TMP/drawing/sheet-2.png" parts.png 1800
copy "$ROOT/Resources/Logo.png" logo.png 256
rm -rf "$TMP"
