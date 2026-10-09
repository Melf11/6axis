#!/usr/bin/env python3
"""Merges scripts/translations_en.py into Resources/Localizable.xcstrings (adds bridge messages as manual keys)."""
import json, pathlib, sys
root = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / "scripts"))
from translations_en import EN, SAME
path = root / "Resources" / "Localizable.xcstrings"
cat = json.loads(path.read_text())
strings = cat["strings"]
for key, value in EN.items():
    entry = strings.setdefault(key, {"extractionState": "manual"})
    entry.setdefault("localizations", {})["en"] = {"stringUnit": {"state": "translated", "value": value}}
for key in SAME:
    if key in strings:
        strings[key]["shouldTranslate"] = False
missing = [k for k, v in strings.items() if "en" not in v.get("localizations", {}) and v.get("shouldTranslate", True)]
path.write_text(json.dumps(cat, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
print(f"{len(strings)} strings, {len(missing)} still untranslated")
for k in missing: print("  ", repr(k))
