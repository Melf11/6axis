# Fehlerberichte und automatische Fehlerbehebung – Plan

Stand: Oktober 2026 · Status: Planung

Ziel: Fehler direkt in 6axis melden – in einem kleinen Chat – und freigegebene Meldungen automatisch prüfen, strukturieren und über Nacht als einzelne Pull Requests zur Durchsicht bereitstellen. **Sicherheit hat Vorrang vor Komfort.**

## Entscheidungen

| Thema | Entscheidung |
|---|---|
| Anmeldung in der App | **GitHub-Konto** über den Device Flow („Code eingeben auf github.com“); kein Server, kein Geheimnis in der App |
| Wer darf automatisch verarbeiten lassen | **Freigabeliste im Repository** (`.github/bug-automation.yml`), nur vom Inhaber änderbar; alle anderen nur per Label `freigegeben` durch den Inhaber |
| Verarbeitung | **GitHub Actions** mit der offiziellen Claude Code Action |
| Claude-Zugang | **Claude-Pro-Token** (`claude setup-token`) als Secret `CLAUDE_CODE_OAUTH_TOKEN` |
| Ergebnis | **Ein Pull Request pro Fehler**, nie automatisch gemergt |

## Überblick

```
6axis (Einstellungen → Fehlerberichte, mit GitHub angemeldet)
   │  Chat: Beschreibung, ähnliche bekannte Fehler, Anhänge (Version, Mac, optional Screenshot/Datei)
   ▼
GitHub-Issue (Label: fehler, neu)                         ◄── auch Issues von der Webseite / per Hand
   │
   ▼  Workflow „Sichtung“ (bei neuem Issue / neuem Kommentar)
   │   • Duplikat?  → verknüpfen, Hinweis im Chat, Label duplikat
   │   • unklar?    → Rückfrage als Kommentar, Label braucht-info
   │   • Absender in der Freigabeliste oder Label „freigegeben“ vom Inhaber → Label bereit
   ▼
Workflow „Nächtliche Fehlerbehebung“ (z. B. 02:00, höchstens N Fehler)
   │   pro Fehler: Branch fix/issue-N → reproduzieren (Test/Demo-Lauf) → beheben → Tests
   │   → Pull Request „Fixes #N“ (Ursache, Lösung, Screenshots) oder Befund + Label braucht-mensch
   ▼
Inhaber prüft und merged  →  nächstes Release  →  In-App-Update  →  Chat zeigt „Behoben in 1.0.x“
```

## 1. Die App

### Einstellungen → „Fehlerberichte“
- Schalter **„Fehlerberichte in 6axis aktivieren“** (standardmäßig aus)
- **„Mit GitHub anmelden“**: 6axis zeigt einen 8-stelligen Code und öffnet `github.com/login/device`; nach Bestätigung erscheint „Angemeldet als @name“ mit **Abmelden**
- Hinweis, was übertragen wird, und Link zur Freigabeliste („Deine Berichte werden automatisch bearbeitet“ / „… nach Freigabe“)

### Anmeldung (Device Flow)
- Eigene **GitHub-OAuth-App „6axis“** mit aktiviertem Device Flow; in der App steht nur die **öffentliche Client-ID** (kein Client-Secret – der Device Flow braucht keins)
- Berechtigung (Scope): **`public_repo`** – nötig, um im öffentlichen Repository Issues und Kommentare anzulegen. Mehr wird nicht angefragt.
- Token im **macOS-Schlüsselbund** (Keychain, nur diese App); Abmelden löscht es; widerrufbar unter GitHub → Settings → Applications
- Netzwerkzugriffe nur bei eingeschalteter Funktion und während der Chat benutzt wird (Leitlinie 7)

### Der Chat
- Menü **Hilfe → Fehler melden …** öffnet ein schmales Fenster:
  - **Neuer Bericht:** Freitext; schon beim Tippen „Ähnliche bekannte Fehler“ (GitHub-Suche, ohne KI) – ein Klick öffnet den Verlauf dieses Fehlers und man kann dort ergänzen statt doppelt zu melden
  - **Anhänge:** Version, Build, macOS, Mac-Modell automatisch; **optional** Screenshot des Fensters und die aktuelle `.6axis`-Datei; **Vorschau vor dem Senden**, nichts wird ungefragt hochgeladen
  - **Meine Berichte:** Liste mit Stand (neu · Rückfrage · in Arbeit · Fix bereit · behoben in x.y.z); jeder Bericht als Verlauf – Rückfragen der Sichtung erscheinen als Nachrichten, man antwortet direkt
- Dateianhänge: GitHub hat keine Upload-Schnittstelle für Bilder und Dateien in Issues. Möglich ist, sie als **Gist des Melders** abzulegen und im Issue zu verlinken (dafür zusätzlich der Scope `gist`, nur auf ausdrücklichen Wunsch) – oder in der ersten Version nur Text zu senden. → offene Frage unten.

## 2. Das Repository

### Freigabeliste `.github/bug-automation.yml`
```yaml
# Wessen Fehlerberichte automatisch verarbeitet werden (GitHub-Benutzernamen).
reporters:
  - Melf11
# Grenzen für den nächtlichen Lauf
max_fixes_per_night: 3
max_minutes_per_fix: 45
```
- Geschützt durch **`CODEOWNERS`** (`/.github/ @Melf11`) und **Branch-Schutz auf `main`**: Änderungen nur per Pull Request mit Zustimmung des Inhabers, CI muss grün sein
- Workflows lesen die Liste immer **vom Stand auf `main`**, nie aus einem PR-Branch

### Labels (Zustände)
| Label | Bedeutung |
|---|---|
| `fehler` | Fehlerbericht |
| `neu` | noch nicht gesichtet |
| `duplikat` | verweist auf ein bestehendes Issue |
| `braucht-info` | Rückfrage an den Melder offen |
| `freigegeben` | vom Inhaber freigegeben (für Melder außerhalb der Liste) |
| `bereit` | darf nachts automatisch bearbeitet werden |
| `in-arbeit` | wird gerade bearbeitet |
| `fix-bereit` | Pull Request liegt vor |
| `braucht-mensch` | automatische Behebung nicht möglich, Befund im Issue |

## 3. Workflows (GitHub Actions)

### „Sichtung“ – `.github/workflows/bug-triage.yml`
- Auslöser: `issues: opened, edited, labeled` und `issue_comment: created` (nur Issues mit `fehler`)
- Läuft auf Ubuntu (schnell, kein Build nötig); Claude Code mit **nur Lese-Werkzeugen + GitHub-CLI für Issues**
- Aufgaben: Duplikate anhand offener und der letzten 90 Tage geschlossener Issues finden; Bericht in festes Format bringen (Schritte, erwartet, tatsächlich, Version); Rückfragen stellen; Freigabe prüfen und `bereit` setzen
- Freigabe-Prüfung **in Code, nicht durch die KI**: ein kleines Skript liest die Freigabeliste von `main` und prüft den Autor bzw. per GitHub-API, **wer** das Label `freigegeben` gesetzt hat

### „Nächtliche Fehlerbehebung“ – `.github/workflows/bug-fix.yml`
- Auslöser: Zeitplan (z. B. 02:00) und manuell (`workflow_dispatch`, auch für ein einzelnes Issue)
- Läuft auf **macOS** wie das CI (Xcode, OpenCASCADE), **ein Job pro Fehler** (Matrix), höchstens `max_fixes_per_night`, Zeitlimit pro Job
- Vor dem Start nochmals Freigabe prüfen (Skript); dann Label `in-arbeit`
- Auftrag an Claude: Leitlinien aus `AGENTS.md` befolgen; Fehler zuerst **reproduzieren** (Test oder Demo-Lauf), dann beheben; `swift test`, `scripts/ui-check.sh`, `scripts/update-strings.sh --check` müssen grün sein; keine Workflows, Secrets, Release- oder Signatur-Dateien anfassen
- Ergebnis: Branch `fix/issue-N`, **Pull Request „Fixes #N“** mit Ursache, Lösung, Testnachweis und Screenshots aus dem Demo-Lauf; Label `fix-bereit`. Gelingt das nicht: Befund als Kommentar, Label `braucht-mensch`
- Der PR durchläuft das normale CI; **gemergt wird nur durch den Inhaber**

## 4. Sicherheit

| Risiko | Gegenmaßnahme |
|---|---|
| Geheimnisse in der Open-Source-App | Es gibt keine: Device Flow mit öffentlicher Client-ID, Token pro Nutzer im Schlüsselbund |
| Fremde lassen Code ändern | Automatische Verarbeitung nur für die Freigabeliste oder nach Label durch den Inhaber – geprüft per Skript, nicht durch die KI |
| Eingeschleuste Anweisungen im Bugtext („Prompt Injection“) | Wenige vertrauenswürdige Melder; minimale Rechte; feste Arbeitsanweisung; Ergebnis ist nur ein PR, der Durchsicht und CI braucht |
| Agent greift nach Secrets | Fix-Workflow bindet nur `CLAUDE_CODE_OAUTH_TOKEN` und das automatische `GITHUB_TOKEN` ein; der Signaturschlüssel existiert nur im Release-Workflow, der nur bei vom Inhaber gepushten Tags läuft |
| Agent ändert Workflows oder schützt sich Rechte zu | `GITHUB_TOKEN` ohne `workflows`-Recht kann keine Workflow-Dateien pushen; Rechte im Workflow auf `contents: write, pull-requests: write, issues: write` begrenzt |
| Änderungen gelangen ungeprüft in `main` | Branch-Schutz: nur per PR, CI grün, Zustimmung des Inhabers; kein Auto-Merge |
| Kosten/Kontingent laufen aus dem Ruder | Höchstzahl pro Nacht, Zeitlimit pro Fehler, begrenzte Agenten-Durchläufe; Pro-Kontingent statt Abrechnung nach Verbrauch |
| Privatsphäre der Melder | Nur, was in der Vorschau steht, wird gesendet; Konstruktionsdateien nur auf ausdrücklichen Wunsch; Issues sind öffentlich – darauf weist der Chat hin |

## 5. Claude-Pro-Token

- Erzeugen auf dem eigenen Mac: `claude setup-token` → als Repository-Secret **`CLAUDE_CODE_OAUTH_TOKEN`** hinterlegen
- Die Nutzung zählt gegen das **Pro-Kontingent** (es gibt Nutzungsgrenzen pro Zeitfenster); deshalb anfangs **höchstens 3 Fehler pro Nacht**. Reicht das Kontingent nicht, bricht der Lauf sauber ab und versucht es in der nächsten Nacht erneut (Label bleibt `bereit`)
- Das Token ist an das Konto gebunden; bei Verdacht sofort neu erzeugen und das alte verwerfen

## 6. Einrichtung – was der Inhaber einmalig tut

1. **GitHub-OAuth-App anlegen:** github.com → Settings → Developer settings → OAuth Apps → *New OAuth App*
   - Name `6axis`, Homepage `https://melf11.github.io/6axis/`, Callback-URL beliebig (wird beim Device Flow nicht genutzt, z. B. die Homepage)
   - **„Enable Device Flow“ anhaken** → die **Client-ID** an Claude geben (öffentlich, kommt in die App)
2. **Claude-Token:** `claude setup-token`, als Secret `CLAUDE_CODE_OAUTH_TOKEN` hinterlegen
3. **GitHub-CLI anmelden** (`gh auth login`), damit Branch-Schutz, Labels und Workflows eingerichtet und getestet werden können
4. Freigabeliste pflegen: eigene und vertrauenswürdige Benutzernamen eintragen (per PR)

## 7. Stufen

| Stufe | Inhalt | Fertig, wenn |
|---|---|---|
| **1 Repository** | Freigabeliste, `CODEOWNERS`, Labels, Branch-Schutz `main`, Skript zur Freigabeprüfung mit Tests | Branch-Schutz aktiv; Skript entscheidet korrekt für Liste/Label/Fremde |
| **2 Sichtung** | Workflow `bug-triage.yml`, Issue-Vorlage angepasst | Test-Issue wird strukturiert, Duplikat erkannt, `bereit` nur bei Freigabe |
| **3 App** | Einstellungen, Device-Flow-Anmeldung, Schlüsselbund, Chat (neu, ähnliche Fehler, Anhänge-Vorschau, Meine Berichte, Antworten), Übersetzungen | Bericht aus der App landet als Issue; Rückfrage erscheint im Chat; Abmelden löscht Token |
| **4 Nächtliche Behebung** | Workflow `bug-fix.yml` (Matrix, Grenzen, Labels, PR-Vorlage) | Absichtlich eingebauter Test-Fehler wird über Nacht als PR mit grünem CI geliefert |
| **5 Feinschliff** | „Behoben in x.y.z“ im Chat nach Release, Übersicht für den Inhaber (z. B. wöchentliche Zusammenfassung als Issue) | – |

Testen ohne echte Melder: Sichtung und Freigabeprüfung bekommen einen **Trockenlauf-Modus** (nur protokollieren, nichts ändern); die App-Seite wird gegen eine nachgebildete GitHub-Schnittstelle getestet (`SIXAXIS_GITHUB_API` auf einen lokalen Testserver).

## Offene Fragen
1. **Anhänge:** in Stufe 3 nur Text (einfach, sicher) oder gleich Screenshot/Datei (über Gists des Melders, zusätzlicher Scope `gist`)?
2. **Uhrzeit und Menge** des nächtlichen Laufs (Vorschlag: 02:00, höchstens 3)?
3. **Benachrichtigung:** reichen die normalen GitHub-Benachrichtigungen (E-Mail/App) für neue PRs, oder zusätzlich eine tägliche Zusammenfassung?
