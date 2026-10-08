#!/bin/bash
# Regenerates the images of the product page from the app's demo runs:
# website/assets (German UI) and website/assets/en (English UI).
#   scripts/screenshots.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$ROOT/build/6axis.app" ] || "$ROOT/scripts/build-app.sh" debug
BIN="$ROOT/build/6axis.app/Contents/MacOS/SixAxis"

shoot() {
    local lang="$1" out="$2" tmp
    tmp="$(mktemp -d)"
    mkdir -p "$out"
    SIXAXIS_DEMO=1 SIXAXIS_SNAPSHOTS="$tmp/ui" "$BIN" -AppleLanguages "($lang)" >/dev/null 2>&1 || true
    SIXAXIS_DEMO=1 SIXAXIS_DRAWING_DEMO="$tmp/drawing" "$BIN" -AppleLanguages "($lang)" >/dev/null 2>&1 || true
    copy() { [ -f "$1" ] && sips -Z "$3" "$1" --out "$out/$2" >/dev/null && echo "  $out/$2"; }
    copy "$tmp/ui/09-final.png" model.png 1800
    copy "$tmp/ui/04-sketch.png" sketch.png 1800
    copy "$tmp/ui/11-marking.png" marking.png 1800
    copy "$tmp/drawing/sheet-1.png" drawing.png 1800
    copy "$tmp/drawing/sheet-2.png" parts.png 1800
    [ "$lang" = de ] && cp "$tmp/drawing/hero.svg" "$out/hero.svg" && echo "  $out/hero.svg"
    rm -rf "$tmp"
}
shoot de "$ROOT/website/assets"
shoot en "$ROOT/website/assets/en"
sips -Z 256 "$ROOT/Resources/Logo.png" --out "$ROOT/website/assets/logo.png" >/dev/null
