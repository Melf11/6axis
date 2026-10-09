# Mitmachen bei 6axis

Danke, dass du helfen willst! Issues und Pull Requests auf Deutsch oder Englisch sind willkommen.

## Leitlinien

6axis soll **schlank, nativ und einfach zu bedienen** bleiben – und trotzdem komplexe Bauteile ermöglichen. Die verbindlichen Leitlinien (nativ statt mitgeliefert, ein Arbeitsablauf statt vieler Werkbänke, Komplexität über Parameter statt Oberfläche, gute Voreinstellungen, flüssig bleiben, offline) stehen in [AGENTS.md](AGENTS.md). Bitte prüfe jede Änderung dagegen – KI-Assistenten lesen diese Datei automatisch.

## Grundsätze

1. **Offline zuerst.** Keine Netzwerkzugriffe, keine Telemetrie, keine Konten.
2. **Einfach verständlich.** Jede neue Funktion braucht einen klaren Hinweistext in der Statuszeile und, wo sinnvoll, ein Tastenkürzel.
3. **Der Kern bleibt UI-frei.** Geometrie, Solver und Dokumentmodell gehören nach `SixAxisCore` und bekommen Tests.
4. **Dateiformat ist Vertrag.** Änderungen an `CADDocument` müssen alte `.6axis`-Dateien weiterhin öffnen können (neue Felder optional/mit Standardwert).

## Ablauf

```bash
brew install opencascade
swift test
scripts/build-app.sh debug && open build/6axis.app
```

- Für UI-Änderungen: Screenshots aus dem Demo-Lauf beilegen (`SIXAXIS_DEMO=1 SIXAXIS_SNAPSHOTS=…`).
- Ein neues Feature im Modell besteht aus: Datentyp in `Document.swift`, Anwendung in `Builder.swift`, Test in `Tests/`, Befehl in `Editor+Commands.swift`, Dialog in `CommandPanel.swift`.
- Neue OpenCASCADE-Funktionen werden in `OCCTBridge` als schmale C-Funktion ergänzt und in `Kernel.swift` gekapselt.

## Code-Stil

Swift-Standardstil, 4 Leerzeichen, kurze Kommentare, die das *Warum* erklären. Keine neuen Abhängigkeiten ohne Diskussion im Issue.

## Lizenz

Mit deinem Beitrag stimmst du zu, dass er unter der MIT-Lizenz veröffentlicht wird.

## Release veröffentlichen

1. `main` ist grün (CI) und `docs/roadmap.md` ist aktuell.
2. Lokal testen: `scripts/build-app.sh release && scripts/make-dmg.sh` – die App in `build/` muss ohne Homebrew-Pfade starten (das Skript prüft das).
3. Tag setzen und pushen:
   ```bash
   git tag v0.9.0
   git push origin v0.9.0
   ```
   Der Workflow **Release** baut die App, packt DMG/ZIP mit Prüfsummen und veröffentlicht das GitHub Release. Tags mit Bindestrich (`v0.9.1-beta.1`) werden als Vorabversion markiert.

Die Produktseite (`website/`) wird bei jeder Änderung auf `main` automatisch über GitHub Pages veröffentlicht. Bilder neu erzeugen: `scripts/screenshots.sh`.

## Texte und Übersetzungen

Sichtbare Texte schreibst du auf Deutsch direkt in den Code – SwiftUI-Literale (`Text("Skizze")`) werden automatisch übersetzt, alle anderen als `String(localized: "…")`, Fehlermeldungen als `KernelError("…")`. Danach:

```bash
scripts/update-strings.sh          # neue Texte in Resources/Localizable.xcstrings übernehmen
# Übersetzung in scripts/translations_en.py ergänzen (oder den Katalog in Xcode bearbeiten)
python3 scripts/apply-translations.py
```

Das CI prüft mit `scripts/update-strings.sh --check`, dass jeder Text eine englische Übersetzung hat. Weitere Sprachen sind willkommen.
