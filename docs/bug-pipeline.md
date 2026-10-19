# Fehlerberichte & Fehlerbehebung

Stand: Oktober 2026 · Grundsatz: **Berichte kommen über GitHub, behoben wird lokal auf dem Mac des Inhabers.**
Keine automatische Verarbeitung in GitHub Actions, kein Claude-Zugang im Repository.

## Überblick

```
6axis (Mac der Melder)            GitHub                         Mac des Inhabers
Fehlerbericht-Chat  ──Issue──▶  Issue mit Label „fehler“  ◀──  scripts/bugfix.py (von Hand gestartet)
   GitHub-Anmeldung              Rückfragen als Kommentare       Claude Code mit deinem Login
   (nur Liste „reporters“)       Pull Request „fix/issue-N“  ◀──  prüft selbst, pusht, öffnet PR
```

## 1. Der Chat in der App
- Einstellungen → **Fehlerberichte**: aus- bzw. einschalten, mit GitHub anmelden (Device Flow, nur Scope `public_repo`, Token im Schlüsselbund dieses Macs).
- Nur Konten aus der Liste **`reporters`** sehen den Chat. Das ist Komfort, keine Sicherheitsgrenze – Issues kann bei einem öffentlichen Repository jeder anlegen.
- Netzwerk nur auf Klick (Leitlinie 7): die Berechtigung wird erst geprüft, wenn Einstellungen oder Chat geöffnet werden.
- Hilfe → „Fehler melden …“ öffnet den Chat (eingeschaltet und angemeldet), sonst wie bisher GitHub im Browser.

## 2. Freigabelisten `.github/bug-automation.yml`
```yaml
reporters:   # dürfen den Chat nutzen
  - Melf11
autofix:     # deren Berichte bearbeitet bugfix.py ohne weitere Freigabe
  - Melf11
```
- Berichte anderer werden erst bearbeitet, wenn **der Inhaber** das Label `freigegeben` setzt (geprüft in der Issue-Chronik).
- Die Listen gelten immer in der Fassung von `main` – nie aus einer Arbeitskopie. Geschützt durch CODEOWNERS (Branch-Schutz für `main` empfohlen).
- Entscheidung in einfachem Code (`scripts/bug_automation.py`), nicht durch die KI.

## 3. Das lokale Werkzeug `scripts/bugfix.py`

```bash
gh auth login                   # einmalig
claude                          # einmalig anmelden (Claude-Abo)
scripts/bugfix.py --dry-run     # zeigt, was bearbeitet würde
scripts/bugfix.py               # bis zu 3 freigegebene Berichte
scripts/bugfix.py --issue 42    # genau einen
```

Für jeden Bericht:
1. Label `in-arbeit`; eigene Arbeitskopie (`git worktree`) unter `~/.6axis-bugfix/issue-N` mit Branch `fix/issue-N` von `origin/main`.
2. Der Bericht wird als Datei `.bugfix/REPORT.md` abgelegt – **nur Text des Melders und des Inhabers**, fremde Kommentare fallen weg.
3. Claude Code läuft mit deinem Login (`claude -p`), Modus `dontAsk`: erlaubt sind nur Lesen/Ändern von Dateien und Bauen/Testen
   (`swift build/test`, `scripts/build-app.sh`, `scripts/ui-check.sh`, Übersetzungs-Skripte, `git status/diff/log`).
   **Kein Git-Commit/Push, kein `gh`, kein Netz, keine MCP-Server.** Alles andere wird ohne Rückfrage abgelehnt.
4. Claude schreibt `.bugfix/RESULT.md` (Status, Commit-Titel, Ursache, Lösung, Nachweis).
5. **Das Werkzeug prüft selbst**: geschützte Dateien unverändert (`.github/`, Update-Schlüssel, Automatisierung), Kern-Tests,
   Übersetzungen, App-Build, Oberflächenprüfung mit Grenzwerten.
6. Nur wenn alles grün ist: Commit „… Fixes #N“, Push, Pull Request, Label `fix-bereit`, Kommentar im Issue.
   Sonst: Label `braucht-mensch`, Befund als Kommentar, Arbeitskopie bleibt zum Ansehen.
7. **Gemergt wird nie automatisch** – du prüfst den Pull Request.

## 4. Prüfen, mergen, veröffentlichen: `scripts/release.py`

```bash
scripts/release.py              # Pull Requests durchgehen, danach Release anbieten
scripts/release.py --dry-run    # nur zeigen, nichts ändern
scripts/release.py --verify v2.0.3   # ein veröffentlichtes Release prüfen
```

1. Läuft nur, wenn `gh` als Inhaber angemeldet ist.
2. Für jeden offenen Pull Request (Korrekturen aus `bugfix.py` zuerst) zeigt es: behobene Issues, Umfang, CI-Status und Hinweise
   (fremder Autor, Fork, geänderte geschützte Dateien). Auswahl:
   - **b** Bericht und Lösung lesen · **d** Änderungen ansehen
   - **t** App mit genau dieser Korrektur bauen und öffnen – zum Ausprobieren neben der installierten
   - **m** mergen – nur bei grüner CI, ohne Konflikt, und nur genau der angezeigte Stand (`--match-head-commit`).
     Bei Hinweisen muss die PR-Nummer eingetippt werden. Das Issue schließt GitHub automatisch („Fixes #N“).
   - **x** verwerfen (Begründung als Kommentar, Issue → `braucht-mensch`) · **s** überspringen · **w** auf CI warten
3. Danach: was seit dem letzten Tag neu ist, Vorschlag der nächsten Version (Fehlerbehebung = letzte Stelle +1), Kurzbeschreibung,
   auf Wunsch die volle Prüfung genau dieses Stands auf dem Mac (eigene Arbeitskopie).
4. Veröffentlichen erst nach eingetipptem „ja“: Tag pushen → GitHub Actions baut und signiert → das Skript wartet,
   lädt die Dateien und prüft Prüfsummen, Update-Signatur, Version und Code-Signatur.
5. Auf Wunsch bekommen die Melder einen Kommentar „Behoben in …“.

Von Hand geht es auch: Pull Request auf GitHub ansehen → „Merge pull request“; dann
`git checkout main && git pull && git tag -a v2.0.3 -m "6axis 2.0.3 – …" && git push origin v2.0.3`.

## Sicherheit

| Risiko | Gegenmaßnahme |
|---|---|
| Zugangsdaten im Repository oder in der CI | gibt es nicht mehr: Claude läuft nur auf deinem Mac mit deinem Login |
| Fremde lösen Arbeit aus | nur Liste `autofix` oder Label `freigegeben` durch den Inhaber; Liste aus `main` |
| Manipulierter Berichtstext (Prompt-Injection) | Bericht als Daten mit Hinweis; nur Text von Melder und Inhaber; Claude ohne Netz, Git und GitHub; Werkzeug-Liste fest |
| Schädlicher Code in der Korrektur | eigene Arbeitskopie; Tests laufen auf deinem Mac – deshalb nur vertrauenswürdige Melder in `autofix`; PR-Prüfung vor dem Merge |
| Änderungen an Automatisierung/Signierung | geschützte Dateien → Abbruch |
| Ungeprüfte Änderungen landen in `main` | nie automatisch: nur Pull Requests, Merge durch dich (`release.py`: nur grüne CI, nur der angesehene Stand) |

Restrisiko: Bauen und Testen führen Code der Arbeitskopie auf deinem Mac aus. Darum bearbeitet das Werkzeug ohne
deine ausdrückliche Freigabe nur Berichte von Personen, denen du vertraust (`autofix`).

## Labels
`fehler` (Bericht), `neu`, `braucht-info` (Rückfrage offen – wird übersprungen), `freigegeben` (vom Inhaber),
`in-arbeit`, `fix-bereit` (PR offen), `braucht-mensch` (automatisch nicht gelöst), `duplikat`.

## Einrichtung (einmalig)
1. **GitHub-OAuth-App** für den Chat: github.com → Settings → Developer settings → OAuth Apps → New OAuth App
   (Name `6axis`, Homepage und Callback `https://melf11.github.io/6axis/`, **Enable Device Flow** anhaken, kein Client-Secret).
   Die Client-ID kommt in `Resources/github-client-id.txt`.
2. `gh auth login` und `claude` (anmelden) auf deinem Mac.
3. Optional: Branch-Schutz für `main` mit Code-Owner-Zustimmung.

Das frühere Konzept mit GitHub Actions und einem Claude-Token als Repository-Secret ist verworfen.
