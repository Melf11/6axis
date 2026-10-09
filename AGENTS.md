# Hinweise für KI-Assistenten und Mitwirkende

Diese Datei lesen Codex, Copilot, Cursor, Claude Code und andere Assistenten automatisch. Sie gilt genauso für Menschen. Ausführlicher: [CONTRIBUTING.md](CONTRIBUTING.md), Planung: [docs/roadmap.md](docs/roadmap.md).

## Was 6axis ist

Ein **schlankes, natives** parametrisches CAD für macOS – für Konstruktion, Holz/Werkstatt und 3D-Druck. Offline, Open Source (MIT). Der Projektinhaber ist Tischler; die Oberfläche ist deutsch und englisch.

## Leitlinien (verbindlich)

1. **Nativ statt mitgeliefert.** Oberfläche (SwiftUI/AppKit), Grafik (Metal), PDF, Schriften usw. kommen von macOS. Mitgeliefert wird nur, was es auf dem Mac nicht gibt – heute ausschließlich OpenCASCADE. Neue Abhängigkeiten nur mit gutem Grund, mit MIT-verträglicher Lizenz (MIT/BSD/Boost/Apache, LGPL nur dynamisch gelinkt und austauschbar) und nach Rückfrage.
2. **Ein Arbeitsablauf statt vieler Werkbänke.** Jede Funktion folgt demselben Muster: auswählen → Befehl (Werkzeugleiste, Radialmenü, Befehlssuche „S“) → Dialog mit Live-Vorschau → Eintrag in der Zeitleiste, nachträglich änderbar. Keine eigenen Modi mit eigenen Menüs.
3. **Komplexität über Parameter und Bezüge, nicht über mehr Knöpfe.** Komplexe Bauteile entstehen aus vielen einfachen, sauber aufeinander aufbauenden Schritten. Werte sind Ausdrücke (`breite / 2`), Bezüge müssen Maßänderungen überstehen.
4. **Gute Voreinstellungen.** Ein Befehl soll mit einem Klick und einer Zahl funktionieren. Feinheiten sind erreichbar, stehen aber nicht im Weg.
5. **Jede neue Funktion muss sich fragen lassen: Macht sie die Oberfläche schwerer?** Wenn ja, anders lösen oder hinter eine sinnvolle Voreinstellung legen.
6. **Flüssig bleiben.** Nichts Teures auf dem Hauptthread oder pro Eingabe-Ereignis (Neuberechnung läuft im Hintergrund, Picking nicht pro Scroll-Ereignis).
7. **Offline und ohne Konto.** Keine Telemetrie, keine Netzwerkzugriffe außer auf ausdrücklichen Klick (z. B. „Fehler melden“).

## Technik in Kürze

- SwiftPM-Paket: `SixAxisCore` (Kern, ohne UI: Dokument, Skizzen-Löser, Modellaufbau, Zeichnung), `SixAxis` (App), `OCCTBridge` (C-Schnittstelle zu OpenCASCADE).
- Dokument = Werttyp `CADDocument` (JSON, `.6axis`). Formatänderungen: `CADDocument.currentFormatVersion` erhöhen, Migration in `CADDocument.migrations`, Testdatei in `Tests/SixAxisCoreTests/Fixtures`.
- Bezüge auf Geometrie: `ProfileRef` (mit `ProfileAnchor`), `FaceRef`/`EdgeRef` (mit Topologie-Zählern). Neue Referenzen so bauen, dass sie Parameteränderungen überstehen.

## Arbeiten im Repository

```bash
brew install opencascade
swift test                          # Kern-Tests
scripts/build-app.sh debug          # App bauen → build/6axis.app
scripts/build-app.sh release && scripts/ui-check.sh   # Oberflächenprüfung (echte Fenster, de + en)
scripts/update-strings.sh           # neue Texte in den String Catalog übernehmen
```

- **Texte:** auf Deutsch im Code (`Text("…")`, `String(localized: "…")`, `KernelError("…")`), englische Übersetzung in `scripts/translations_en.py`, dann `python3 scripts/apply-translations.py`. Das CI bricht bei fehlenden Übersetzungen ab.
- **Oberfläche prüfen:** Das Terminal hat keine Bildschirmaufnahme-Rechte – stattdessen die Demo-Läufe nutzen (`SIXAXIS_DEMO=1 SIXAXIS_SNAPSHOTS=dir`, `SIXAXIS_DRAWING_DEMO=dir`, `SIXAXIS_EXAMPLES_DEMO=dir`, `SIXAXIS_NAV_TEST=dir`). Automatische Läufe nutzen eigene Einstellungen und einen eigenen Autosave-Ordner und verändern nichts beim Nutzer.
- **Git:** Arbeit auf einem Branch (`feature/…`, `fix/…`, `docs/…`), committen, pushen; nach `main` mergen erst nach Absprache. Releases entstehen durch ein Tag `vX.Y.Z` (GitHub Actions baut DMG/ZIP, Oberflächenprüfung vorher).
- **Lizenzen:** eigener Code MIT; OpenCASCADE (LGPL 2.1) bleibt dynamisch gelinkt und austauschbar, Lizenztexte liegen in der App.
