# Fräsen (CAM) – Konzept

Stand: Oktober 2026 · Status: Planung

Ziel: Bauteile aus 6axis direkt auf der CNC-Fräse fertigen – zuerst für die **Holzwerkstatt** (Plattenfräse/Portalfräse, 2,5D), später auch 3D-Formen. Es gelten die [Leitlinien](../AGENTS.md): kein eigener „CAM-Arbeitsbereich“ mit eigener Welt, sondern derselbe Ablauf wie beim Konstruieren – Bearbeitung wählen, Dialog mit Vorschau, Eintrag in einer Liste, alles parametrisch.

## Was eine Fräs-Funktion braucht

Vom Bauteil zur fertigen Fräsdatei sind sechs Bausteine nötig:

| # | Baustein | Was er tut | Woher |
|---|---|---|---|
| 1 | **Einrichtung** | Rohteil (Plattengröße, Stärke), Nullpunkt (z. B. Plattenecke oben links, Oberseite), Spannung/Opferplatte, Sicherheitshöhe | eigene Daten im Dokument |
| 2 | **Werkzeugbibliothek** | Fräser mit Durchmesser, Schneidenlänge, Typ (Schaft-, Kugel-, V-, Bohrer), Drehzahl, Vorschub, Zustellung | eigene Daten, als JSON exportier-/teilbar |
| 3 | **Bearbeitungen** | Kontur außen/innen mit Haltestegen, Tasche, Bohren, Planen, Nut, Gravur; später adaptives Ausräumen und 3D-Schlichten | Algorithmen (siehe unten) |
| 4 | **Bahnberechnung** | Aus Geometrie + Werkzeug die Fräserbahnen: Versatz um den Fräserradius, Zustellungen in Z, Ein-/Ausfahren (Rampe, Helix), Haltestege | **Clipper2** für 2D-Versatz, OpenCASCADE für Geometrie, später **OpenCAMLib** für 3D |
| 5 | **Simulation** | Bahnen anzeigen, Materialabtrag als Höhenkarte, Kollisions- und Plausibilitätsprüfung (Fräser zu kurz, Werkzeug passt nicht in die Ecke, Fahrt durch Spannmittel) | eigene Umsetzung mit Metal |
| 6 | **Postprozessor** | Bahnen → G-Code für die konkrete Steuerung (Einheiten, Kopf/Fuß, Werkzeugwechsel, Kreisbögen G2/G3, Dialekt) | eigene, kleine Vorlagen je Steuerung |

## Bibliotheken

| Bibliothek | Wofür | Lizenz | Bewertung |
|---|---|---|---|
| **[Clipper2](https://github.com/AngusJohnson/Clipper2)** | Polygon-Versatz und -Boolesche Operationen in 2D – Kern jeder Kontur- und Taschenbahn | Boost 1.0 (frei, MIT-verträglich) | **erste Wahl** für 2,5D; C++, klein (wenige Dateien), schnell, robust |
| **OpenCASCADE** (schon drin) | Schnitte durch das Bauteil in Bearbeitungstiefen, Flächen/Kanten erkennen (Taschenboden, Bohrungen), Kreisbögen | LGPL 2.1 (dynamisch) | liefert die Konturen, die Clipper2 versetzt |
| **[OpenCAMLib](https://github.com/aewallin/opencamlib)** | 3D: „Drop-Cutter“ (Fräser fällt auf Dreiecksnetz), Wasserlinien – für Schruppen/Schlichten von Freiformen | LGPL 2.1 (seit 2018; dynamisch einbinden wie OCCT) | **später** für 3D; wird auch von FreeCAD genutzt |
| eigene Simulation | Höhenkarte des Rohteils auf der GPU, Fräser „stanzt“ Bahn ab | – | Metal ist schon da, wenige hundert Zeilen |

Bewusst **nicht**: ein komplettes externes CAM-System einbetten (z. B. FreeCADs Path/CAM-Arbeitsbereich mit Python) – widerspricht „schlank und nativ“.

## Ausgabe: G-Code und Steuerungen

Postprozessoren sind kleine Textvorlagen (Swift), je Steuerung eine. Für Holz-CNCs sind verbreitet:

- **GRBL / grblHAL** – sehr verbreitet bei Hobby- und kleineren Portalfräsen
- **LinuxCNC**
- **Mach3 / Mach4**, **UCCNC**
- **Estlcam** (eigene Steuerung, liest G-Code)
- **Industrie (Homag, Biesse, SCM)** – Plattenbearbeitungszentren nutzen eigene Formate (z. B. WoodWOP `.mpr`, Biesse `.bpp`) – das ist ein eigenes, späteres Thema

Jede Ausgabe beginnt mit einer Kommentar-Kopfzeile (Bauteil, Werkzeuge, Nullpunkt, Rohteil) und wird vor dem Speichern **simuliert und geprüft**.

## Vorschlag für die Umsetzung in Stufen

### Stufe 1 – 2,5D für Platten (Holzwerkstatt)
- Einrichtung: Rohteil aus dem Bauteil (Hüllquader + Aufmaß) oder Plattenmaß, Nullpunkt wählbar, Sicherheitshöhe
- Werkzeugbibliothek mit typischen Holzfräsern (Schaftfräser 3/6/8/12 mm, Bohrer 5/8/35 mm, V-Nut 90°) und Schnittwerten
- Bearbeitungen: **Kontur** (außen/innen/auf Linie, Haltestege, Zustellung in Schritten), **Tasche**, **Bohren** (erkennt Bohrungen aus dem Modell, z. B. System-32-Reihen und Dübellöcher), **Nut**
- Bahnen mit Clipper2, Rampeneintauchen, Fräsrichtung Gleich-/Gegenlauf
- Vorschau der Bahnen im 3D-Fenster, Laufzeit-Schätzung
- Postprozessoren: GRBL, LinuxCNC, Mach3
- Mehrere Teile eines Korpus auf einer Platte (verbindet sich mit dem **Plattenzuschnittplan** aus der Feature-Sammlung: Verschachtelung/Nesting)

### Stufe 2 – Komfort und Sicherheit
- Simulation des Materialabtrags (Höhenkarte), Warnungen (Restmaterial in Innenecken, Fräser zu kurz, Haltestege fehlen)
- Adaptives Ausräumen (gleichmäßige Fräserlast) für Aluminium und harte Hölzer
- Bearbeitung von beiden Seiten (Wenden), Bezugsbohrungen
- Weitere Postprozessoren nach Bedarf (UCCNC, Estlcam, grblHAL-Varianten)

### Stufe 3 – 3D
- Schruppen und Schlichten von Freiformen mit OpenCAMLib (Drop-Cutter, Wasserlinie, Kugelfräser)
- 3D-Simulation

## Offene Fragen an den Werkstatt-Alltag
- Welche Fräse und Steuerung wird genutzt (GRBL, Mach3, Estlcam, LinuxCNC, Industrie)? → bestimmt den ersten Postprozessor
- Typische Arbeiten: Plattenteile mit Bohrungen ausschneiden? Taschen/Nuten? Gravuren/Schilder? 3D-Reliefs?
- Arbeitsweise: ganze Platte verschachteln oder Einzelteile auf Rohlingen?

## Sicherheit
CAM erzeugt Maschinenbewegungen. Deshalb: keine Ausgabe ohne Simulation und Plausibilitätsprüfung, deutliche Hinweise auf Nullpunkt und Werkzeuge in der Datei, Probelauf „in der Luft“ empfehlen. Die Verantwortung für den Betrieb der Maschine bleibt beim Anwender – das steht auch im Ausgabedialog.
