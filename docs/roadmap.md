# Roadmap

Stand: Oktober 2026 · Aktuelles Release: [1.0.0](https://github.com/Melf11/6axis/releases/tag/v1.0.0) · als Nächstes: 1.1

**Leitlinien** (verbindlich, auch für KI-Assistenten): siehe [AGENTS.md](../AGENTS.md#leitlinien-verbindlich) – schlank und nativ, Bedienbarkeit und Einfachheit zuerst, ein Arbeitsablauf statt vieler Werkbänke, Komplexität über Parameter und Bezüge statt über mehr Oberfläche.

Reihenfolge nach Absprache: **zuerst ein weitergebbares Release**, damit Freunde 6axis testen können – danach die Funktionen. Holz-Werkzeuge und Plattenzuschnitt werden in der [Feature-Sammlung](#feature-sammlung) gesammelt und kommen am Ende.

| Version | Ziel | Kern |
|---|---|---|
| **0.9** | Test-Release für Freunde | App läuft ohne Homebrew, GitHub Actions baut Releases, Produktseite |
| **1.0** | Stabil für Alltagsnutzung | Neuberechnung im Hintergrund, Englisch, Dateiformat-Versionierung, Feedback der Tester |
| 1.1 | Skizze vervollständigen | Trimmen, Versatz, Spiegeln, Muster, Projizieren, Text, Splines |
| 1.2 | Modellieren | Konstruktionsebenen, Bohrung, Muster/Spiegeln, Körper verschieben/kombinieren |
| 1.3 | Prüfen & Ausgabe | Messen, Schnittansicht im 3D-Fenster, 3MF |
| 1.4 | Baugruppen | Komponenten, Gelenke, Explosionsansicht |
| 2.0 | Fräsen (CAM) | 2,5D für Platten: Kontur, Tasche, Bohren, Nut, G-Code (GRBL, LinuxCNC, Mach3) – [Konzept](cam.md) |
| später | Feature-Sammlung | Holz-Werkzeuge, Plattenzuschnittplan, … |

---

## 0.9 – Test-Release

Ziel: Ein Freund lädt eine Datei von GitHub, öffnet sie und kann konstruieren – ohne Homebrew, ohne Xcode, ohne Apple-Entwicklerkonto.

### 1. App eigenständig machen
- [x] Alle benötigten Bibliotheken in `6axis.app/Contents/Frameworks` kopieren: OpenCASCADE (~30 `libTK*`), TBB und deren Abhängigkeiten (z. B. FreeType) – rekursiv ermittelt mit `otool -L`
- [x] Verweise mit `install_name_tool` auf `@rpath` umstellen, `@executable_path/../Frameworks` als rpath setzen; keine Pfade nach `/opt/homebrew` mehr (`otool` prüft das im Build und bricht sonst ab)
- [x] Ad-hoc signieren (`codesign --sign -`, Bibliotheken einzeln, dann die App) – auf Apple Silicon Pflicht, damit die App überhaupt startet
- [x] Release-Build (`-c release`), Version und Build-Nummer aus dem Git-Tag ins `Info.plist`
- [x] Lizenzen beilegen: MIT für 6axis, LGPL-2.1-Text und Quellverweis für OpenCASCADE (Bibliotheken bleiben austauschbare dylibs → LGPL-konform)
- [ ] Prüfung auf einem sauberen Mac bzw. in einem Benutzerkonto ohne Homebrew

**Einschränkung 0.9:** nur **Apple Silicon** (M1 und neuer), macOS 15+. Intel-Macs bräuchten OpenCASCADE als x86_64- bzw. Universal-Build aus dem Quellcode (siehe Offene Punkte).

### 2. GitHub Actions
- [x] **CI** (`.github/workflows/ci.yml`) bei jedem Push und Pull Request: macOS-Runner (Apple Silicon), `brew install opencascade`, `swift build`, `swift test`, App bauen
- [x] Optional im CI: UI-Demo-Lauf (`SIXAXIS_DEMO=1`) und Zeichnungs-Demo, Screenshots als Artefakt – hilfreich bei Pull Requests
- [x] **Release** (`.github/workflows/release.yml`) beim Push eines Tags `v*` (z. B. `v0.9.0`):
  - App bauen und Bibliotheken einbetten (Schritt 1)
  - **DMG** mit Anleitung „Erster Start“ und Verknüpfung zu „Programme“ (`hdiutil`), zusätzlich ZIP
  - SHA-256-Prüfsummen
  - GitHub Release mit Versionshinweisen (aus den Commits seit dem letzten Tag) und Installationsanleitung
- [x] ~~Homebrew-Cache~~ nicht nötig: OpenCASCADE installiert sich im Workflow in 12 s
- [x] Ablauf zum Veröffentlichen in `CONTRIBUTING.md`: `git tag v0.9.0 && git push --tags`

### 3. Installation ohne Apple-Entwicklerkonto
Ohne Notarisierung zeigt macOS beim ersten Start eine Warnung. Die Anleitung (Release-Text, Produktseite, README) erklärt die Schritte für macOS 15:
1. DMG öffnen, 6axis in „Programme“ ziehen
2. 6axis öffnen → Hinweis „kann nicht überprüft werden“ → **Fertig**
3. **Systemeinstellungen → Datenschutz & Sicherheit → „Dennoch öffnen“**, bestätigen
4. Alternative für Erfahrene: `xattr -dr com.apple.quarantine /Applications/6axis.app`

### 4. Für Tester
- [x] Menü **Hilfe → „Fehler melden …“ / „Idee vorschlagen …“**: öffnet ein vorausgefülltes GitHub-Issue (Version, macOS-Version) im Browser – nur auf Klick, keine Telemetrie
- [x] Issue-Vorlagen „Fehler melden“ und „Idee“ im Repository
- [x] Version in „Über 6axis“
- [ ] Version im Fenstertitel der Zeichnung

### 5. Produktseite (GitHub Pages)
Einfache, schnelle Seite unter `https://melf11.github.io/6axis/`, eigener Ordner `website/`, veröffentlicht per GitHub Actions (`actions/deploy-pages`), nur HTML/CSS, keine Tracker, keine externen Schriften.

Inhalt:
- **Kopf:** Logo, „6axis – freies CAD für den Mac. Für Konstruktion, 3D-Druck und Holz.“, großer Knopf **Herunterladen** (→ `releases/latest`), Hinweis „macOS 15+, Apple Silicon, kostenlos & Open Source“
- **Screenshots:** Modell, Skizze mit Bemaßung, technische Zeichnung (Korpus mit Stückliste) – erzeugt mit den Demo-Läufen (`scripts/screenshots.sh`)
- **Drei Säulen:** *Konstruieren* (Skizze, Parameter, Zeitleiste), *3D-Druck* (STL, Slicer, Gewicht), *Werkstatt* (Zeichnung, Zuschnittliste, DXF 1:1)
- **Installation** in drei Schritten (siehe oben) mit Bildern
- **Open Source:** MIT, GitHub-Link, Mitmachen
- Hell/Dunkel automatisch, mobilfreundlich; Sprache Deutsch (Englisch mit 1.0)

### Zusätzlich umgesetzt
- [x] Beispiele (Korpus, Schneidebrett, Aufbewahrungsbox) in `Examples/` und unter **Ablage → Beispiele**
- [x] Gewicht in der Statusleiste nach Körpermaterial (Holz, Kunststoffe, Metalle)
- [x] Produktseite online: https://melf11.github.io/6axis/

### Fertig, wenn
- Ein Tag `v0.9.0` erzeugt automatisch ein GitHub Release mit DMG
- Das DMG startet auf einem Mac ohne Homebrew
- Die Produktseite ist online und verlinkt das neueste Release

---

## 1.0 – Stabil ✅ (Release 1.0.0)

- [x] **Parameter verschieben Geometrie zuverlässig:** Profile merken sich ihre Lage relativ zu den Skizzenpunkten, Kanten und Flächen von Abrundung/Fase/Wandstärke bleiben bei gleicher Topologie über ihren Index erhalten. Ändern von z. B. Korpusbreite oder -höhe baut fehlerfrei neu auf; ältere Dateien funktionieren weiter. Alle Beispiele sind vollständig parametrisch.
- [x] **Neuberechnung im Hintergrund:** Neuaufbau auf einer eigenen Queue; ist er nach 80 ms fertig, wird er sofort übernommen (Vorschau beim Ziehen bleibt direkt), sonst bleibt die Oberfläche bedienbar und zeigt „Berechne Modell …“; veraltete Berechnungen werden übersprungen. Viele Werkzeugkörper (z. B. 400 Bohrungen) werden in einer Operation vereinigt statt nacheinander (13 s → 6 s im Debug-Build, ~2 s im Release-Build)
- [x] **Englisch:** alle ~530 Texte (Oberfläche, Meldungen, Fehlermeldungen aus Kern und OpenCASCADE-Brücke, technische Zeichnung, Beispiele) im String Catalog `Resources/Localizable.xcstrings`; die Sprache folgt dem System (pro App einstellbar unter Systemeinstellungen → Allgemein → Sprache & Region). `scripts/update-strings.sh` sammelt neue Texte über den Swift-Compiler, das CI bricht bei fehlenden Übersetzungen ab
- [x] Produktseite zweisprachig (`website/en/`, Screenshots mit englischer Oberfläche über `scripts/screenshots.sh`)
- [x] **Dateiformat-Versionierung:** Format 2 (1.0); ältere Dateien werden schrittweise migriert, Dateien aus neueren Versionen mit klarer Meldung abgelehnt, fehlende Felder sind erlaubt, verständliche Fehlermeldungen bei beschädigten Dateien. Test-Sammlung `Tests/SixAxisCoreTests/Fixtures` mit den Beispielen aus 0.9.0 – bei jedem Release kommen die Beispiele dazu
- [x] **README** aktualisiert (Funktionsliste, Screenshots, Installation, Beispiele, Englisch)
- [x] Mehr Tests: `scripts/ui-check.sh` prüft im CI und vor jedem Release die Oberfläche über die Demo-Läufe (Deutsch und Englisch, Zeichnung, Beispiele, Neuberechnung im Hintergrund) – Screenshots als Download; Beispielmodelle, Parameteränderungen und Dateien aus 0.9.0 als Regressionstests

---

## 1.0.x – Pflege
- [x] Flüssiges Verschieben (3D und Zeichnung), Zoomen mit ⌘ + Scrollen in der Zeichnung (1.0.1)
- [x] **Updates in der App** (1.0.2): tägliche Suche (abschaltbar), Hinweis in der Kopfleiste, Versionshinweise, Installation mit einem Klick und Neustart; nur mit gültiger Ed25519-Signatur, sonst Verweis auf die Release-Seite

## Fehlerberichte & automatische Fehlerbehebung
Plan: [docs/bug-pipeline.md](bug-pipeline.md) – Fehler-Chat in der App (GitHub-Anmeldung), Sichtung und nächtliche Behebung in GitHub Actions mit Claude, ein Pull Request pro Fehler, Freigabeliste im Repository.

## 1.1 – Skizze vervollständigen
- **Rückmeldungen der Tester** einarbeiten (Bedienung von Zeichnungsfenster, Radialmenü, Navigation, DXF in CAM-/Lasersoftware)
- Trimmen und Verlängern
- Versatz (z. B. Wandstärke als Kontur)
- Spiegeln an einer Linie
- Rechteck- und Kreismuster in der Skizze
- Skizzen-Abrundung und -Fase
- Kanten und Flächen von Körpern in die Skizze projizieren
- Maßeingabe auch für Bögen
- Text (zum Gravieren bzw. für den 3D-Druck)
- Splines

## 1.2 – Modellieren
- Konstruktionsebenen (versetzt, unter Winkel, mittig zwischen zwei Flächen) und -achsen
- Bohrung (Durchgang, Sackloch, Senkung, Gewinde-Kernloch)
- Gewinde (kosmetisch und modelliert)
- Muster rechteckig/kreisförmig, Spiegeln – für Features und Körper
- Körper verschieben, kopieren, drehen; Körper kombinieren (verbinden, abziehen, schneiden)

## 1.3 – Prüfen & Ausgabe
- Messwerkzeug (Abstand, Winkel, Fläche, Volumen)
- Schnittansicht im 3D-Fenster
- 3MF-Export mit Einheiten (für den 3D-Druck besser als STL)
- Zuschnittmaße auch für schräg liegende Teile (minimales Hüllquader statt achsparallel)
- Bemaßung verdeckter Merkmale in der Zeichnung

## 1.4 – Baugruppen
- Komponenten (wiederverwendbare Teile, mehrfach eingebaut)
- Gelenke: starr, Drehung, Schieben
- Explosionsansicht, auch in der technischen Zeichnung
- Stückliste aus Komponenten

## 2.0 – Fräsen (CAM)
Ausführlich: [docs/cam.md](cam.md). Zuerst die Fragen dort klären (Fräse/Steuerung, typische Arbeiten).
- Stufe 1 – 2,5D für Platten: Einrichtung (Rohteil, Nullpunkt), Werkzeugbibliothek, Kontur mit Haltestegen, Tasche, Bohren (auch aus System-32-Reihen), Nut; Bahnen mit Clipper2; Vorschau und Laufzeit; Postprozessoren GRBL, LinuxCNC, Mach3; Verschachtelung mehrerer Teile (mit dem Plattenzuschnittplan)
- Stufe 2 – Simulation des Materialabtrags, Warnungen, adaptives Ausräumen, Wendebearbeitung, weitere Steuerungen
- Stufe 3 – 3D-Schruppen/-Schlichten mit OpenCAMLib

---

## Feature-Sammlung

Ideen ohne feste Version; Reihenfolge nach Bedarf.

### Holz-Werkzeuge
- **Lochreihe System 32** – Ø5-Bohrungen im 32-mm-Raster, Abstand zur Vorderkante wählbar (Standard 37 mm)
- **Nut und Falz** – entlang einer Kante, Breite/Tiefe als Parameter (z. B. für Rückwände)
- **Dübelverbindung** zwischen zwei Platten – Bohrungen in beiden Teilen automatisch passend
- **Fingerzinken / Schwalbenschwanz** zwischen zwei Platten
- **Topfbänder** (Ø35-Bohrung mit Befestigungslöchern)
- **Plattenkörper** – Brett mit Länge/Breite/Dicke und Material direkt anlegen
- **Kantenumleimer** – in Stückliste und Zuschnitt berücksichtigen (Zuschnitt = Fertigmaß − Kante)

### Plattenzuschnitt
- **Zuschnittplan** – Teile aus der Stückliste auf Rohplatten (z. B. 2800 × 2070) verteilen, Sägeschnitt-Breite, Faserrichtung beachten, Verschnitt in Prozent, als PDF/Zeichnungsblatt

### Weitere Ideen
- Radialmenü per Rechtsklick-Ziehen (Gesten), als Option
- Rendering-Ansicht mit Materialien (Holzmaserung)
- Intel-Unterstützung (Universal-Build)
- Notarisierte App, sobald ein Apple-Entwicklerkonto vorhanden ist

---

## Offene Punkte / Risiken
- **Intel-Macs:** brauchen einen eigenen OpenCASCADE-Build (x86_64 oder Universal) – im CI aus dem Quellcode möglich, kostet aber Build-Zeit (Cache nötig)
- **Größe:** OpenCASCADE-Bibliotheken ~50 MB; DMG voraussichtlich 25–35 MB
- **Gatekeeper:** ohne Notarisierung bleibt der Zusatzschritt beim ersten Start; Apple kann diesen Weg in künftigen macOS-Versionen weiter erschweren
- **macOS-Runner** von GitHub Actions sind für öffentliche Repositories kostenlos, für private zählen sie mit erhöhtem Faktor gegen das Kontingent
