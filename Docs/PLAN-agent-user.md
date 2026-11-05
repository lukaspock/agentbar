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
- Host und Agent haben dieselbe UID: Host-Binary root-eigen und nicht schreibbar halten. Gehaertet (Phase 7 in CONTRACTS.md): `op: host` prueft per `LOCAL_PEERPID` + `proc_pidpath`, dass der Peer `/usr/local/libexec/agentbar/agentbar-host` ist (root-eigen); ein lebender Host wird nicht verdraengt, ein toter ersetzt. **Restrisiko (bleibt):** ein Prozess des Agent-Benutzers kann den echten Host beenden und sich im Fenster danach anmelden, das echte Binary mit injizierter Bibliothek starten oder debuggen, und `token.agent` lesen (ein eigenes Host-Token hilft nicht, gleiche UID). Er erhaelt dann App-zu-Host-Zeilen und kann Chat-Ausgabe faelschen (Freigaben rendert weiterhin die App). **Kuenftige Option: separater Host-Benutzer** (eigene UID fuer `agentbar-host`, Socket nur fuer diese UID, Rollentabelle um `.host` erweitern).
- Isolation ist nur Benutzertrennung, kein Sandbox-Ersatz: Der Agent-Benutzer sieht Prozessliste, `/tmp`, Netzwerk inkl. localhost-Dienste. Starke Isolation bräuchte eine VM (Tart/Virtualization.framework); Härtung per `pf`/`sandbox-exec` ist optional und `sandbox-exec` deprecated.
- Duplex-Op im Thread-pro-Verbindung-Transport; Version-Skew App/Host; gemeinsame Quoten.
- Computer-Use/GUI-Agents: braucht eigene angemeldete Sitzung und eigene TCC-Rechte, besser VM. Eigener späterer Schritt.

## Noch offen
- Exakter Pfad für das Notaus-Script und wer es auslöst.
- Ob Hooks im Agent-Home nur für Terminal-Sessions oder auch für den Host-`claude` aktiv sein sollen (Doppel-Freigabe).
- Name der Gruppe und des Benutzers final (`agentbar`, `agentbar-ipc` als Vorschlag).

## Admin-Installer (O2, 2026-11-05)
Ersetzt den manuellen `sudo`-Ablauf oben fuer den Onboarding-Weg; das Script bleibt auch von Hand nutzbar (`--dry-run`).

**Ablauf:** `AdminInstaller` (App/Sources/Setup, `SetupAdminBlock`) prueft die gebuendelte Payload `Resources/AgentSetup/` gegen `manifest.json` (SHA-256, von `App/Scripts/bundle-cli.sh` nach dem Signieren erzeugt), baut EIN Root-Programm und fuehrt es per `NSAppleScript` (`do shell script ... with administrator privileges`, Hintergrund-Thread) aus. Das Programm legt ein root-eigenes Staging (`/Library/Application Support/AgentBar/staging.XXXXXX`, 0700) an, kopiert die vier Payload-Dateien per `ditto`, setzt root:wheel, lehnt Symlinks/Fremddateien ab (Exit 71), prueft die Hashes **auf der Staging-Kopie** (Exit 72) und startet erst dann `setup-agent-user.sh` von dort. Quoting/Manifest/Statuszeilen sind reine Funktionen (`AdminInstallerSupport.swift` im Core, getestet).

**Script (nicht interaktiv):** `--owner NAME` (Pflicht, Allow-List `[A-Za-z0-9._-]`), `--steps`, `--host-binary`, `--cli-binary`, `--token-file`, `--run-id`, `--migrate`, `--dry-run`. Steps: `agentUser` (Role-Account per `dscl`: UID = hoechste belegte UID in 200..399 + 1, Shell `/usr/bin/false`, Passwort `*`, `IsHidden 1`, Home per `install -d` 700 agentbar:staff, Gruppe `agentbar-ipc`, `/Users/Shared/AgentBar` 0750 Besitzer:`agentbar-ipc` - die Gruppe sitzt am Verzeichnis, daher kein Re-Login), `cli` (`/usr/local/bin/agentbar`), `hostBinary` (`/usr/local/libexec/agentbar/agentbar-host`, `xattr -c`, `cmp -s`; danach LaunchDaemon und Post-Check `launchctl print system/com.agentbar.host`: `state = running`, kein `last exit code = 78`, bis 20 s), `claudeToken`.

**Bestehender Account:** Ist `agentbar` schon da und kein Role-Account (z. B. alte uid 502 mit Login-Shell), wird nichts veraendert: Exit 20 mit klarer Meldung (`AdminInstallerError.legacyAccount`). Erst mit `--migrate` (App: `AdminInstaller(migrate: true)` nach Rueckfrage) wird er in place umgestellt: Daemon und Prozesse stoppen, neue UID im Role-Bereich, Shell/Passwort/AuthenticationAuthority bereinigt, Home per `chown -R -P` angepasst. Nichts wird geloescht.

**Token:** Die App legt den Token als kurzlebige 0600-Datei ab und uebergibt nur den Pfad (`tokenFile`-Closure). Das Script prueft regulaere Datei, kein Symlink, 0600, Besitzer = Owner/root, Zeichensatz/Laenge; schreibt nach `/Users/agentbar/.config/agentbar/claude-oauth-token` (0600, agentbar:staff) und loescht die Quelle (auch bei Fehlern; die App loescht zusaetzlich).

**Fortschritt:** JSON-Zeilen in `/Library/Application Support/AgentBar/setup-status.jsonl` (root, 0644, fester Pfad, pro Lauf neu; Felder `seq, run, step, state, msg`). Die App liest alle 300 ms und filtert nach `run`-ID.

**Aufraeumen:** `remove-agent-user.sh` kennt den Role-Account (`dscl -delete`, Home nur ohne `--keep-home`) und entfernt das Status-/Staging-Verzeichnis.

**Restrisiken / nicht verifiziert:** Das Manifest liegt im selben (App-)Bundle wie die Binaries; es schuetzt vor Austausch zwischen Pruefung und Ausfuehrung (TOCTOU), nicht vor einem vor dem Start manipulierten Bundle (dagegen hilft nur eine Signatur-/Notarisierungspruefung). Die Token-Quelle wird mit `stat` geprueft und dann gelesen (kleines Zeitfenster, Aufrufer ist ohnehin Admin). Echte Ausfuehrung (Prompt, dscl, Daemon, Migration) wurde nicht getestet.
