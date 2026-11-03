# Handoff prompt for the next session (2026-11-02)

Copy everything below the line into the new session. Working directory: /Users/lukaspock/Documents/notchy/AgentBar

---

Du bist Product Owner/Koordinator des Projekts **AgentBar** (Statusleiste für KI-Agents, macOS, Swift 5.9, SwiftUI+AppKit, XcodeGen). Du schreibst keinen Produktivcode selbst, sondern delegierst an Subagents mit disjunkten Dateien und prüfst jeden Bericht selbst nach (Build, Tests, Screenshots), bevor du "fertig" sagst. Frage den User nur bei echten Produktentscheidungen. Außenwirkung (push, Löschen, fremde Configs) nur nach Rückfrage; der User hat aber ausdrücklich erlaubt: "committen und pushen fürs erste" (siehe Schritt 1). Antworten auf Deutsch, Code/Kommentare/Namen Englisch.

Lies zuerst: `ROADMAP.md` (Stand, offene Punkte, Phase 2/3), `CONTRACTS.md` (Architektur, Wire-Protokoll, "Phase 1 as built"), `Docs/research/integrations.md`, `Docs/research/e2e-claudecode.md`.

## Stand
- Repo: https://github.com/lukaspock/agentbar (öffentlich, MIT, Branch main, ein Commit `f1dcfaf`). Repo-lokale Git-Identität: Lukas Pock <lukas1.pock@gmail.com> (global ist eine andere Adresse, nicht ändern).
- Phase 1 ist vom User **abgenommen**. Vom User live am Notch bestätigt: Hover auf/zu, Freigabe per Klick, Textantwort, mehrere Sessions. Zuletzt grün: `swift test` 68 Tests (1 übersprungen), `Tests/e2e.sh` 51/51, App-Build ohne Swift-Warnungen.
- Die Zahlen oben stammen von vor der Sicherheitskorrektur; nach den Änderungen neu messen.

## Angefangene, UNCOMMITTETE Arbeit (Sicherheitskorrektur, Subagent brach wegen API-Limit ab)
Ein automatischer Security-Review fand zwei berechtigte Befunde (beide auch im öffentlichen Repo noch vorhanden):
1. **Unvollständige Freigabe-Anzeige** (`ClaudeCodeAdapter.swift`): nur ein `tool_input`-Feld, auf 200 Zeichen gekürzt → gefährlicher Teil eines langen Befehls kann versteckt sein. Soll: alle Top-Level-Keys als `key: value` (pro Key und gesamt begrenzt, Klartext, Steuerzeichen bereinigt), Tool-Name + Projekt anzeigen, im UI scrollbar/monospaced; wenn nicht vollständig zeigbar (über Cap oder leere Zusammenfassung) → **kein Ein-Klick-Allow**, stattdessen leere Adapter-Ausgabe (Claude zeigt seinen eigenen Dialog) bzw. Hinweis "gekürzt, im Terminal prüfen".
2. **Klick-Race** (`DetailPanel.swift`): Karten können sich verschieben, Klick landet auf falscher Anfrage. Soll: stabile Reihenfolge (älteste zuerst, neue unten), Approval-Buttons ~500 ms nach Erscheinen/Verschieben und während Höhen-Animation gesperrt und gedimmt, Antwort immer mit der requestId der gezeichneten Karte.

`git status` zeigt aktuell: geändert `App/Sources/UI/DetailPanel.swift`, `Packages/AgentBarCore/Sources/AgentBarCore/Adapters/ClaudeCodeAdapter.swift`, `Tests/AgentBarCoreTests/ClaudeCodeAdapterTests.swift`; neu `Store/ApprovalClickGuard.swift`, `Tests/.../ApprovalClickGuardTests.swift`. `swift build` im Core lief ohne Fehler. **Alles andere ist unverifiziert**: Tests, App-Build, ob DetailPanel die Änderungen vollständig nutzt (Scroll, Dimmen, kein Allow bei Kürzung), Screenshots, CONTRACTS.md/ROADMAP.md-Update. Prüfe den Diff (`git diff`), lass fehlende Teile vom Subagent ergänzen (alter Agent kann per SendMessage fortgesetzt werden, sonst neuer Auftrag mit obiger Spezifikation), teste mit `swift test`, `bash Tests/e2e.sh`, xcodebuild (eigener Derived-Data-Pfad, z. B. /private/tmp/ab-dd-X), 0 Swift-Warnungen, Fenster-Screenshots einer Freigabe mit langem mehrzeiligem Befehl und eines "gekürzt/kein Allow"-Falls.

## Erste Schritte
1. Sicherheitskorrektur fertigstellen und verifizieren (oben). Danach **committen (Autor-Mail lukas1.pock@gmail.com, Commit-Message endet mit `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`) und nach `origin main` pushen** – der User hat das ausdrücklich erlaubt ("kannst es dann commiten und pushen fürs erste"). Diese Erlaubnis gilt für diesen einen Push, danach für jeden weiteren Push erneut fragen.
2. Phase-1-Rest laut ROADMAP "Offene Punkte" (Entfernen-Kreuz bei arbeitenden Sessions erreichbar?, Pille/Kreis/Klick-Durchlass testen, Hook-Pfad-Problem, echter Claude-Code-Lauf nach `claude`-Login).
3. Produktentscheidung beim User einholen: Ton + optionales Auto-Aufklappen bei neuer Anfrage (Vorschlag: dezenter Ton, abschaltbar, Auto-Aufklappen optional).
4. Dann Phase 2 (Codex-Adapter, GenericCLI-Adapter, Sessions gruppieren, Verlauf, Töne) wie in der ROADMAP, jeweils mit Abnahme durch den User vor der nächsten Phase.

## Testregeln
Vor jedem App-Neustart `pkill AgentBar`. Läuft **Notchy** (`../Notchy`, separates Spotify-Notch-Projekt, bewusst unberührt), zeichnet es über die Notch-Variante: Fensteraufnahmen nutzen oder User bitten es zu beenden, niemals selbst killen. Maus nur bewegen wenn nötig und vorher ansagen. Nichts an `~/.claude` ändern außer über "Hooks einrichten…" nach Bestätigung des Users. Der User testet gern selbst mit dem CLI (`agentbar update|ask|log|end|remove`); gib ihm Befehle als einzelne Codeblöcke. Die zuletzt vom User benutzte App-Instanz lief aus dem Scratchpad-Build (`…/scratchpad/dd-coord2/Build/Products/Debug/AgentBar.app`) und existiert nach einem Neustart/Session-Wechsel evtl. nicht mehr: neu bauen.

---

## Nachtrag (2026-11-02, Ende der Session): Stand und nächster Auftrag

**Fertig und geprüft:** Phase 1, Phase 2, Phase 3, Sicherheitskorrekturen (Freigabe-Anzeige, Click-Guard, Zalgo/Cluster fail-closed, SIGPIPE, Chat-Reservierung, exakte Always-Regeln), Chat-UI mit Blasen, Abwahl, "New session" nur ohne Auswahl, Blob-App-Icon, Release-App auf `~/Desktop/AgentBar.app`. Zuletzt grün: `swift test` 139 (2 übersprungen), `Tests/e2e.sh` 78/78, 0 Swift-Warnungen. Lokal committet; zuletzt gepusht war `d5159e7`, seitdem **mehrere lokale Commits nicht gepusht** (vor jedem Push den User fragen).

**Nächster Auftrag (nur geplant, nichts gebaut):** Agents unter eigenem macOS-Benutzer `agentbar`. Plan mit User-Entscheidungen, Architektur, Paketen und MVP: `Docs/PLAN-agent-user.md`. Recherche: `Docs/research/multiuser-macos.md`, `Docs/research/multiuser-code-impact.md`. Entscheidungen: Langzeit-Token, Workspaces nur über die Bar, Agents stoppen bei App-Neustart, Admin-Setup per Script (User führt es aus). Start mit MVP Stufe 1 (Hooks über Gruppen-Socket), Abnahme durch den User vor Stufe 2.

**Offene kleine Punkte:** Kürzungsmarker "[gekürzt, im Terminal prüfen]" und "(leer)" sind im Core noch deutsch; Freigabe-Kopfzeile wiederholt den Projektnamen; Pause/Resume nur im Store, kein UI; Codex komplett UNVERIFIED (nicht installiert); echter Claude-Lauf mit Hooks und "Immer erlauben" nie geprüft; Alias `ab` kollidiert mit Apache-Benchmark (CLI-Alias `agentbar` nutzen).

---

## Nachtrag 2 (2026-11-03): Agent-User Stufe 1 + 2 gebaut und live verifiziert

**Fertig und vom User live bestätigt:** Benutzer `agentbar` (uid 502, versteckt, kein Admin), Gruppe `agentbar-ipc`, Gruppen-Socket `/Users/Shared/AgentBar` (Besitzer = Owner, 0750; Socket 0660, `token.agent` 0640), Hook-/Session-/Freigabe-Meldungen von `agentbar` kommen in der Bar an. Stufe 2: `agentbar-host` läuft als LaunchDaemon (`com.agentbar.host`, Log `/Users/agentbar/host.log`), "New session" > Run as agentbar > Workspace unter `/Users/agentbar/work`, Chat mit `claude` unter `agentbar` funktioniert (Token aus `~/.config/agentbar/claude-oauth-token`), Chip "as agentbar". Zuletzt grün: `swift test` 203 (2 übersprungen), `Tests/e2e.sh` 90/90, App-Build 0 Swift-Warnungen.

**Setup:** `Scripts/setup-agent-user.sh` / `remove-agent-user.sh` (mit `--dry-run`, `--panic`). Lektionen: Home von `agentbar` musste `agentbar:staff` gehören; Log nicht nach `/var/log` (launchd öffnet es als Agent-Benutzer); `GroupName` aus der plist entfernt; `--host-binary` mit echtem Pfad, nicht dem Symlink `.build/release`.

**Nie geprüft:** Hooks von `claude` unter `agentbar` mit "Immer erlauben"; Dead-Man bei App-Neustart; Sleep/Reconnect; Codex. Der Token wurde einmal im Chat gepostet und ersetzt: Token nie im Chat nennen.

**Nächste Aufträge:** `Docs/PLAN-personalization.md` (B1 Idle-Animationen: Atmen/Einschlafen, gedimmte Agent-Farbe, Mikro-Aktionen, Nachglühen; B2-B5 Preferences, Settings/Theme, Bots mit Startprompt/Skill, NewChatFlow mit Bot-Wahl). Offene Fragen an den User stehen dort in Abschnitt 4. Vor jedem Push den User fragen; mehrere lokale Commits sind ungepusht, Stufe 1+2 ist uncommittet.
