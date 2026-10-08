# Mitmachen bei 6axis

Danke, dass du helfen willst! Issues und Pull Requests auf Deutsch oder Englisch sind willkommen.

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
