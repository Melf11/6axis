#!/bin/bash
# Builds Resources/AppIcon.icns and Resources/Logo.png from Resources/Logo.svg.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
swiftc -O "$ROOT/scripts/render-svg.swift" -o "$TMP/render-svg" 2>/dev/null
for s in 16 32 128 256 512; do
    "$TMP/render-svg" "$ROOT/Resources/Logo.svg" "$ICONSET/icon_${s}x${s}.png" "$s"
    "$TMP/render-svg" "$ROOT/Resources/Logo.svg" "$ICONSET/icon_${s}x${s}@2x.png" "$((s * 2))"
done
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
"$TMP/render-svg" "$ROOT/Resources/Logo.svg" "$ROOT/Resources/Logo.png" 512
rm -rf "$TMP"
echo "Built Resources/AppIcon.icns and Resources/Logo.png"
