#!/bin/bash
# Builds 6axis.app into ./build.
#   scripts/build-app.sh debug     fast build for development (uses Homebrew's OpenCASCADE)
#   scripts/build-app.sh release   optimised, self-contained app (libraries embedded, see bundle-libs.sh)
# Version: $VERSION, else the latest git tag (v0.9.0 → 0.9.0); build number: $BUILD_NUMBER, else commit count.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/6axis.app"
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.9.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

cd "$ROOT"
swift build -c "$CONFIG" --product SixAxis
BIN="$(swift build -c "$CONFIG" --show-bin-path)/SixAxis"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SixAxis"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>6axis</string>
    <key>CFBundleDevelopmentRegion</key><string>de</string>
    <key>SixAxisUpdatePublicKey</key><string>$(tr -d '[:space:]' < "$ROOT/Resources/update-public-key.txt")</string>
    <key>CFBundleLocalizations</key><array><string>de</string><string>en</string></array>
    <key>CFBundleDisplayName</key><string>6axis</string>
    <key>CFBundleIdentifier</key><string>app.6axis</string>
    <key>CFBundleExecutable</key><string>SixAxis</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>6axis Design</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>CFBundleTypeIconFile</key><string>AppIcon</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>app.6axis.design</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>app.6axis.design</string>
            <key>UTTypeDescription</key><string>6axis Design</string>
            <key>UTTypeConformsTo</key><array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>6axis</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Translations: the string catalog compiles to de.lproj / en.lproj in the app bundle.
xcrun xcstringstool compile "$ROOT/Resources/Localizable.xcstrings" --output-directory "$APP/Contents/Resources" >/dev/null

mkdir -p "$APP/Contents/Resources/Licenses"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/Licenses/6axis-LICENSE.txt"

if [ "$CONFIG" = "release" ]; then
    "$ROOT/scripts/bundle-libs.sh" "$APP"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
