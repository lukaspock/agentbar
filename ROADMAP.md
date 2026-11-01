# AgentBar – Roadmap & Handover

Letzter Stand: 2026-11-01. Lies zuerst `CONTRACTS.md` (Verträge, Wire-Protokoll, "Phase 1 as built"),
danach `Docs/research/integrations.md` (Claude-Hooks/Codex-Recherche) und `Docs/research/e2e-claudecode.md`.
Rolle beim Weiterarbeiten: Coordinator/Product Owner, der Code delegiert; Berichte der Subagents immer selbst nachprüfen.

## Status
**Phase 1 (MVP): gebaut, nachgeprüft, vom User am Notch teilweise handgetestet.**
- Kern/Transport (`Packages/AgentBarCore`): Store, Unix-Socket mit Token, CLI `agentbar` (update/ask/log/end/remove/hook).
- ClaudeCode-Adapter + "Hooks einrichten…" (Diff-Vorschau, Backup, Bestätigung).
- UI: Blob-Figuren (freundliche Statusfigur), Hover-Panel, Notch/Pille/Kreis, Antwortfeld, Stopp-Knopf.
- Agents entfernen: Kreuz pro Zeile, "Wirklich?"-Bestätigung bei aktiven, "Erledigte entfernen", CLI `agentbar remove`.
- Zahlen zuletzt: `swift test` 68 grün (1 übersprungen), `Tests/e2e.sh` 51/51, App-Build ohne Swift-Warnungen.

**Vom User live bestätigt:** Hover auf/zu, Freigabe per Klick (Ja), Textantwort tippen, mehrere Sessions parallel.

## Offene Punkte aus Phase 1 (zuerst erledigen)
1. **Echter Claude-Code-Lauf:** scheiterte an abgelaufenem `claude`-Login. Nach Login:
   `AB_REAL_CLAUDE=allow|deny|timeout AB_REAL_OUT=<dir> swift test --filter testRealClaudeRun`, dann "Hooks einrichten…" in der App.
   Zu verifizieren: PermissionRequest-Payload, `permission_suggestions` + "Immer erlauben" (`updatedPermissions`), Timeout-Fallthrough,
   Race zwischen Terminal-Antwort und wartendem Hook, Live-Reload der Hook-Config. Ergebnis in `Docs/research/e2e-claudecode.md` nachtragen.
2. **UI ungetestet:** Pille und Kreis (Ziehen, Position merken), Klick-Durchlass der transparenten Fläche, Augen-Verfolgung der Maus,
   Animationen (nur Standbilder gesehen), Mac ohne Notch, mehrere Displays, Release-Build, App an festem Ort (z. B. /Applications).
3. **Entfernen-Kreuz:** laut Subagent sitzt es nur an done/idle/error-Zeilen; für arbeitende/wartende Sessions (mit "Wirklich?")
   prüfen, ob es erreichbar ist (Soll: per Hover sichtbar). Echter Mausklick darauf nie getestet.
4. **Hook-Pfad:** Hooks speichern den absoluten Pfad zum CLI im App-Paket. App verschieben = Hooks brechen. Lösung evtl. Kopie des CLI nach
   `~/Library/Application Support/AgentBar/bin/` bei Setup (Produktentscheidung offen).
5. **Burst-Last:** ~190 Verbindungen in wenigen ms → einzelne ECONNREFUSED (Listen-Backlog). Niedrig; ggf. Backlog erhöhen.
6. Beendete Sessions: werden nach 10 min oder >20 Sessions entfernt (Standard); bei Bedarf einstellbar machen.

## Produktentscheidungen (offen, vom User zu beantworten)
- Aufmerksamkeit bei neuer Anfrage: nur Farbwechsel (aktuell) oder zusätzlich dezenter Ton und optional kurzes Auto-Aufklappen (abschaltbar)?
- Optik: Blob-Größe, Tempo des Aufklappens, "Working"-Blob ist in der Leiste fast weiß statt getönt – gewünscht?
- Abnahme Phase 1 durch den User steht noch aus.

## Phase 2 (nach Abnahme von Phase 1)
- **Codex-Adapter:** laut Recherche hat Codex Hooks mit sehr ähnlichem Schema (`~/.codex/hooks.json` bzw. `config.toml`, Events u. a.
  PermissionRequest, Stop; Quelle siehe `Docs/research/integrations.md`) plus `notify` und `codex exec --json`. `codex` ist lokal nicht installiert
  → zuerst Installation nur nach Rückfrage, Schema live verifizieren (alles bisher UNVERIFIED).
- **GenericCLI-Adapter:** stdin/stdout oder Webhook (lokal, Token) für beliebige Agents; `agentbar` CLI deckt vieles schon ab → Wrapper-Befehl
  `agentbar run -- <cmd>` prüfen.
- **Mehrere Sessions parallel** (Grundlage vorhanden): Sortierung/Gruppierung nach Projekt, Auswahl-UI, Verlauf pro Session ausbauen.
- **Töne** (optional, abschaltbar), ggf. Auto-Aufklappen bei Anfrage.
- Optional: MCP-Server, damit Agents selbst Fragen stellen (`ask` als MCP-Tool).

## Phase 3
- **Chat-Eingabe zum Agent:** gestreamter Prozess (`claude -p --input-format stream-json --output-format stream-json`) oder SDK `canUseTool`.
  Hooks können keinen Text in laufende TUI-Sessions injizieren (Recherche). Wire-Format des Control-Protokolls ist UNVERIFIED.
- **ComputerUse-Adapter:** Aktions-Log in Klartext (`currentAction` im Modell vorhanden), Stopp-Kanal: `SessionStore.stopHandler` +
  `supportsStop` sind schon angelegt; Pause/Stopp muss sofort wirken (kein Bestätigungsdialog).

## Später (nur auf Wunsch)
- Isolierte Umgebung (VM oder zweiter Benutzer) als Ziel für Computer-Use-Agents.
- Notchy-Modul, das denselben Kern nutzt (`../Notchy` hat ein Modulsystem, siehe `../ARCHITECTURE.md`; bisher bewusst unberührt).
- Release-Packaging (Signierung, Notarisierung, Installation nach /Applications).

## So arbeitest du weiter
Build und Tests (Pfade anpassen, eigener Derived-Data-Pfad pro Build-Session):
```
cd AgentBar/Packages/AgentBarCore && swift build && swift test && bash Tests/e2e.sh
cd AgentBar/App && xcodegen generate && xcodebuild -project AgentBar.xcodeproj -scheme AgentBar -derivedDataPath /tmp/ab-dd-X build
```
Demo ohne echte Agents: `AgentBar --demo`, `--demo-state idle|working|needsInput|question|error|computer|many`, `--demo-expanded`,
`--presentation notch|pill|circle`. Debug: `AGENTBAR_DEBUG_HOVER=1`, `AGENTBAR_DIR=<kurzer Pfad>` (Socket-Pfad max. ~104 Zeichen),
DEBUG-Flag `--auto-answer <optionId>`.
Testregeln: vor jedem Neustart `pkill AgentBar`; läuft Notchy, zeichnet es über die Notch-Variante (Fensteraufnahmen nutzen oder Notchy beenden);
nichts an `~/.claude` ändern außer über "Hooks einrichten…" nach Bestätigung; Maus nur bewegen wenn nötig und vorher ansagen.

## Dateibesitz (Subagent-Aufträge disjunkt halten)
`Contract/` = nur Coordinator (zuletzt additiv erweitert um `ResponseSink.remove`). Store/Transport/CLI/Tests = Core-Agent.
`App/Sources/UI` + `App/Sources/App` = UI-Agent. `Adapters`/`Setup` = Adapter-Agent. Integration/Review am Ende ein eigener Agent.
