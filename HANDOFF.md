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
