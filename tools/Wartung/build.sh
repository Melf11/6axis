#!/bin/bash
# Builds "6axis Wartung" (menu bar app for the owner) and installs it to ~/Applications.
#   tools/Wartung/build.sh          → build, install, start
#   tools/Wartung/build.sh --no-open
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APP="$HERE/build/6axis Wartung.app"

swift build -c release --package-path "$HERE" 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | grep -v "^\[" || true
BIN="$(swift build -c release --package-path "$HERE" --show-bin-path)/Wartung"
[ -x "$BIN" ] || { echo "✗ build failed" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Wartung"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>6axis Wartung</string>
    <key>CFBundleDisplayName</key><string>6axis Wartung</string>
    <key>CFBundleIdentifier</key><string>app.6axis.wartung</string>
    <key>CFBundleExecutable</key><string>Wartung</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>WartungRepo</key><string>$REPO</string>
</dict></plist>
PLIST
codesign --force -s - "$APP" >/dev/null

DEST="$HOME/Applications/6axis Wartung.app"
mkdir -p "$HOME/Applications"
pkill -x Wartung 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "✓ installiert: $DEST"
[ "${1:-}" = "--no-open" ] || open "$DEST"
