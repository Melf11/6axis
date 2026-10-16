# Fräsen (CAM) und Maschinensteuerung – Konzept

Stand: Oktober 2026 · Status: Stufen 1 und 2 umgesetzt (Branch feature/2.0-cam)

Ziel: Bauteile aus 6axis direkt auf der CNC-Fräse fertigen – **vom Modell bis zum Fräsen in einem Mac-Programm**, so wie Estlcam CAM und Maschinensteuerung verbindet. 6axis soll also nicht nur G-Code erzeugen, sondern die Fräse auch selbst steuern: verfahren, Nullpunkt setzen, Programm abfahren – zuerst für die **Holzwerkstatt** (Plattenfräse/Portalfräse, 2,5D), später auch 3D-Formen. Es gelten die [Leitlinien](../AGENTS.md): keine eigene Welt, sondern derselbe Ablauf wie beim Konstruieren – Bearbeitung wählen, Dialog mit Vorschau, Eintrag in einer Liste, alles parametrisch. Umgesetzt als eigene **Werkzeugleiste „Fräsen“** (Umschalter am Arbeitsbereich-Symbol, wie die Skizze ihre eigene Leiste hat): gleiches Modell, gleiches 3D-Fenster, die Bearbeitungen im Browser unter „Fräsen“ – wer nicht fräst, sieht davon nichts.

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

**Umgesetzt (Stufe 1):** Für 2,5D reicht OpenCASCADE: `BRepOffsetAPI_MakeOffset` versetzt ebene Flächen exakt (mit Inseln), daher wurde **keine neue Bibliothek** (Clipper2) nötig. Clipper2 bleibt Option, falls Verschachtelung oder adaptives Ausräumen es verlangen – dann mit Rückfrage (Leitlinie 1).

Bewusst **nicht**: ein komplettes externes CAM-System einbetten (z. B. FreeCADs Path/CAM-Arbeitsbereich mit Python) – widerspricht „schlank und nativ“.

## Ausgabe: G-Code und Steuerungen

Postprozessoren sind kleine Textvorlagen (Swift), je Steuerung eine. Für Holz-CNCs sind verbreitet:

- **GRBL / grblHAL** – sehr verbreitet bei Hobby- und kleineren Portalfräsen
- **LinuxCNC**
- **Mach3 / Mach4**, **UCCNC**
- **Estlcam** (eigene Steuerung, liest G-Code)
- **Industrie (Homag, Biesse, SCM)** – Plattenbearbeitungszentren nutzen eigene Formate (z. B. WoodWOP `.mpr`, Biesse `.bpp`) – das ist ein eigenes, späteres Thema

Jede Ausgabe beginnt mit einer Kommentar-Kopfzeile (Bauteil, Werkzeuge, Nullpunkt, Rohteil) und wird vor dem Speichern **simuliert und geprüft**.

## Maschinensteuerung (wie das Estlcam-CNC-Programm)

Wunsch aus dem Testerkreis: *„Es gibt von Estlcam das CNC-Programm. Das steuert dann wirklich die CNC und fährt den G-Code. Außerdem kann man da den Nullpunkt finden, Achsen nullen, parken. Alles, was die Motoren steuert.“*

### Welche Steuerung? (wichtig)
- Estlcam schreibt auf den Arduino (Uno, Nano, Mega) eine **eigene Firmware** mit eigenem Protokoll. Diese Firmware ist nicht GRBL-kompatibel und nicht offen dokumentiert – **6axis kann eine Estlcam-Firmware nicht direkt ansteuern** ([Openbuilds, Entwickler-Beitrag](https://openbuilds.com/goto/post?id=60141), [V1 Engineering Forum](https://forum.v1engineering.com/t/estlcam-firmware-arduino-uno-protoneer-cnc-shield/3854)).
- Die gute Nachricht: Auf **dieselbe Hardware** (Arduino + CNC-Shield) lässt sich jederzeit **GRBL** schreiben; Estlcam bietet sogar GRBL-kompatible Pinbelegungen an. GRBL und grblHAL haben ein **offenes, gut dokumentiertes Protokoll** über USB ([Grbl v1.1 Interface](https://github-wiki-see.page/m/gnea/grbl/wiki/Grbl-v1.1-Interface)).
- 6axis steuert deshalb **GRBL 1.1, grblHAL und GRBL-kompatible Steuerungen** wie FluidNC (ESP32). Für Fräsen mit Estlcam-Firmware heißt das: einmal GRBL aufspielen und die Achsen-Einstellungen (Schritte/mm, Richtung, Endschalter) übernehmen – dafür bekommt 6axis einen geführten Einrichtungs-Assistenten.

### Funktionen
| Bereich | Was 6axis kann |
|---|---|
| Verbinden | USB-Steuerung auswählen (wird automatisch gefunden), Verbindung und Firmware anzeigen, Einstellungen der Steuerung lesen und – mit Rückfrage – schreiben |
| Positionsanzeige | Maschinen- und Werkstückkoordinaten live (DRO), Status (bereit, läuft, Halt, Alarm), Fräserposition im 3D-Fenster über dem Bauteil |
| Verfahren (Joggen) | Pfeiltasten/Bild-auf/-ab, Schaltflächen, wählbare Schrittweite (0,01 / 0,1 / 1 / 10 mm) oder Dauerfahrt; **Gamepad/Controller** über Apples GameController-Framework (nativ) |
| Referenzfahrt | Referenzieren auf die Endschalter (Homing), danach sind Maschinenkoordinaten verlässlich |
| Nullpunkt | X/Y/Z einzeln oder alle nullen; Nullpunkt aus der Einrichtung in 6axis übernehmen (z. B. Plattenecke) |
| Nullpunkt finden | **Z mit Tastplatte / Längensensor** (Antastzyklus, Plattenstärke einstellbar); Kanten- und Eckenantasten für X/Y |
| Parken | Parkposition anfahren (z. B. hinten oben), vor Werkzeugwechsel und nach dem Programm |
| Programm abfahren | Job direkt aus der 6axis-Bearbeitung (oder G-Code-Datei) starten, Fortschritt, Restzeit, **Pause / Fortsetzen / Stopp**, Start ab einer Zeile, **Vorschub- und Drehzahl-Override** während der Fahrt |
| Werkzeugwechsel | Programm hält, parkt, fordert das nächste Werkzeug an, Z neu antasten, weiter |
| Spindel / Absaugung | Ein/Aus, Drehzahl (wenn die Steuerung sie schaltet), Absaugung automatisch mit der Spindel |
| Sicherheit | Software-Endlagen, Prüfung „Job passt in den Arbeitsraum“, Bestätigung vor dem Start, Alarm-Meldungen im Klartext, Notstopp-Taste (Leertaste/Esc → sofortiger Halt) |

### Technik (nativ)
- **USB-Seriell** über die macOS-Systemschnittstellen (IOKit/POSIX) – keine Zusatzbibliothek; übliche USB-Chips (FTDI, CH340, CP210x) bringt macOS mit
- **Streaming nach GRBL-Protokoll** mit Zeichenzählung (Puffer der Steuerung bleibt gefüllt, gleichmäßige Fahrt), Echtzeitbefehle (Halt, Fortsetzen, Reset, Override) sofort
- **Gamepad** über GameController.framework, Tastatur über die normale Eingabe
- Steuerung läuft in einem eigenen Thread, damit die Oberfläche das Fräsen nie stört

### Sicherheit (gilt besonders hier)
- Software ersetzt **keinen Not-Aus**: die Fräse braucht einen echten Not-Aus-Schalter, der die Motoren/Spindel stromlos macht – darauf weist 6axis beim ersten Verbinden hin
- „Stopp“ in 6axis = sofortiger Vorschubhalt und Reset der Steuerung; die Taste ist immer sichtbar und groß
- Kein Start ohne Referenz/Nullpunkt-Prüfung, ohne Simulation und ohne Bestätigung; bei Verbindungsabbruch hält die Steuerung (GRBL stoppt, wenn keine Daten mehr kommen – Puffer ist klein)
- Erste Tests immer „in der Luft“ (Z hoch genullt) – der Assistent bietet das an

## Vorschlag für die Umsetzung in Stufen

### Stufe 1 – 2,5D für Platten (Holzwerkstatt)
- Einrichtung: Rohteil aus dem Bauteil (Hüllquader + Aufmaß) oder Plattenmaß, Nullpunkt wählbar, Sicherheitshöhe
- Werkzeugbibliothek mit typischen Holzfräsern (Schaftfräser 3/6/8/12 mm, Bohrer 5/8/35 mm, V-Nut 90°) und Schnittwerten
- Bearbeitungen: **Kontur** (außen/innen/auf Linie, Haltestege, Zustellung in Schritten), **Tasche**, **Bohren** (erkennt Bohrungen aus dem Modell, z. B. System-32-Reihen und Dübellöcher), **Nut**
- Bahnen mit Clipper2, Rampeneintauchen, Fräsrichtung Gleich-/Gegenlauf
- Vorschau der Bahnen im 3D-Fenster, Laufzeit-Schätzung
- Postprozessoren: GRBL, LinuxCNC, Mach3
- Mehrere Teile eines Korpus auf einer Platte (verbindet sich mit dem **Plattenzuschnittplan** aus der Feature-Sammlung: Verschachtelung/Nesting)

### Stufe 2 – Maschinensteuerung (wie Estlcam-CNC)
- Verbinden (USB), Positionsanzeige, Joggen (Tastatur, Gamepad), Referenzfahrt, Nullpunkt setzen und antasten (Z mit Tastplatte), Parken
- Job aus 6axis oder G-Code-Datei abfahren: Fortschritt, Pause/Stopp, Overrides, Werkzeugwechsel
- Live-Fräserposition im 3D-Fenster
- Assistent: GRBL auf Estlcam-Hardware (Arduino + CNC-Shield) aufspielen und Achsen einrichten
- Testbar ohne Fräse über einen eingebauten GRBL-Simulator (Testsuite im CI)

### Stufe 3 – Komfort und Sicherheit
- Simulation des Materialabtrags (Höhenkarte), Warnungen (Restmaterial in Innenecken, Fräser zu kurz, Haltestege fehlen)
- Adaptives Ausräumen (gleichmäßige Fräserlast) für Aluminium und harte Hölzer
- Bearbeitung von beiden Seiten (Wenden), Bezugsbohrungen
- Weitere Postprozessoren nach Bedarf (UCCNC, Estlcam, grblHAL-Varianten)

### Stufe 4 – 3D
- Schruppen und Schlichten von Freiformen mit OpenCAMLib (Drop-Cutter, Wasserlinie, Kugelfräser)
- 3D-Simulation

## Offene Fragen an den Werkstatt-Alltag
- **Stand beim Tester:** Fräse mit **Sub-D-25-Anschluss** (Parallelport, Schritt/Richtung) und einem USB-Konverter dazwischen – vermutlich ein Arduino-basierter Adapter mit Estlcam-Firmware. Für 6axis: GRBL auf diesen Adapter spielen (wenn Arduino-basiert und die Pinbelegung passt) oder eine GRBL/grblHAL-Platine mit Sub-D-25-Ausgang verwenden. Ein reines USB-Druckerkabel kann keine Schrittsignale erzeugen. → Modell/Foto des Konverters klären.
- **Zur Maschinensteuerung** (an den Freund mit Estlcam): Welche Steuerung steckt in der Fräse (Arduino Uno/Nano/Mega mit CNC-Shield, Estlcam-Klemmenadapter, etwas anderes)? Gibt es Endschalter (Referenzfahrt)? Tastplatte oder Längensensor für Z? Schaltet die Steuerung die Spindel (Relais/PWM) oder läuft die Oberfräse separat? Wäre ein Umstieg auf GRBL auf derselben Hardware in Ordnung?
- Welche Fräse und Steuerung wird genutzt (GRBL, Mach3, Estlcam, LinuxCNC, Industrie)? → bestimmt den ersten Postprozessor
- Typische Arbeiten: Plattenteile mit Bohrungen ausschneiden? Taschen/Nuten? Gravuren/Schilder? 3D-Reliefs?
- Arbeitsweise: ganze Platte verschachteln oder Einzelteile auf Rohlingen?

## Sicherheit
CAM erzeugt Maschinenbewegungen. Deshalb: keine Ausgabe ohne Simulation und Plausibilitätsprüfung, deutliche Hinweise auf Nullpunkt und Werkzeuge in der Datei, Probelauf „in der Luft“ empfehlen. Die Verantwortung für den Betrieb der Maschine bleibt beim Anwender – das steht auch im Ausgabedialog.
