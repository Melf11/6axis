<p align="center"><img src="Resources/Logo.png" width="160" alt="6axis Logo"></p>

<h1 align="center">6axis</h1>

**Freies, natives Mac-CAD für Konstruktion und 3D-Druck – vollständig offline.**

6axis ist ein parametrisches 3D-CAD-Programm für macOS, das sich am bewährten Bedienkonzept von Fusion 360 orientiert: Skizze mit Abhängigkeiten → Extrusion/Drehung → Abrundung, Fase, Wandstärke – alles in einer Zeitleiste, die sich jederzeit nachträglich ändern lässt. Gebaut mit Swift, SwiftUI und Metal auf dem Open-Source-Geometriekernel OpenCASCADE.

*English:* 6axis is a free, open-source, fully offline parametric CAD app for macOS, inspired by Fusion 360's workflow and focused on mechanical design and 3D printing. The UI is currently German; contributions (including localization) are welcome.

## Funktionen (Stand 0.1)

- **Skizzen** auf Ursprungsebenen oder ebenen Körperflächen: Linie, Rechteck, Mittelpunkt-Rechteck, Kreis, 3-Punkt-Bogen
- **Abhängigkeiten**: horizontal, vertikal, deckungsgleich, tangential, gleich, parallel, senkrecht, konzentrisch, Mittelpunkt, kollinear, symmetrisch, fixieren – mit automatischer H/V-Erkennung beim Zeichnen
- **Bemaßungen** (Länge, Abstand horizontal/vertikal, Punkt–Linie, Radius, Durchmesser, Winkel) mit Ausdrücken und **Benutzerparametern** (`breite / 2 + wand`)
- Anzeige der **Freiheitsgrade**; vollständig bestimmte Geometrie wird schwarz dargestellt
- Automatische **Profilerkennung** inklusive Löchern und überlappender Kurven
- **Extrusion** (eine Seite, symmetrisch, zwei Seiten; verbinden, ausschneiden, schneiden, neuer Körper) mit ziehbarem Pfeil und Live-Vorschau; ebene Körperflächen lassen sich direkt extrudieren (Press-Pull)
- **Drehung** um Achsen, Skizzenlinien oder Kanten
- **Abrundung, Fase, Wandstärke**
- **Parametrische Zeitleiste**: bearbeiten, unterdrücken, löschen, zurückrollen; Referenzen überleben Änderungen
- **Export**: STL (3D-Druck), STEP; **Import**: STEP; **„Im Slicer öffnen“** (PrusaSlicer, Bambu Studio, OrcaSlicer, Cura …)
- Volumen und geschätztes PLA-Gewicht der Auswahl
- Fusion-artige Bedienung: Ribbon, Browser, ViewCube, Radialmenü per Rechtsklick, Befehlssuche mit **S**, Tastenkürzel (L, R, C, A, D, E, F, X …)
- Automatisches Sichern: Das letzte Design (auch ungesichert) und die Ansicht werden beim nächsten Start wiederhergestellt
- Unbegrenztes Rückgängig/Wiederholen, Dark Mode, Retina, 120 Hz

## Bedienung

| Aktion | Trackpad | Maus |
|---|---|---|
| Drehen (Orbit) | Zwei-Finger-Wischen (in Skizzen: ⇧) | Rechte Taste ziehen / ⇧ + Mitteltaste |
| Verschieben | ⇧ + Zwei-Finger-Wischen (in Skizzen: ohne ⇧) | Mitteltaste ziehen |
| Zoomen | Pinch | Mausrad (zum Cursor) |
| Überall drehen | ⌥ + Ziehen | ⌥ + Ziehen |

| Taste | Befehl | Taste | Befehl |
|---|---|---|---|
| S | Befehlssuche | E | Extrusion |
| L | Linie | F | Abrundung |
| R | Rechteck | X | Hilfslinie umschalten |
| C | Kreis | H / V | horizontal / vertikal |
| A | Bogen | T / P | tangential / senkrecht |
| D | Bemaßung | O | Ortho/Perspektive |
| Esc | Abbrechen | ⌘↩ | Skizze fertig |

## Bauen

Voraussetzungen: macOS 14+, Xcode 16+ (Swift 6), [Homebrew](https://brew.sh).

```bash
brew install opencascade
swift test                      # Kern-Tests (Solver, Kernel, Parametrik)
scripts/build-app.sh            # erzeugt build/6axis.app
open build/6axis.app
```

Logo und App-Icon werden aus `Resources/Logo.svg` erzeugt: `python3 scripts/make-logo.py && scripts/make-icon.sh`.

Zum Entwickeln einfach `Package.swift` in Xcode öffnen und das Schema **SixAxis** starten. OpenCASCADE an anderem Ort: `OCCT_PREFIX=/pfad/zu/occt swift build`.

Automatischer UI-Durchlauf mit Screenshots (praktisch für Tests und Pull Requests):

```bash
SIXAXIS_DEMO=1 SIXAXIS_SNAPSHOTS=/tmp/6axis-shots build/6axis.app/Contents/MacOS/SixAxis
```

## Architektur

```
Sources/
  OCCTBridge/   C-Schnittstelle über OpenCASCADE (C++). Swift sieht nie C++.
  SixAxisCore/     Modell ohne UI: Dokument, Features, Skizze, Constraint-Solver,
                Ausdrucks-Parser, parametrischer Neuaufbau mit Cache, Kernel-Wrapper.
  SixAxis/      macOS-App: Editor-Zustand, Metal-Viewport, SwiftUI-Oberfläche.
Tests/          Unit-Tests für SixAxisCore.
```

- Das **Dokument** (`CADDocument`) ist ein reiner Werttyp und wird als JSON (`.6axis`) gespeichert. Undo bedeutet einfach: alte Kopie zurückholen.
- Der **ModelBuilder** spielt die Zeitleiste ab und cacht jedes Präfix per Hash. Beim Bearbeiten des letzten Features wird nur dieses neu berechnet.
- **Topologische Referenzen** (Kanten, Flächen, Profile) speichern eine geometrische Signatur und werden beim Neuaufbau zum ähnlichsten Element aufgelöst.
- Der **Skizzen-Solver** ist ein gedämpftes Least-Squares-Verfahren (Levenberg) mit Rang-Analyse für Freiheitsgrade.
- Der **Viewport** rendert mit Metal (MSAA, dicke Bildschirmraum-Linien, ID-Buffer-Picking).

## Roadmap

- Skizze: Trimmen, Versatz, Spiegeln, Muster, Skizzen-Abrundung, Splines, Text, Projizieren von Kanten
- Konstruktionsebenen und -achsen, Bohrung, Gewinde, Muster (rechteckig/kreisförmig), Spiegeln, Verschieben/Kopieren
- 3MF-Export mit Einheiten, Messwerkzeug, Schnittansicht
- Mehrere Komponenten und Baugruppen mit Gelenken, technische Zeichnungen
- Englische Lokalisierung, signiertes Release mit gebündelten OCCT-Bibliotheken

## Mitmachen

Beiträge sind sehr willkommen – siehe [CONTRIBUTING.md](CONTRIBUTING.md).

## Lizenz

[MIT](LICENSE). 6axis nutzt OpenCASCADE Technology (LGPL 2.1 mit Ausnahme) als dynamisch gelinkte Bibliothek.
„Fusion 360“ ist eine Marke von Autodesk, Inc.; 6axis ist ein unabhängiges Projekt und steht in keiner Verbindung zu Autodesk.
