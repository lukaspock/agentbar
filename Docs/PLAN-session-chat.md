# PLAN: Chat im Panel – "weiter schreiben" + Accept/Deny

Stand: 2026-11-07. Quellen: code.claude.com/docs (hooks, sessions, channels, remote-control, cli-reference, agent-sdk/sessions). "UNVERIFIED" = nicht in der Doku belegt.

## 1. Befund

### 1.1 Hooks können Text einspeisen – aber nur, solange der Agent läuft
- BELEGT: `Stop`/`SubagentStop` mit `{"decision":"block","reason":"..."}` verhindert das Stoppen, Claude arbeitet weiter (Exit 2 ebenso). `hookSpecificOutput.additionalContext` auf Stop setzt die Session ebenfalls fort (Transkript-Label "Stop hook feedback", kein Fehler). (hooks#stop-decision-control)
- BELEGT: Schutz gegen Endlosschleifen: Eingabefeld `stop_hook_active` (true, wenn schon wegen Stop-Hook weitergelaufen) und Deckel von 8 aufeinanderfolgenden Fortsetzungen.
- BELEGT: `additionalContext` (max. 10 000 Zeichen, als system-reminder gewrappt, KEINE Chat-Nachricht) bei SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PostToolBatch. UserPromptSubmit kann den Prompt nicht ersetzen, nur ergänzen oder blocken. Die Doku empfiehlt faktische statt imperative Formulierung (Prompt-Injection-Abwehr).
- BELEGT (Schluss): Hooks sind ereignisgetrieben. Wartet die TUI idle auf Eingabe, feuert nichts; nach dem Stop ist das Stop-Fenster vorbei. `Notification idle_prompt` kommt ca. 60 s nach Ende der Antwort, hat aber keine Entscheidungsmacht ("Notification hooks can't block or modify"). => Ein Hook kann NICHT eine Nachricht in eine idle Terminal-Session schieben.
- Folge für Option A: Eine Nachricht, die der User tippt während der Agent noch arbeitet, lässt sich per PostToolUse-/Stop-Hook zustellen. Tippt er, wenn der Agent schon idle ist, erreicht sie die Session nicht.

### 1.2 Von außen steuern
- BELEGT: `claude --resume <id>` (auch `-p`, `--output-format stream-json`, `--input-format stream-json`) und `--fork-session` (neue Session-ID, Original bleibt). Transkripte: `~/.claude/projects/<cwd-encoded>/<id>.jsonl`. Format intern, ändert sich zwischen Versionen (sessions#where-transcripts-are-stored).
- BELEGT: "Resume the same session in two terminals without forking: messages from both interleave into one transcript." => paralleles `--resume` zur offenen TUI ohne Fork ist ein Konflikt (die TUI kennt die fremden Einträge nicht, Kontext driftet). Mit `--fork-session` gibt es das Problem nicht, ABER: Datei-Änderungen im Working Dir sind real und gemeinsam (Agent SDK/sessions), "Allow for this session"-Grants werden nicht übernommen.
- BELEGT: Agent SDK: `resume`, `forkSession`, `canUseTool`/permission-prompts und `AskUserQuestion` werden in-loop behandelt (agent-sdk/user-input); `--permission-prompt-tool mcp__x__y` für `-p`. Eigene App-gehostete Sessions sind damit voll steuerbar.
- BELEGT: Remote Control (`claude --remote-control`, `/remote-control`): steuert die laufende lokale Session von claude.ai / Claude-App aus, Verlauf synchron in Terminal und Gerät, Permission-Prompts und AskUserQuestion bleiben offen bis beantwortet. Voraussetzung claude.ai-Abo-Login (keine API-Keys, kein Bedrock/Gateway), Outbound-HTTPS über Anthropic-Server. UNVERIFIED: eine öffentliche API/Protokoll, über die eine Drittapp wie AgentBar sich anhängen könnte – nur die offiziellen Clients sind dokumentiert. Pro Interaktivprozess eine Remote-Session.
- BELEGT: Channels (Research Preview, `--channels plugin:...`): MCP-Server mit `claude/channel`-Capability pusht Events in die LAUFENDE Interaktiv-Session; zweiseitig (Reply-Tool); optional "permission relay" (Tool-Freigaben aus der Ferne). Einschränkungen: Session muss mit `--channels` gestartet werden (nicht nachträglich aktivierbar -> bestehende Terminal-Sessions fallen raus), nur Anthropic-Allowlist oder `--dangerously-load-development-channels`, claude.ai/Console-Auth, Flags können sich ändern, Antworttext erscheint nicht im Terminal. Das ist der einzige belegte Weg, Text in eine IDLE Terminal-Session einzuspeisen – aber nur für neu gestartete Sessions.
- UNVERIFIED: IDE-Kanäle (VS Code/JetBrains-Bridge) als Drittanbieter-API; offizielle Doku nennt keine.
- Inoffiziell/Hack (nicht in Doku): Tastenanschläge ins Terminal (AppleScript/Accessibility, iTerm-API, tmux `send-keys`). Funktioniert idle, bricht mit jedem Terminal; braucht Accessibility-Rechte. Nicht als Kernpfad.

### 1.3 PermissionRequest-Antworten
BELEGT (hooks#permissionrequest): `hookSpecificOutput.decision`:
- `behavior: "allow"` (+ `updatedInput` = komplettes Ersatz-Input, wird erneut gegen deny/ask-Regeln geprüft; + `updatedPermissions`), `behavior: "deny"` (+ `message` an Claude, + `interrupt: true` stoppt Claude).
- `updatedPermissions`: Einträge `{type: addRules|replaceRules|removeRules|setMode|addDirectories|removeDirectories, rules:[{toolName, ruleContent}], behavior, destination: session|localSettings|projectSettings|userSettings}`. "Always" = `addRules` mit `destination: session` (nur diese Session) oder `localSettings`/`userSettings` (dauerhaft). Eingabe liefert `permission_suggestions` – 1:1 als "Always"-Button übernehmbar.
- "Ask"/Durchreichen: Hook gibt nichts aus (oder Exit 2 ohne decision) -> normaler Terminal-Dialog bleibt. Deny/ask-Regeln gelten weiter.
Fragetypen:
| Typ | Per Hook im Panel beantwortbar? |
|---|---|
| Tool-Freigabe (Bash/Edit/…) | Ja (PermissionRequest). Bereits umgesetzt. |
| AskUserQuestion | Ja, laut Doku über PreToolUse: `permissionDecision:"allow"` + `updatedInput` = originale `questions` + `answers{frage-text: label}`. "Allow" allein reicht nicht. UNVERIFIED, ob PermissionRequest für dieses Tool feuert; PreToolUse-Weg ist der belegte. Achtung: PreToolUse-Timeout/Default 600 s, Hook darf sonst nichts ausgeben. |
| Plan-Freigabe (ExitPlanMode) | UNVERIFIED. Doku nennt ExitPlanMode neben AskUserQuestion als "braucht Interaktion", gibt aber kein Antwortschema. Vorerst im Terminal lassen, im Panel nur "wartet auf Plan-Freigabe" anzeigen. |
| MCP-Elicitation | Ja: Elicitation-Hook (accept/decline/cancel + `content`). Selten, später. |
| Notification idle_prompt / permission_prompt | Nur anzeigen (kein Rückkanal). |

### 1.4 Sicherheit / Timeouts
- BELEGT: Hook-Default 600 s (command). Bei Timeout wird die Hook-Ausgabe verworfen -> kein Entscheid, Claude zeigt den normalen Terminal-Dialog (fail-safe, entspricht dem Adapter: "Safe default… empty output"). Exit ≠ 0/2 = nicht-blockierender Fehler, Aktion läuft weiter; bei PreToolUse blockiert ein Timeout NICHT den Call. Achtung: ein kaputter PreToolUse-Hook = Tool läuft ungeschützt (nur PermissionRequest verwenden, um zu gate'n; `onFailure:"block"` existiert ab v2.1.295, wirkt nicht auf Stop).
- BELEGT: Deny/ask-Regeln und managed Settings werden auch nach Hook-Allow geprüft.
- Channels/Remote Control: wer antworten kann, kann freigeben (Allowlist der Sender). Analog: nur lokaler Socket mit Token/Peer-UID prüfen.

## 2. Optionen "weiter schreiben" bei Terminal-Sessions

| | Idee | Aufwand | Risiko | UX |
|---|---|---|---|---|
| A | Warteschlange: Nachricht liegt im Panel, Stop-Hook liefert sie als `block`+`reason` bzw. PostToolUse als `additionalContext` | S (Hook-Antwort aus Queue, Adapter hat Stop-Pfad) | Greift nur, wenn der Agent noch läuft; idle = verpufft (bleibt "wartend"). 8er-Cap, Text kommt als system-reminder statt User-Turn; Stop-Hook blockiert den "fertig"-Zustand/Benachrichtigungen | Gut für "Zwischenruf"/Korrektur während der Arbeit, schlecht als Chat |
| B | Panel startet `claude -p --resume <id> --fork-session --output-format stream-json --input-format stream-json` als eigene AgentBar-Session ("Fortsetzen als Fork") | M-L (Prozess-Host, stream-json-Parser, Permission via `--permission-prompt-tool`/SDK) | Fork-Dateiänderungen kollidieren mit der Terminal-Session am selben Working Dir; Grants fehlen; kein Live-Sync zurück ins Terminal; ohne Fork = interleaved Transkript (nicht tun) | Echter Chat inkl. Freigaben; klares Modell "ab hier lebt die Fortsetzung im Panel" |
| C | Nur Chat-Sessions, die AgentBar selbst hostet (SDK/`-p`); Terminal-Sessions read-only + Freigaben | M | gering | Konsistent, aber der User will Terminal-Sessions steuern |
| D1 | Terminal-Session mit `--channels` (eigener AgentBar-Channel, Dev-Flag) oder `--remote-control` starten | L | Research Preview, Flags instabil, Allowlist/Dev-Flag, claude.ai-Auth, Session muss neu gestartet werden; RC-Anbindung für Drittapps UNVERIFIED | Einziger Weg mit echter Idle-Zustellung in dieselbe Session; nur für neue Sessions |
| D2 | Keystroke-Injection ins Terminal (iTerm-API/tmux/Accessibility) | M | Fragil, Rechte, falsche Eingabe bei laufendem Dialog | Funktioniert idle, aber hacky |

## 3. Accept/Deny im Panel – Brainstorming
- Inline-Freigabe-Blase im Chat-Verlauf an der Stelle des Tool-Aufrufs (statt separater RequestCard); nach Entscheid wird sie zur Notiz "Erlaubt · 12:03".
- Buttons: Erlauben / Immer (aus `permission_suggestions`, Ziel-Scope sichtbar: Session vs. Projekt vs. User; Default Session) / Ablehnen / Ablehnen mit Begründung (Textfeld -> `message`) / Ablehnen + Stoppen (`interrupt`).
- Fragen mit Optionen (AskUserQuestion): Optionen als Chips, Multi-Select, "Andere…" Textfeld; Antwort via PreToolUse-`updatedInput.answers`. Fallback "Im Terminal beantworten" (Hook ohne Ausgabe).
- Plan-Freigabe: erst nur Anzeige + "Im Terminal öffnen" bis Schema belegt ist.
- Kürzel: ⌘↩ erlauben, ⌘⌫ ablehnen, ⌥⌘↩ immer; nur bei fokussierter, sichtbarer Anfrage; mehrere Anfragen: Reihenfolge/Nummern.
- Klick-Schutz: kurze Armierungsverzögerung (~400 ms) nach Erscheinen/Wechsel der Karte, Anfrage nie unter einem gerade verschobenen Layout; bei destruktiven Mustern (rm, git push --force, sudo, Schreiben außerhalb des Projekts) roten Rahmen + Doppelbestätigung/Halten-zum-Erlauben; "Always" nie als Default-Fokus; Befehl vollständig und unverkürzt anzeigen (Prompt-Injection-Schutz, `updatedInput` anzeigen, wenn verändert).
- Sammel-Freigaben: gleiche Tool+Muster-Anfragen bündeln ("3× Edit in src/ – alle erlauben"); nur für nicht-destruktive Klassen.
- Timeout: Karte zeigt Restzeit (600 s), danach "Im Terminal beantworten" (Hook fällt auf Terminal-Dialog zurück); Antwort kommt der Session zu spät -> Hinweis, nicht still schlucken.
- Terminal-Parallelität: antwortet der User im Terminal, verschwindet die Karte (PostToolUse/nächstes Event als Signal).

## 4. Empfehlung (Phasen)
1. MVP (S): Freigabe-Blase inline + Klick-Schutz, Deny mit Begründung, "Immer" mit sichtbarem Scope (Session-Default), Timeout-Anzeige. Nutzt vorhandenen PermissionRequest-Pfad.
2. Phase 2 (S-M): Option A als "Nachricht vormerken" – ehrlich beschriftet: "wird zugestellt, sobald Claude den nächsten Schritt macht"; bei idle Hinweis "Session wartet im Terminal" + Button "Kopieren/Im Terminal öffnen". AskUserQuestion-Buttons über PreToolUse (zuvor Spike gegen reale Claude-Version, da Schema nur aus Doku).
3. Phase 3 (M-L): Option B als explizite Aktion "Im Panel fortsetzen (Fork)" mit Hinweis auf geteiltes Working Dir; baut auf Option C (App-gehostete Chat-Sessions, SDK/stream-json) auf, die ohnehin die volle Chat-UX liefert.
4. Beobachten: Channels/Remote Control. Sobald stabil und für Drittapps dokumentiert, ist ein AgentBar-Channel der saubere Weg für Idle-Zustellung; bis dahin nicht investieren. Keystroke-Injection (D2) nur als optionales Experiment.

Spikes vor Umsetzung: (1) AskUserQuestion über PreToolUse real testen; (2) feuert PermissionRequest für ExitPlanMode/AskUserQuestion?; (3) Verhalten von Stop-`block` mit AgentBars aktuellen Hooks (Konflikt mit `stop_hook_active`).
