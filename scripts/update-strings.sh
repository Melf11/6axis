#!/bin/bash
# Extracts every localizable string from the sources (Text("…"), String(localized:), KernelError("…") …)
# via the Swift compiler and merges them into Resources/Localizable.xcstrings (source language German).
# New strings appear without English translation; translate them in Xcode or in the JSON.
#   scripts/update-strings.sh           update the catalog
#   scripts/update-strings.sh --check   CI: fail if a string has no English translation
set -euo pipefail
CHECK="${1:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
CATALOG="$ROOT/Resources/Localizable.xcstrings"
[ -f "$CATALOG" ] || echo '{"sourceLanguage":"de","strings":{},"version":"1.0"}' > "$CATALOG"

# Force a full recompile of both modules so every file emits its strings.
rm -rf "$ROOT/.build/strings"
swift build --package-path "$ROOT" --scratch-path "$ROOT/.build/strings" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$TMP" >/dev/null

# Debug-only sources (demo scripts) are not shown to users.
rm -f "$TMP"/DemoScript.stringsdata
xcrun xcstringstool sync "$CATALOG" --stringsdata "$TMP"/*.stringsdata
rm -rf "$TMP"
python3 - "$CATALOG" "$CHECK" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
s = d["strings"]
missing = [k for k, v in s.items() if k.strip() and "en" not in v.get("localizations", {}) and v.get("shouldTranslate", True)]
print(f"{len(s)} strings, {len(missing)} without English translation")
for k in missing[:40]: print("  ", k)
if sys.argv[2] == "--check" and missing:
    print("::error::Untranslated strings – add them to scripts/translations_en.py and run scripts/apply-translations.py")
    sys.exit(1)
PY
