# Technischer Zeichnungseditor

Ziel: Aus dem 3D-Modell wird automatisch eine normgerechte 3-Tafel-Projektion mit Bemaßung abgeleitet – in einem eigenen Fenster, das nur bei Bedarf geöffnet wird und mit dem Modell synchron bleibt. Zielgruppe sind u. a. Tischler, die nach der Zeichnung in Holz fertigen.

## Entscheidungen

| Thema | Entscheidung |
|---|---|
| Projektionsmethode | Methode 1 (Europa, ISO 5456-2): Draufsicht unter, Seitenansicht von links rechts neben der Vorderansicht |
| Bemaßungsstil | **Bezugsmaße von einer Anschlagkante** (Parallelbemaßung, ISO 129-1): links bzw. unten als Bezug |
| Genauigkeit | **Ganze Millimeter** |
| Blatt | **Querformat**, automatisch A4 → A3 → A2, je nach Größe |
| Mehrere Körper | **Gesamtansicht** mit allen Teilen in Einbaulage, dazu Positionsnummern, Stückliste und Einzelteilblätter (abschaltbar) |
| Material / Faserrichtung | pro Körper im Browser, in Stückliste und Einzelteilen |

## Normen

- ISO 5456-2 – Projektionsmethode 1, Projektionssymbol im Schriftfeld
- ISO 128 – Linienarten: sichtbare Kanten breit (0,5 mm), verdeckte Kanten schmal gestrichelt (0,25 mm), Mittellinien schmal strichpunktiert
- ISO 129-1 / DIN 406 – Bemaßung: Maßhilfslinien, Maßlinien mit gefüllten Pfeilen, erste Maßlinie 10 mm, weitere 7 mm Abstand, jedes Maß nur einmal
- ISO 5457 / ISO 7200 – Blattformate, Rahmen, Schriftfeld (Benennung, Zeichnungsnummer, Maßstab, Projektionssymbol, Datum, Ersteller, Material, Blatt)
- ISO 5455 – Maßstäbe 5:1, 2:1, 1:1, 1:2, 1:5, 1:10, 1:20, 1:50
- DIN 919 – Technische Zeichnungen Holzverarbeitung (Orientierung)

## Architektur

```
OCCTBridge   ob_hlr(): exakte Verdeckungsrechnung (HLRBRep), liefert 2D-Polylinien
             mit Typ (sichtbar/verdeckt, Kante/Umriss) und Kreise (für Ø und Mittellinien)
SixAxisCore  Drawing/   reines 2D-Zeichnungsmodell in Papier-Millimetern
                        DrawingGenerator: Ansichten → Layout → Maßstab → Bemaßung
                        (testbar ohne UI)
SixAxis      Drawing/   Fenster, Darstellung (Core Graphics), PDF-Export, Druck
```

- Bildschirm, PDF und Druck nutzen **dieselbe** Core-Graphics-Zeichenroutine → exakt, was man sieht.
- Alle sichtbaren Körper werden **gemeinsam** projiziert, damit sich Teile korrekt gegenseitig verdecken.
- **Synchronisation:** Bei Modelländerungen wird im Hintergrund neu berechnet (entprellt), nur solange das Zeichnungsfenster offen ist. Ergebnisse werden pro Modellstand gecacht.
- Zeichnungseinstellungen (Blatt, Maßstab, Schriftfeld) werden in der `.6axis`-Datei gespeichert (optional, rückwärtskompatibel).

## Automatische Bemaßung (Regeln)

1. **Gesamtmaße** (Länge, Breite, Höhe) jeweils dort, wo sie in wahrer Größe erscheinen: Breite und Höhe in der Vorderansicht, Tiefe in der Seitenansicht.
2. **Bezugsmaße** von der Anschlagkante: alle markanten Kantenlagen (Absätze, Teilekanten, Böden) werden von der linken bzw. unteren Kante aus parallel bemaßt, das kürzeste Maß innen.
3. **Bohrungen** in der Ansicht, in der sie als Kreis erscheinen: Ø-Angabe, Mittellinien, Lage von den Bezugskanten.
4. **Rundungen** (Abrundungen, Bögen) dort, wo sie in wahrer Gestalt erscheinen: „R5“ bzw. „4× R5“, Hinweislinie von außen mit Pfeil auf den Bogen (ISO 129-1).
5. **Fasen** (kurze 45°-Kanten): Hinweislinie „Fase 2 × 45°“, gleiche zusammengefasst „(4×)“; ihre Kantenlinien in den anderen Ansichten werden nicht zusätzlich bemaßt. **Schrägen**: Winkelmaß (Bogen zur waagerechten bzw. senkrechten Bezugskante, ganze Grad), Anfang und Ende über die Bezugsmaße.
6. Jedes Maß nur **einmal**; Positionen, die schon in einer Ansicht bemaßt sind, werden in anderen weggelassen.
7. Längen auf **ganze Millimeter** gerundet (Radien und Durchmesser bei Bedarf mit einer Nachkommastelle, z. B. R2,5); sehr dicht liegende Lagen (< 1 mm) werden zusammengefasst.

## Etappen

1. **Grundlage** – Verdeckungsrechnung, Zeichnungsfenster, Blatt mit Rahmen und Schriftfeld, Vorder-/Drauf-/Seitenansicht + Isometrie, automatischer Maßstab, Live-Synchronisation, PDF-Export
2. **Automatische Bemaßung** – Gesamtmaße, Bezugsmaße, Bohrungen mit Mittellinien, kollisionsfreie Anordnung
3. **Bearbeiten** – Maße verschieben, ausblenden, ergänzen; Ansichten verschieben; Schriftfeld ausfüllen (Anpassungen überleben Modelländerungen)
4. **Mehrere Körper erweitert** – Einzelteilblätter, Stück- und Zuschnittliste, Positionsnummern
5. **Erweiterungen** – DXF-Export (CNC/Laser), Schnittansichten, Detailansichten, Material und Faserrichtung

## Stand

- [x] **Etappe 1 – Grundlage**: HLR-Projektion (`ob_hlr`), Zeichnungsfenster (⇧⌘D), Blatt mit Rahmen, Zentriermarken und Schriftfeld, Vorder-/Draufsicht/Seitenansicht von links + Isometrie, automatische Blatt- und Maßstabswahl, Live-Synchronisation im Hintergrund, PDF-Export (maßstabsgetreu), Drucken
- [~] **Etappe 2 – Automatische Bemaßung**: Gesamtmaße, Bezugsmaße von links/unten, Bohrungen (Ø, n×, Mittellinien, Lage) erledigt; Radien (R, n× R, Pfeil auf den Bogen, einmal je Blatt, Dezimalstelle mit Komma bei Bedarf), Fasen („Fase 2 × 45°“, „(4×)“), Schrägen mit Winkelmaß und Bezugsmaßen der Endpunkte, Hinweislinien weichen einander aus; offen: verdeckte Merkmale
- [x] **Etappe 3 – Bearbeiten**: Maße auswählen (Hover/Klick), ziehen (Maßlinie rastet in 7-mm-Reihen ein und weicht anderen aus, Wert verschiebt sich entlang der Linie), ausblenden (⌫), eigene Maße zwischen Eckpunkten/Bohrungsmitten (D, waagerecht/senkrecht/schräg je nach Platzierung, folgen Modelländerungen), Ansichten verschieben (Projektionsflucht bleibt erhalten, Isometrie frei), Zurücksetzen-Menü, alles rückgängig machbar und in der Datei gespeichert. Stabile Maß-Kennungen („front.x.481“) halten Anpassungen über Modelländerungen hinweg
- [x] **Etappe 4 – Mehrere Körper**: Positionsnummern (ISO 6433, verschiebbar), Stück-/Zuschnittliste über dem Schriftfeld (ISO 7573: Pos., Benennung, Anzahl, Länge × Breite × Dicke, Material), Erkennung gleicher Teile (Maße, Volumen, Topologie), Einzelteilblätter mit automatischer Ausrichtung (Länge → x, Breite → oben, Dicke → Tiefe), bis zu 4 Teile je Blatt mit eigenem Maßstab, Blattnummern „n / N“, Blatt-Reiter im Fenster, mehrseitiger PDF-Export und Druck, Schalter im Menü „Blätter“
- [x] **Etappe 5 – Erweiterungen**: Material und Faserrichtung je Körper (Browser → Rechtsklick; Stückliste, Faserpfeil auf Einzelteilen, getrennte Positionen bei anderem Material), DXF-Export R12 (Blatt mit ISO-Ebenen; Einzelteile 1:1 für CNC/Laser mit echten Kreisen), Schnitt A–A der Seitenansicht (Schraffur je Teil wechselnd, Schnittverlauf mit Pfeilen, mit der Maus verschiebbar), Einzelheiten (Werkzeug E: Mittelpunkt und Radius klicken, Vergrößerung automatisch 2:1/5:1/…, verschiebbar, löschbar)

### Testen

```bash
swift test --filter DrawingTests
# Beispiel-Korpus erzeugen, Zeichnung als PNG/PDF und Fenster-Screenshot ablegen:
SIXAXIS_DEMO=1 SIXAXIS_DRAWING_DEMO=/tmp/6axis-drawing build/6axis.app/Contents/MacOS/SixAxis
```
