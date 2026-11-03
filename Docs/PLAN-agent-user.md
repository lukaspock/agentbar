# Plan: Agents unter eigenem macOS-Benutzer (`agentbar`)

Stand: 2026-11-02. Nur Planung, nichts davon ist gebaut. Grundlage: `Docs/research/multiuser-macos.md` (macOS-Mechanik) und `Docs/research/multiuser-code-impact.md` (Code-Analyse mit Datei/Funktion). Dort stehen Details und Quellen; vieles zu `claude` unter Fremdbenutzer ist UNVERIFIED.

## Ziel
Agents (zuerst `claude`, später Codex) laufen unter einem nicht-admin Benutzer `agentbar` in eigenen Workspaces. Der Besitzer (du) steuert sie nur über die AgentBar-App in seiner Sitzung: Freigaben, Chat, Stop, neue Session. Der Agent-Benutzer kommt nicht an die Daten des Besitzers.

## Entscheidungen des Users (2026-11-02)
- **Login:** Langzeit-Token (`claude setup-token`, 1 Jahr gültig, Pro/Max/Team nötig, gilt nur für Modellanfragen). Der Host setzt ihn als `CLAUDE_CODE_OAUTH_TOKEN`. Nicht zusammen mit `ANTHROPIC_API_KEY` setzen. Token liegt nur für den Agent-Benutzer lesbar (0600, Home 700), nie in der App-Config des Besitzers.
- **Workspaces:** Nur über die Bar. Ordner unter `/Users/agentbar/work`, nur der Agent-Benutzer liest sie. Nicht unter `~/Documents` (TCC).
- **App-Neustart:** Agents werden gestoppt (Dead-Man im Host nach kurzer Frist, z. B. 20 s ohne Verbindung). Kein Re-Attach im MVP.
- **Admin-Setup:** Per Script, das der User selbst prüft und mit sudo startet. Ich führe nichts davon aus.

## Architektur
```
Besitzer-Sitzung                         LaunchDaemon (UserName=agentbar)
AgentBar.app                             agentbar-host
 ├ SessionStore, UI, ChatSession          ├ spawnt claude (PosixChatProcess als "dummes Rohr")
 ├ renderApproval, safeAlwaysRule         ├ Pfad-Containment, Env-Bau, Prozessgruppen-Kill
 ├ chatOwned, Log-Sanitizing              ├ Workspaces anlegen/listen, Hooks schreiben
 └ RemoteChatProcess ───── Unix-Socket ───┘ Dead-Man bei Verbindungsverlust
        /Users/Shared/AgentBar (Gruppe agentbar-ipc, Dir 2770/0750, Socket 0660)
```
Kernprinzip: Alle Sicherheitslogik bleibt **Besitzer-seitig** (Freigabe-Rendering, Always-Regeln, Reservierung, Sanitizing). Der Host ist ein dummes Rohr für spawn/stdin/stdout/stderr/exit. Die vorhandene Naht `ChatProcess`/`ChatProcessFactory` wird genutzt: `RemoteChatProcess` ersetzt `PosixChatProcess` für das Ziel "agentbar".

### Transport-Sicherheit
- Socket von `~/Library/Application Support/AgentBar` nach `/Users/Shared/AgentBar` (Gruppe `agentbar-ipc`, Besitzer als Mitglied, Dir 0750/2770, Socket 0660). Der Besitzer-Socket bleibt zusätzlich bestehen (lokale Nutzung unverändert).
- `getpeereid`-Check: statt `== geteuid()` eine Rollentabelle (`.owner`, `.agent`) mit zwei erlaubten UIDs. Fallback `LOCAL_PEERCRED`.
- Token pro Rolle: `token` (Besitzer, 0600), `token.agent` (0640, Gruppe). Rotation per temp+rename mit 60 s Gnadenfrist.
- Session-Herkunft: Die Rolle `.agent` darf keine Besitzer- oder `chatOwned`-IDs anfassen; Quoten pro Rolle.
- XPC/Mach bewusst nicht: Bootstrap-Namespaces sind pro Benutzer getrennt und ad-hoc-Signatur macht XPC unbequem.

### Host-Protokoll
Ein neues langlebiges Duplex-Op `host` (nur Rolle `.agent`): Handshake, dann Frames `spawn`, `stdin`, `terminate`, `kill`, `workspaces`, `mkworkspace`, `hookplan`, `hookapply`, `ping`; Events `spawned`, `spawnFailed`, `stdout`, `stderr`, `exit`. IDs vergibt nur die App. Zeilenlimit nur für diesen Kanal 1 MiB. Spawn-Fehler als stderr + Exit 127.

### Hooks
Der Host schreibt `~/.claude/settings.json` **des Agent-Benutzers** über `HookSetup(settingsURL:)`. Plan/Apply als Ops, die Bestätigung mit Diff-Vorschau bleibt in der App (Plan wird Codable). CLI liegt root-eigen unter `/usr/local/bin/agentbar` (0755), nicht im App-Bundle. Achtung: Doppel-Freigabe, wenn Hooks im Agent-Home auch den Chat-`claude` erreichen (Hook-Session-ID gegen `chatOwned` abgleichen).

### UI
- `NewChatFlow` wird Dialog: "Ausführen als: <ich> / agentbar", Workspace-Popup (vom Host) plus "Neuer Workspace"; `NSOpenPanel` nur für lokal.
- Anzeige "läuft als agentbar" als Chip/Header, **nur aus vertrauenswürdiger Herkunft** (App-Wissen), nie aus Agent-Text.
- Menü "Agent-Benutzer…" (Status Host, Einrichten, Hooks).
- Optional additives `AgentSession.runsAs` (Contract ist FROZEN, nur Coordinator).

## Admin-Setup (Script, vom User ausgeführt)
`Scripts/setup-agent-user.sh` (idempotent, mit `--dry-run`):
1. `sysadminctl -addUser agentbar` ohne `-admin`; verstecken mit `dscl . -create /Users/agentbar IsHidden 1`; Home 700; auch dein Home 700 prüfen.
2. Gruppe `agentbar-ipc` anlegen, Besitzer eintragen (Re-Login nötig).
3. `/Users/Shared/AgentBar` mit Modus/Gruppe, `/Users/agentbar/work`, CLI nach `/usr/local/bin`, Host-Binary root-eigen.
4. LaunchDaemon-plist (`UserName`, `GroupName`, `HOME`, `PATH` inkl. `~/.local/bin` explizit), `launchctl bootstrap`.
5. Token-Hinterlegung: `sudo -u agentbar` schreibt den Token in eine 0600-Datei. Der Token wird nie auf der Kommandozeile oder im Chat übergeben.
Gegenstück `Scripts/remove-agent-user.sh` (Daemon per `launchctl bootout`, dann `sysadminctl -deleteUser`).

## Arbeitspakete (disjunkte Dateien) und Reihenfolge
| P | Inhalt | Besitzt |
|---|--------|---------|
| P0 | Spec/Contracts, Rollenmodell, Wire-Ops (Coordinator) | CONTRACTS.md, Contract/ |
| P1 | Transport-Sicherheit: `TransportSecurity`, Rollen, Token pro Rolle, Gruppen-Socket | TransportServer/SocketIO/Limits |
| P2 | CLI: Fallback-Dir, `token.agent` | Sources/agentbar/** (nach P1) |
| P3 | Host-Kern: Target `agentbar-host`, Containment, Env, Prozessgruppen, Dead-Man | Host/*, ChatSessionProcess |
| P4 | Host-Kanal: `host`-Op, `RemoteChatProcess` | Transport (nach P1) |
| P5 | Hooks über Host (Plan/Apply, CLI-Pfad) | Adapters/HookSetup |
| P6 | UI: Dialog, Chip, Menü (zuerst gegen Fake-Host) | App/** |
| P7 | Setup-/Remove-Scripts, LaunchDaemon-plist | Scripts/ |
| P8 | Integration, manuelle Abnahme | alle, ein Agent |

Reihenfolge: P0 → (P1 ‖ P3 ‖ P6 ‖ P7) → (P2, P4, P5) → P6-Verdrahtung → P8.

## MVP (zuerst)
**Stufe 1 (P0+P1+P2+P5-Teil):** Hooks von `claude` unter `agentbar` melden über den Gruppen-Socket an die Bar des Besitzers. Freigaben in der Bar funktionieren. Agents startest du in diesem Schritt noch im Terminal als `agentbar`.
**Stufe 2 (P3+P4+P6):** Chat aus der Bar startet `claude` über den Host beim Agent-Benutzer.
**Stufe 3:** Härtung, Codex, optional Re-Attach, GUI-Agents (separat: VM, siehe unten).

## Tests
- Automatisch: Peer-Check injizierbar (`ownerUid = geteuid()+1` usw.), Rollenmatrix, Modi/Gruppe, Token-Rotation, Host über `socketpair` mit Fake-/`cat`-/Shell-Prozess, Pfad-Containment, Env-Leak-Test (keine Besitzer-Variablen im Child).
- Nur manuell: echter Benutzer und Rechte, LaunchDaemon, `claude`-Login als `agentbar` (zuerst `sudo -u agentbar -H claude -p "hi"` mit dem Token), Gruppen-Re-Login, Prozessgruppen-Kill, Sleep/Reconnect.

## Risiken
- `claude` im Daemon ohne entsperrte Keychain: UNVERIFIED. Der Token-Weg umgeht die Keychain, der Fallback ist `~/.claude/.credentials.json`.
- Der Besitzer kann Prozesse fremder UID nicht killen: Stop läuft über den Host, dazu Dead-Man und ein Admin-Notaus-Script.
- Host und Agent haben dieselbe UID: Host-Binary root-eigen und nicht schreibbar halten.
- Isolation ist nur Benutzertrennung, kein Sandbox-Ersatz: Der Agent-Benutzer sieht Prozessliste, `/tmp`, Netzwerk inkl. localhost-Dienste. Starke Isolation bräuchte eine VM (Tart/Virtualization.framework); Härtung per `pf`/`sandbox-exec` ist optional und `sandbox-exec` deprecated.
- Duplex-Op im Thread-pro-Verbindung-Transport; Version-Skew App/Host; gemeinsame Quoten.
- Computer-Use/GUI-Agents: braucht eigene angemeldete Sitzung und eigene TCC-Rechte, besser VM. Eigener späterer Schritt.

## Noch offen
- Exakter Pfad für das Notaus-Script und wer es auslöst.
- Ob Hooks im Agent-Home nur für Terminal-Sessions oder auch für den Host-`claude` aktiv sein sollen (Doppel-Freigabe).
- Name der Gruppe und des Benutzers final (`agentbar`, `agentbar-ipc` als Vorschlag).
