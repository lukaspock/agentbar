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

## Phase 4 (Vision): Agent arbeitet parallel am Rechner "wie ein zweiter Mensch" (aufgenommen 2026-11-03)
Ziel des Users: Ein Agent nutzt am Ende alle Tools inkl. Maus/Tastatur/Computer Use, gleichzeitig, **ohne den User zu stören** (eigener Bildschirm, eigene Maus, eigener Fokus).
- **Einschätzung (UNVERIFIED, vor Bau per Machbarkeitsstudie prüfen):** Computer Use unter dem Daemon-Benutzer `agentbar` geht nicht (keine GUI-Sitzung, TCC-Rechte nur interaktiv). "Zweite GUI-Sitzung per Fast User Switching" stört nicht, funktioniert aber vermutlich nicht verlässlich: Eine inaktive Sitzung hat keinen aktiven Bildschirm, Screenshot und Eingabe-Events laufen dort unzuverlässig, Rechte müssen in der Sitzung selbst erteilt werden. Dieselbe Sitzung wie der User stört immer (geteilte Maus/Fokus).
- **Empfohlene Option: macOS-VM auf dem eigenen Mac** (Tart oder Virtualization.framework, Apple Silicon). Eigener virtueller Bildschirm, eigene Maus/Tastatur, eigene Benutzer, volle Isolation; Screenshots und Eingaben laufen über die VM-Schnittstelle (VNC/Virtualization-Display) statt über deine Sitzung. Bekannte Grenzen: maximal 2 macOS-VMs gleichzeitig, Ressourcenverbrauch (RAM/CPU), Einmal-Setup (Anmeldung, Bedienungshilfen/Screen-Recording-Rechte im Gast, `claude` + Token im Gast), keine iCloud-Dienste im Gast.
- **Alternativen:** zweiter physischer Mac (z. B. Mac mini) mit demselben Host-Protokoll über Netzwerk; für reine Web-Aufgaben ein headless Browser im Workspace von `agentbar` (kein Bildschirm nötig).
- **Architektur-Hinweis:** Das Host-Protokoll (Stufe 2) ist bewusst ein "dummes Rohr": `agentbar-host` kann später in der VM statt unter `agentbar` laufen; die Bar bleibt Besitzer von Freigaben/Sicherheitslogik. Transport wäre dann TCP/vsock statt Unix-Socket (neue Transport-Sicherheit nötig: Authentisierung, Verschlüsselung).
- **Nächster Schritt:** Machbarkeitsstudie (Option VM vs. zweite GUI-Sitzung vs. 2. Mac): Tart-Setup, Computer-Use-Latenz, Rechtevergabe im Gast, Host in der VM, Netzwerk-Transport. Danach Entscheidung durch den User.

## B7: First-Run-Setup im Panel (aufgenommen 2026-11-03)
Ziel: Das manuelle Terminal-Setup (Benutzer `agentbar`, Gruppe, Verzeichnisse, Daemon, Token) läuft beim ersten Öffnen der App als geführter Ablauf im Notch-Panel: Karte "Agent user einrichten", ein Klick, ein Admin-Prompt (Passwort/Touch ID), Fortschritt im Panel; Gegenstück "Entfernen". Scripts (`Scripts/setup-agent-user.sh`, `remove-agent-user.sh`) und `agentbar-host`/CLI werden ins App-Bundle gelegt.
**Machbarkeitsprüfung zuerst (kurze Experimente, UNVERIFIED bis dahin):**
1. Admin-Prompt: Setup-Script aus der App mit Admin-Rechten starten (Admin-Dialog über `osascript ... with administrator privileges` bzw. Authorization Services) gegen `SMAppService.daemon` (Daemon im Bundle, einmalige Freigabe in den Systemeinstellungen). Welcher Weg funktioniert mit lokaler/ad-hoc-Signatur?
2. Token abfangen: `claude setup-token` aus der App per PTY starten, Browser-Login des Users abwarten, Token aus der Ausgabe lesen und direkt in `~agentbar/.config/agentbar/claude-oauth-token` (0600) schreiben, ohne ihn anzuzeigen oder zu loggen. Ist die Ausgabe zuverlässig parsebar?
3. Re-Login sparen: Verzeichnis `/Users/Shared/AgentBar` im Setup mit Gruppe `agentbar-ipc` anlegen, sodass neue Dateien (Socket) die Gruppe erben und kein `chown` auf die Gruppe nötig ist (BSD-Semantik); danach entfällt das Ab-/Anmelden.
4. Fehler- und Rückbaupfade (Teil-Setup erkennen und reparieren; die Lektionen aus Nachtrag 2 in HANDOFF.md).
**Verteilung:** Für andere Nutzer wäre eine Developer-ID-Signatur plus Notarisierung nötig (bezahlter Apple Developer Account); sonst Gatekeeper-Warnung ("Trotzdem öffnen") oder Selbstbau aus dem Quellcode. Für den eigenen Mac reicht die lokale Signatur.
**Reihenfolge:** nach B4 und B5. Die Experimente 1 und 2 brauchen den User (Admin-Passwort, Browser-Login).

### B7: Entscheidungen des Users (2026-11-03, nach Machbarkeitsprüfung, Bericht: Docs/research/b7-feasibility.md)
- **Apple-Account:** kostenlos (kein Developer-ID/Notarisierung). Lokale Signatur genügt für den eigenen Mac; Verteilung an andere später per Gatekeeper-Hinweis oder Selbstbau.
- **Admin-Weg:** `NSAppleScript do shell script ... with administrator privileges` (ein Passwortdialog), gebündeltes Setup-Script mit einkompiliertem SHA-256 geprüft. `SMAppService` nicht als Hauptweg.
- **Token:** per PTY-Prototyp (`claude setup-token`, sehr breites PTY, zeilenweises Matching), vorab als Besitzer holen, per kurzlebiger 0600-Datei an das root-Script übergeben, danach löschen: ein Passwortprompt.
- **Entfernen im Panel:** löscht nach Bestätigung auch das Home des Agent-Benutzers inkl. Workspaces (klare Warnung vorher).
- **Tests mit dem User:** Admin-Dialog-Testprogramm (`/private/tmp/b7-experiments/admin/osa`, harmlos, `id -u`) und echter `setup-token`-Lauf mit Browser-Login; Token nie im Chat zeigen.
- **Re-Login sparen:** Gruppenvererbung ist gemessen (macOS vererbt die Verzeichnisgruppe); das Setup legt `/Users/Shared/AgentBar` einmal mit `agentbar-ipc` an, der Server soll kein `chgrp` mehr aufrufen.
