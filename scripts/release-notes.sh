#!/bin/bash
# Release notes for a tag: changes since the previous tag plus the first-start guide.
#   scripts/release-notes.sh v0.9.0
set -euo pipefail
TAG="${1:?usage: release-notes.sh <tag>}"
PREV="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
RANGE="${PREV:+$PREV..}$TAG"

echo "## Download"
echo
echo "**6axis-${TAG#v}.dmg** öffnen und 6axis auf „Programme“ ziehen."
echo
echo "Voraussetzungen: Mac mit **Apple Silicon** (M1 oder neuer), **macOS 15 Sequoia** oder neuer."
echo
echo "## Erster Start"
echo
echo "6axis ist kostenlose Open-Source-Software ohne kostenpflichtiges Apple-Entwicklerkonto und deshalb nicht von Apple notarisiert. Beim ersten Start einmalig:"
echo
echo "1. 6axis öffnen → Meldung „kann nicht überprüft werden“ → **Fertig**"
echo "2. **Systemeinstellungen → Datenschutz & Sicherheit** → ganz unten **„Dennoch öffnen“** → bestätigen"
echo
echo "Im Terminal geht es auch: \`xattr -dr com.apple.quarantine /Applications/6axis.app\`"
echo
echo "## Änderungen${PREV:+ seit $PREV}"
echo
git log --no-merges --pretty='- %s' "$RANGE" | grep -v '^- WIP' || echo "- Erstes Release"
echo
echo "## Feedback"
echo
echo "In 6axis: **Hilfe → Fehler melden …** oder **Idee vorschlagen …** – oder direkt hier unter *Issues*."
