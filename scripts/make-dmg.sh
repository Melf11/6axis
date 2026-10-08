#!/bin/bash
# Packs build/6axis.app into a compressed disk image with an "Applications" shortcut and a short
# first-start guide, plus a ZIP and SHA-256 checksums.
#   scripts/make-dmg.sh            → build/6axis-<version>.dmg, build/6axis-<version>.zip
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/6axis.app"
[ -d "$APP" ] || { echo "Build the app first: scripts/build-app.sh release" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
NAME="6axis-$VERSION"
STAGE="$(mktemp -d)"

cp -R "$APP" "$STAGE/6axis.app"
ln -s /Applications "$STAGE/Programme"
cat > "$STAGE/Erster Start – bitte lesen.txt" <<'TXT'
6axis – erster Start
====================

1. Ziehe "6axis" auf "Programme".
2. Öffne 6axis aus dem Programme-Ordner.
   macOS meldet: "6axis" kann nicht geöffnet werden / kann nicht überprüft werden.
   → Klicke auf "Fertig" (nicht "In den Papierkorb legen").
3. Öffne Systemeinstellungen → Datenschutz & Sicherheit.
   Ganz unten steht: "6axis" wurde blockiert … → klicke "Dennoch öffnen" und bestätige.
4. Ab jetzt startet 6axis ganz normal.

Warum? 6axis ist kostenlose Open-Source-Software ohne kostenpflichtiges Apple-Entwicklerkonto
und deshalb nicht von Apple notarisiert. Der Quellcode ist öffentlich einsehbar.

Für Erfahrene (Terminal):  xattr -dr com.apple.quarantine /Applications/6axis.app

Voraussetzungen: Mac mit Apple Silicon (M1 oder neuer), macOS 15 Sequoia oder neuer.
Fehler gefunden? 6axis → Hilfe → "Fehler melden …"
TXT

rm -f "$ROOT/build/$NAME.dmg" "$ROOT/build/$NAME.zip"
hdiutil create -volname "6axis $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$ROOT/build/$NAME.dmg" >/dev/null
(cd "$ROOT/build" && ditto -c -k --sequesterRsrc --keepParent 6axis.app "$NAME.zip")
(cd "$ROOT/build" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > "$NAME.sha256")
rm -rf "$STAGE"
ls -lh "$ROOT/build/$NAME".* | awk '{print $5, $9}'
