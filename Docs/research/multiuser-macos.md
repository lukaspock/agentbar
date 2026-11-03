# Agents unter eigenem macOS-Benutzer (Recherche, Stand 2026-11)

Hinweis: Reine Recherche, nichts am System getestet. Quellen: Claude-Code-Doku (offiziell), Apple-Dev-Forum/Apple-Doku, Community-Berichte. Alles mit "[unverifiziert]" ist aus Hintergrundwissen und vor Umsetzung auf dem Zielrechner zu testen.

## 1. Benutzer anlegen
- `sysadminctl -addUser agentbar -fullName "AgentBar" -password - -home /Users/agentbar` (ohne `-admin` = Standardbenutzer). `-password -` fragt interaktiv. Braucht Admin/sudo. `sysadminctl` legt Home samt Kopie von /System/Library/User Template an; `dscl` (`. -create /Users/...`) muss alles (UID, Shell, Home, createhomedir) manuell; ist fehleranfaelliger. Empfehlung: `sysadminctl`. Flags vorher mit `sysadminctl -help` pruefen (Quelle zeigt `-hidden` nur in Wrapper-Skripten: https://docs.applivery.com/en/device-management/apple/macos/policies/automate-admin-account/ ).
- Versteckt: `dscl . -create /Users/agentbar IsHidden 1` (Login-Fenster/Benutzerliste). Zusaetzlich `sudo defaults write /Library/Preferences/com.apple.loginwindow Hide500Users -bool YES` nur fuer UIDs <500 [unverifiziert]. Besser: UID >= 501 lassen, nur IsHidden=1; Home-Ordner ggf. nach /var/agentbar legen (versteckt auch den Ordner in /Users).
- Home-Rechte: macOS-Standard 0750 bzw. 700 fuer neue Homes (Sonoma+: 700 ist ueblich) [unverifiziert]; explizit `chmod 700 /Users/agentbar` setzen und pruefen, dass dein Benutzer nicht per ACL/Gruppe lesen kann. Dein eigenes Home ebenfalls 700 (Standard), sonst kann der Agent dein Home lesen.
- Secure Token/FileVault: Neue Benutzer per `sysadminctl` bekommen nur dann ein Secure Token, wenn ein Admin mit Token die Anlage autorisiert (`-adminUser/-adminPassword`). Ohne Token: kann sich nicht am FileVault-Preboot entsperren (egal, Agent-Benutzer soll das nicht) und Kryptografie-Features (Volume-Owner) fehlen. Fuer einen Service-Benutzer ist KEIN Secure Token sogar vorteilhaft (kann kein FileVault entsperren). Pruefen: `sysadminctl -secureTokenStatus agentbar` (Quelle: https://support.addigy.com/hc/en-us/articles/4403542345619 ). Nicht in sudoers / admin-Gruppe aufnehmen.
- Aufraeumen: `sudo sysadminctl -deleteUser agentbar` (loescht Home; `-keepHome` zum Behalten). Vorher LaunchDaemons entladen (`launchctl bootout`), Prozesse beenden. Reste: /Users/Shared-Ordner, Gruppe (`dscl . -delete /Groups/agentbar`), pf-/launchd-Dateien. [Mit sysadminctl -deleteUser teils Restinhalte in /private/var/db; unverifiziert]

## 2. Prozesse als anderer Benutzer ohne GUI-Sitzung
Optionen:
a) LaunchDaemon (/Library/LaunchDaemons) mit `UserName`/`GroupName`: laeuft ohne Login, ABER nicht im Login-/Aqua-Kontext des Users. Die Login-Keychain des Users ist nicht entsperrt/nicht Teil der Suchliste; `UserName` allein ist laut Community nicht "als waere der User eingeloggt" (https://developer.apple.com/forums/thread/656000 , https://developer.apple.com/forums/thread/685967 ). `SessionCreate=true` erzeugt eine neue Audit-Session; Ergebnisse gemischt (teils Fehler). Apple-DTS: Daemons sollen Keychain-Zugriff vorab erhalten und nicht interaktiv sein.
b) LaunchAgent in der Fast-User-Switching-Sitzung des agentbar-Users: braucht echte Anmeldung (einmal im Login-Fenster, oder Autologin nicht moeglich fuer zweiten User). Dann ist die Login-Keychain entsperrt (Passwort = Login-Passwort). Aber: Sitzung muss dauerhaft laufen (nach Neustart manuell einloggen); Bildschirm/Sitzung bleibt im Hintergrund. Fuer Headless nicht praktikabel.
c) Hilfsweg: `sudo -u agentbar -i` / `launchctl asuser <uid>` (nur wenn Sitzung existiert) / `su`. Ohne Sitzung kein Bootstrap-Kontext des Users.

claude (Claude Code):
- Credentials auf macOS: Keychain ("Claude Code-credentials"); wenn Keychain schreibt-ablehnt (z.B. gesperrt in SSH), faellt `claude` auf `~/.claude/.credentials.json` (0600) zurueck (offiziell: https://code.claude.com/docs/en/authentication ). Das ist genau der Daemon-Fall: kein Keychain noetig, Datei im Home des agentbar-Users funktioniert. Geh davon aus, dass ohne GUI-Sitzung die Login-Keychain nicht entsperrt ist.
- Umweg ohne Keychain/Browser: `CLAUDE_CODE_OAUTH_TOKEN` (aus `claude setup-token`, 1 Jahr gueltig, braucht Pro/Max/Team; kann nur Modellanfragen, kein Remote Control/claude.ai-Connectors) oder `ANTHROPIC_API_KEY` (Console, Abrechnung per Token; im `-p`-Modus immer genutzt, interaktiv einmalige Bestaetigung). Vorrang: API_KEY/AUTH_TOKEN > apiKeyHelper > OAUTH_TOKEN > /login. Nicht beides gleichzeitig setzen (Auth-Konflikt-Warnung, GitHub-Issues #37512, #80091 sind Community-Berichte: https://github.com/anthropics/claude-code/issues/37512 ). Berichtet wird auch, dass der Env-Token in bestimmten Faellen den Keychain-Eintrag loescht bzw. in langlaufenden launchd-Prozessen der Keychain-Login Vorrang hat (widerspruechlich, [unverifiziert]).
- `apiKeyHelper` (Settings) als Alternative: Skript liefert Key, z.B. aus Datei mit 0600 im agentbar-Home.
- Empfehlung: Einmalige Anmeldung interaktiv als agentbar (z.B. `sudo -u agentbar -H claude auth login` oder `login` in Terminal-Tab, Browser-Flow per URL/Code kopieren). Bei fehlender Keychain landet es in .credentials.json. Fuer den Daemon `HOME`, `PATH` (inkl. ~/.local/bin), `USER`, `LOGNAME` im plist-EnvironmentVariables explizit setzen (launchd setzt kein Login-Env). Alternativ Token per setup-token in einer 0600-Env-Datei.
- Node/Binary: `~/.local/bin/claude` (nativer Installer) im Home des agentbar-Users installieren, nicht im eigenen. Der Binary-Pfad eigener User ist fuer agentbar nicht lesbar (Home 700).
- Unsicherheit: Ob aktuelle claude-Versionen ohne Keychain-Zugriff im Daemon ohne Fehlermeldung/Hang auf die Datei zurueckfallen, nicht getestet. Test: `sudo -u agentbar -H env -i HOME=/Users/agentbar claude -p "hi"` aus einer Shell ohne GUI-Session des Users.

Empfehlung: LaunchDaemon (UserName=agentbar, GroupName=agentbar-ipc, KeepAlive) startet einen kleinen Supervisor ("agentbar-host"), der claude-Prozesse (Agent SDK / `claude -p --output-format stream-json`) spawnt. Kein Keychain, Auth per .credentials.json oder OAUTH_TOKEN/API-Key.

## 3. IPC zwischen den Benutzern
Empfehlung: Unix-Domain-Socket.
- Ort: nicht /tmp. Entweder `/Users/Shared/agentbar/` oder `/var/run/agentbar/` bzw. `/private/var/agentbar/` (von root per LaunchDaemon vor-angelegt, bleibt Reboot-fest nur ausserhalb /var/run, das tmpfs-aehnlich geleert wird [unverifiziert]). Ordner: Owner agentbar, Gruppe `agentbar-ipc`, Mode 2770 (setgid). Dein Benutzer in Gruppe `agentbar-ipc` (`dseditgroup -o edit -a lukaspock -t user agentbar-ipc`; Gruppenaenderung wirkt erst nach neuem Login/Prozess). Socket-Datei Mode 0660 (nach bind per chmod/fchmod; umask 007 vor bind).
- Alternative ohne Gruppen: ACLs (`chmod +a "user:lukaspock allow read,write,..." ...`), funktioniert, ist aber fragiler (Vererbung).
- Authentifizierung: Server prueft Peer mit `getpeereid(fd)` oder `LOCAL_PEERCRED` (xucred, UID) bzw. `LOCAL_PEERPID`; `LOCAL_PEERTOKEN` liefert audit_token_t (robuster gegen PID-Reuse; fuer Code-Signatur-Check via SecCode). Hier reicht UID == dein UID. Zusaetzlich Geheimnis/Nonce-Handshake optional. (Keine offizielle Doku per Suche gefunden; Aussagen aus Hintergrundwissen [unverifiziert].)
- Wer hostet den Socket? Der Daemon (agentbar) lauscht; die AgentBar-App verbindet als Client. Dadurch ist App-Neustart unkritisch und Agenten laufen weiter.
- TCC/Sandbox: App ist nicht sandboxed (ad-hoc signiert, LSUIElement). Zugriff auf /Users/Shared und /var braucht kein TCC. TCC greift bei Desktop/Documents/Downloads und fremden Homes; das Projekt liegt in ~/Documents -> App kann dort lesen (nicht Daemon). Wichtig: Workspaces fuer den Agenten NICHT in ~/Documents des Users legen, sondern in /Users/agentbar/work oder /Users/Shared/... mit Gruppen-Rechten. "Full Disk Access" nicht noetig fuer Socket. Unsicher: ob ein Socket in ~/Desktop von einer nicht-TCC-berechtigten Binary nicht verbindbar ist (irrelevant bei /Users/Shared).
- XPC/Mach: Mach-Services sind pro Bootstrap-Namespace. Ein LaunchDaemon-Service (System-Domain, `XPC_CONNECTION_MACH_SERVICE_PRIVILEGED`) ist von User-Sessions aus erreichbar, wenn die Mach-Namen registriert sind (https://developer.apple.com/documentation/xpc/xpc_connection_mach_service_privileged.md , launchd.plist/man). Ein LaunchAgent im agentbar-User-Kontext waere von deiner Sitzung NICHT erreichbar. Mit UserName im Daemon laeuft der Dienst in der System-Domain; XPC ginge also, aber: Mach-Service-Sicherheit hauptsaechlich Code-Signing/Entitlements-basiert, ad-hoc signiert unbequem. Bewertung: UDS einfacher, ohne Signaturzwang -> UDS. XPC spaeter, falls Developer-ID-Signatur.

## 4. Sicherheitsmodell / Grenzen
Agent-User kann trotz Standardbenutzer:
- Prozessliste sehen (`ps`, auch fremde Prozesse; Argumente/Env anderer Nutzer sind fuer Nicht-Root nicht lesbar, Kommandozeilen schon [unverifiziert]). Eigene Secrets nie in argv.
- /tmp, /private/var/tmp, /Users/Shared, /Applications, /usr/local lesen; Welt-lesbare Dateien (z.B. 755-Homes anderer Benutzer, falls nicht 700!). Dein Home pruefen: `ls -le@ /Users`.
- Netzwerk uneingeschraenkt, inkl. localhost-Dienste deiner Sitzung (Dev-Server, Datenbanken, AgentBar-eigene Ports). Bildschirm: kein Zugriff auf deine Sitzung (WindowServer pro Session, Screen Recording per TCC nur fuer die eigene Sitzung).
- Keychain: dein Login-Keychain nicht lesbar; /Library/Keychains/System.keychain begrenzt.
- sudo nur, wenn in admin/sudoers - nicht aufnehmen.
Haertung:
- `sandbox-exec -f profile.sb` (deprecated, aber funktional; Profile in SBPL) fuer zusaetzliche Einschraenkung auf Workspace-Pfade und Netz-Regeln. Alternativ in-process `sandbox_init` (privat/deprecated). Wartungsrisiko [unverifiziert fuer macOS 26].
- pf-Firewall: Regeln pro Benutzer (`pass out ... user agentbar`, `block drop out quick user agentbar to !<allowlist>`), Anchor in /etc/pf.anchors, per LaunchDaemon `pfctl -f`. Erlaubt Allowlist (api.anthropic.com, github.com). pf braucht Root-Setup und kann durch OS-Updates ueberschrieben werden.
- Home 700, Workspaces per ACL/Gruppe nur fuer dich + agentbar; keine admin-Gruppe; kein Secure Token; Quota nicht nativ.
- Grenzen: Gleicher Kernel; lokale Privilege-Escalation (macOS-CVEs) und Dateien mit lockeren Rechten bleiben Risiko. Der Agent kann Code beliebig ausfuehren (Freigaben der App sind nur eine Policy-Ebene, kein Sandbox-Ersatz). Kein Schutz gegen exfiltrieren ueber Netz ohne pf. Fuer starke Isolation: VM.

## 5. Computer-Use / GUI-Agents (spaeter)
- Fast User Switching: zweite Aqua-Sitzung, braucht echte Anmeldung (Passwort). Screen Recording/Accessibility TCC pro Benutzer separat zu erteilen, nur in der GUI der Sitzung moeglich. Laeuft im Hintergrund weiter, wenn du wechselst.
- Screen Sharing/VNC auf localhost zum agentbar-User: moeglich (Systemeinstellungen -> Teilen, per Benutzer); dann sieht/steuert AgentBar eine entfernte Sitzung; Latenz und Komplexitaet, Einwilligung. [unverifiziert fuer Details macOS 26]
- Virtualisierung: Apple Virtualization.framework / Tart (macOS-Gast-VMs, max. 2 gleichzeitig auf Apple Silicon laut Lizenz). Staerkste Isolation, eigener Snapshot, aber hoher RAM/Disk-Bedarf (~20+ GB) und separate Logins. Fuer Computer-Use die sauberste Loesung, spaeterer Schritt.

## Empfehlung / Plan
1. Standardbenutzer `agentbar` (sysadminctl, hidden, Home 700, kein Secure Token, keine admin-Gruppe), Gruppe `agentbar-ipc`.
2. LaunchDaemon mit UserName/GroupName + explizitem Env (HOME, PATH) startet den Host; claude nativ im agentbar-Home; Auth per .credentials.json oder CLAUDE_CODE_OAUTH_TOKEN/ANTHROPIC_API_KEY (0600).
3. UDS in 2770-Ordner (setgid), Socket 0660, Peer-Check per getpeereid/LOCAL_PEERCRED.
4. Workspaces unter /Users/agentbar/work (oder Shared mit Gruppe), nicht in ~/Documents.
5. Optional: sandbox-exec + pf-Allowlist. GUI-Agents spaeter via VM.

## Offene Unsicherheiten
- Verhalten von claude ohne entsperrte Keychain im Daemon (Fallback-Datei laut Doku fuer "Keychain rejects write"; bei Lesefehlern ungetestet).
- `sysadminctl -hidden`-Flag und Secure-Token-Details auf macOS 26.
- sandbox-exec Zukunftssicherheit; Ort /var/run Persistenz.

## Quellen
- https://code.claude.com/docs/en/authentication
- https://github.com/anthropics/claude-code/issues/37512
- https://github.com/anthropics/claude-code/issues/80091
- https://developer.apple.com/forums/thread/656000
- https://developer.apple.com/forums/thread/685967
- https://developer.apple.com/documentation/xpc/xpc_connection_mach_service_privileged.md
- https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html
- https://support.addigy.com/hc/en-us/articles/4403542345619
- https://docs.applivery.com/en/device-management/apple/macos/policies/automate-admin-account/
