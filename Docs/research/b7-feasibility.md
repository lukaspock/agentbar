# B7 Machbarkeitsprüfung: First-Run-Setup aus der App

Stand: 2026-11-03, macOS 27.0.1 (Build 26A434), Claude Code 2.1.316. Nur Recherche und harmlose Experimente (Wegwerf-Code in `/private/tmp/b7-experiments/`). Kein sudo, nichts angelegt, nichts gestartet, `claude setup-token` nicht ausgeführt, kein Zugriff auf `~/.claude`/Token-Dateien.

Kennzeichnung: **GEMESSEN** = lokal ausgeführt, **GELESEN** = Doku/Forum, **UNVERIFIED** = Annahme.

## Kurzfazit

| # | Frage | Verdikt |
|---|-------|---------|
| 1a | Admin-Prompt per `osascript`/Authorization Services, ad-hoc signiert | **machbar** (kompiliert; Prompt-Lauf braucht den User). Touch ID: wahrscheinlich nur Passwort |
| 1b | `SMAppService.daemon` mit ad-hoc-Signatur | **unklar bis riskant**; Apple DTS rät von ad-hoc ab. Mit "Apple Development"-Zertifikat (hast du) plausibel, aber UNVERIFIED |
| 2 | Token per PTY abfangen | **machbar mit Vorbehalt** (Format/Umbruch/TTY); Parser-Prototyp gemessen mit Fake-Tool |
| 3 | Re-Login sparen via BSD-Gruppenvererbung | **machbar, sogar einfacher als gedacht**: macOS vererbt die Gruppe des Elternverzeichnisses immer, auch ohne setgid |
| 4 | Teil-Setup erkennen | **machbar**, fast alles ohne Root lesbar; Ausnahme Agent-Home/Log |
| 5 | Empfehlung | `osascript`-Weg (AppleScript `with administrator privileges`) mit gebündeltem, root-eigen installiertem Script; ca. 5 Pakete |

---

## 1. Admin-Rechte aus lokal/ad-hoc signierter App

### 1a. `osascript` / NSAppleScript (`do shell script ... with administrator privileges`)
- **GEMESSEN:** `osa.swift` (NSAppleScript in-process, führt `/usr/bin/id -u` mit eigenem Prompt-Text aus) kompiliert fehlerfrei mit `swiftc`. Ausgeführt habe ich es **nicht**, weil dabei der Passwort-Dialog erscheint.
- Ablauf: Das System zeigt den Standard-Authentisierungsdialog (SecurityAgent) mit dem `with prompt`-Text. Nach Erfolg läuft der Befehl als root. Ein Prompt pro `do shell script`-Aufruf; ein Aufruf mit dem ganzen Setup-Script = ein Prompt.
- Keine Signatur-/Team-ID-Anforderung, funktioniert aus ad-hoc-signierten Apps. Es braucht keine Entitlements. Aus sandboxed Apps nicht nutzbar (AgentBar ist nicht sandboxed, sonst wäre das Notch-Panel/Socket ohnehin schwierig).
- Nachteile: Es wird ein einziger Shell-String übergeben (Quoting-Falle: Pfad mit Leerzeichen/Sonderzeichen sauber escapen, nie Nutzereingaben einsetzen); kein Live-Output im Prompt (Ausgabe kommt erst am Ende, Fortschritt nur grob; Workaround: Script schreibt Status in eine Datei/Log, die die App pollt); `NSAppleScript` blockiert den Thread, daher auf Hintergrund-Thread. macOS kann beim ersten Mal eine "AgentBar möchte … steuern"-Automation-Abfrage zeigen, wenn man statt NSAppleScript die `osascript`-Binary über Apple Events anspricht; in-process NSAppleScript mit nur `do shell script` löst in der Regel keine TCC-Automationsabfrage aus (**UNVERIFIED**, muss bei der ersten Ausführung beobachtet werden).
- Sicherheitsaspekt: Das Script, das als root läuft, muss vor der Ausführung gegen Manipulation geschützt sein. Das Script liegt im App-Bundle (vom User beschreibbar, solange `~/Desktop/AgentBar.app` dem User gehört). Ein Angreifer mit User-Rechten könnte es austauschen, und der Prompt zeigt den Inhalt nicht. Gegenmaßnahme: Script vor Ausführung nach `/tmp`-freies, root-eigenes Ziel kopieren (das geht aber erst mit root) oder SHA-256 des Scripts (in der App einkompiliert) vor dem Aufruf prüfen und den Prompt-Text die Hash-Kurzform nennen lassen. Gleiches Problem hat der manuelle Weg nicht, weil der User den Inhalt selbst liest.
- Touch ID: **GELESEN** (Burrow-PR #346, Podman-Desktop-Issue #2998): Der klassische `system.privilege.admin`-Dialog über SecurityAgent bietet nach den gefundenen Quellen kein Touch ID, nur Passwort (Details auf neueren macOS-Versionen ungeklärt). **UNVERIFIED** auf deinem System; beim ersten Lauf beobachten.
  - Quellen: https://github.com/caezium/Burrow/pull/346, https://github.com/containers/podman-desktop/issues/2998

### 1a'. Authorization Services (`AuthorizationCreate` + `AuthorizationCopyRights` + `AuthorizationExecuteWithPrivileges`)
- **GEMESSEN:** `auth.swift` kompiliert. `AuthorizationExecuteWithPrivileges` ist in Swift nicht direkt aufrufbar (unavailable), geht nur über `dlsym` wie im Test. Nicht ausgeführt (Prompt).
- **GELESEN:** Apple markiert die Funktion als deprecated seit 10.7 und verweist auf Helper per launchd/Service Management (https://developer.apple.com/documentation/security/authorizationexecutewithprivileges). Sie funktioniert laut Drittprojekt (STPrivilegedTask) noch unter macOS 13; ob sie auf macOS 26/27 noch existiert, ist hier nur durch Ausführen zu klären (**UNVERIFIED**).
- Vorteil gegenüber osascript: echter Pipe-Output (Live-Fortschritt), Rechte können vorab geholt und für mehrere Aufrufe wiederverwendet werden. Nachteil: deprecated, Wegfall-Risiko, gleicher SecurityAgent-Dialog (Touch ID ebenso unklar). Nicht empfohlen als Primärweg.
- Die moderne Alternative (`SMJobBless`) ist ebenfalls deprecated und braucht Team-ID-gebundene Signatur-Anforderungen (SMPrivilegedExecutables), also kein Weg für ad-hoc.

### 1b. `SMAppService.daemon(plistName:)`
- **GEMESSEN:** `smstatus.swift` kompiliert; `SMAppService.daemon(plistName:"com.agentbar.host.plist").status` liefert außerhalb eines Bundles erwartungsgemäß `notFound (3)`. Registriert wurde nichts (würde einen Eintrag unter Anmeldeobjekte/Hintergrund anlegen = Systemänderung).
- **GELESEN (Apple Developer Forums):**
  - Plist muss im Bundle unter `Contents/Library/LaunchDaemons/` liegen, `BundleProgram` zeigt relativ aufs Binary im Bundle. Der Daemon läuft aus dem App-Bundle als **root** (oder `UserName` aus der Plist; ob `UserName=agentbar` zulässig ist, ist **UNVERIFIED**, in der Praxis üblich bei Daemons, die Privilegien abgeben).
  - `register()` löst eine Benutzerfreigabe aus (Systemeinstellungen > Allgemein > Anmeldeobjekte & Erweiterungen > "Im Hintergrund erlauben"); Status `.requiresApproval`, dann Admin-Authentisierung in den Einstellungen. Die App kann den Prompt nicht selbst beantworten; es sind mehrere Klicks außerhalb der App nötig, also kein "ein Klick, ein Prompt".
  - Quinn (Apple DTS): Daemon und App mit **derselben Apple-Signatur-Identität** signieren; bei ad-hoc ("Sign to Run Locally") sei mit Problemen zu rechnen (z. B. Daemon verliert Hintergrundrecht nach Neustart). Mehrfach berichtetes `Operation not permitted` (Code 1) bei `register()`.
  - Quellen: https://developer.apple.com/forums/thread/761249, /745720, /756846, /757463, /768592
- Vorteil: dauerhafter, vom System verwalteter Daemon, Updates ohne neuen Admin-Prompt (nach Freigabe). Nachteile: Freigabe in den Einstellungen manuell, ad-hoc riskant, der Daemon liegt im vom User beschreibbaren Bundle (für root-Daemon sicherheitlich schlecht), Entfernen = `unregister()`. Für dein Vorhaben (Daemon läuft als `agentbar`, Setup legt Benutzer an) löst SMAppService das Anlegen von Benutzer/Gruppe/Verzeichnissen **nicht**; dafür bräuchte man trotzdem einen root-Schritt.
- Verdikt: **nicht als Primärweg**. Evtl. später, wenn du Developer-ID/Apple-Development-Signatur nutzt. Offene Frage: `security find-identity` zeigt ein Zertifikat "Apple Development: toasty.lukas@gmail.com"; ob die App damit signiert werden kann und SMAppService dann sauber läuft, ist **UNVERIFIED** und ein eigener Test wert (siehe Fragen).

### 1c. Zusammenfassung Vor-/Nachteile

| | osascript/NSAppleScript | AuthorizationExecuteWithPrivileges | SMAppService.daemon |
|---|---|---|---|
| ad-hoc ok | ja | ja (solange API existiert) | riskant/unklar |
| Prompt | 1 Passwortdialog | 1 Passwortdialog | Dialog + Gang in Systemeinstellungen |
| Touch ID | wahrscheinlich nein (UNVERIFIED) | wahrscheinlich nein | Einstellungen: ja (Systemdialog), UNVERIFIED |
| Live-Fortschritt | nein (Datei-Polling) | ja (Pipe) | über Daemon-IPC |
| Zukunftssicher | ja, stabil | nein (deprecated) | ja (Apples Weg) |
| Legt Benutzer an | ja (Script als root) | ja | nein, extra root-Schritt |

---

## 2. Token abfangen (`claude setup-token`)

- **GEMESSEN:** `claude setup-token --help` zeigt nur `Usage: claude setup-token [options]`, "Set up a long-lived authentication token (requires Claude subscription)", Option `-h`. Keine Flags für Ausgabe/Format/Non-interaktiv. Nicht gestartet.
- **GELESEN** (https://code.claude.com/docs/en/authentication, Abschnitt "Generate a long-lived token"): Der Befehl öffnet denselben Browser-OAuth-Fluss wie `/login`; der Token wird nach der Freigabe im Terminal **ausgegeben**, nirgends gespeichert; Gültigkeit ein Jahr; erfordert Pro/Max/Ultra/Team/Enterprise; nur Modellanfragen; als `CLAUDE_CODE_OAUTH_TOKEN` setzen; `--bare` liest ihn nicht. Sekundärquellen sagen, dass der Befehl ein TTY braucht (https://github.com/cheaper-inference/OmniRoute/wiki/Claude-Code-Setup-Token, Community, nicht von Anthropic). Ob die Ausgabe ohne TTY (Pipe) erscheint, ist **UNVERIFIED**; deshalb PTY einplanen. Das Tokenpräfix `sk-ant-oat01-` stammt aus Community-Quellen und aus deinem Auftrag, **UNVERIFIED** gegen die echte Ausgabe.
- Ob der Browser auf dem User-Desktop aufgeht: Der Prozess läuft unter dem App-User (GUI-Sitzung), also öffnet `open` den Standardbrowser. Läuft `claude` stattdessen als `agentbar` (sudo -u), gibt es keinen Browser, der URL-Flow bräuchte dann Copy-Paste (Issue "Headless /login", https://claudeissues.com/issue/83316). Deshalb `setup-token` **als Besitzer** per PTY starten, Token danach als root/`agentbar` ablegen (Schritt unten). Auch Konfigurationsspuren: setup-token schreibt laut Doku nichts, ob es trotzdem Dateien in `~/.claude` des Besitzers anlegt, ist UNVERIFIED.

### Entwurf (PTY)
1. App erzeugt PTY (`openpty`/`forkpty`), **Fenstergröße sehr breit setzen (z. B. 1000 Spalten)**, `TERM=dumb` oder `xterm` ohne Farbe, Umgebung minimal (kein `ANTHROPIC_API_KEY`, kein `CLAUDE_CODE_OAUTH_TOKEN`).
2. Kind: `claude setup-token` (Pfad aus Login-Shell-PATH ermitteln; GUI-Apps haben nur Minimal-PATH, vgl. Lektion `~/.local/bin`).
3. Eltern liest PTY-Master nicht blockierend, hält nur einen **rollenden Puffer** im Speicher (nur der Tail, z. B. 8 KB). UI zeigt **nur einen Status** ("Warte auf Browser-Freigabe…"), nie die Ausgabe.
4. Parser: ANSI-Sequenzen entfernen, dann Regex `sk-ant-oat01-[A-Za-z0-9_-]{20,}` auf einzelnen Zeilen, Token endet am ersten Zeichen außerhalb der Klasse. Plausibilitätsprüfung (Länge, keine Leerzeichen). Nach Fund: Prozess beenden (SIGTERM, Gruppe), Puffer mit `memset_s` löschen.
5. Schreiben: erst mit root-Rechten (zweiter Admin-Prompt vermeiden: Schritt im selben Admin-Aufruf wie das Setup, Token dem Script über **stdin/Datei-Deskriptor**, nicht argv/env) per `install -m 0600 -o agentbar` nach `~agentbar/.config/agentbar/claude-oauth-token` (temp + rename). Ablauf-Reihenfolge: Setup (root) legt Benutzer an; setup-token (Besitzer) läuft **vor** oder **nach** dem Admin-Schritt; Token wird bis zum Schreiben nur im Speicher gehalten. Besser: erst Benutzer anlegen, dann Token holen, dann Schreiben mit einem zweiten kleinen Admin-Aufruf. Das sind zwei Prompts; ein Prompt geht nur, wenn man den Token vor dem Admin-Aufruf holt und beim Setup per Pipe übergibt (Variante A, bevorzugt: **setup-token zuerst, dann ein Admin-Aufruf**).
   - Admin-Aufruf mit Stdin-Übergabe geht mit `AuthorizationExecuteWithPrivileges` (Pipe), bei osascript nicht direkt. Workaround: Token vorher in eine 0600-Datei im Besitzer-Verzeichnis (z. B. `~/Library/Application Support/AgentBar/.tok.XXXX`) schreiben, das Setup-Script als root liest sie, verschiebt sie und löscht sie (Datei nur Sekunden vorhanden, nur Besitzer lesbar). Nachteil: Token liegt kurz auf Platte des Besitzers.
6. Fehler: Timeout (Browser nie bestätigt, 5 Min), Prozess endet ohne Token, mehrere Treffer, Parser findet nichts. In allen Fällen: keine Ausgabe loggen, nur "Token nicht erkannt; manuell einfügen" mit Eingabefeld (SecureField) als Fallback.

### Parser-Test (GEMESSEN mit **Fake**-Tool, nicht dem echten Befehl)
`/private/tmp/b7-experiments/pty/`: `fake-setup-token.sh` gibt ANSI, Text und einen künstlichen `sk-ant-oat01-FAKE…`-Token (128 Zeichen) mit hartem Umbruch an der Terminalbreite aus; `ptyrun.py` startet es über ein PTY.
- 500 Spalten: Regex je Zeile findet den ganzen Token (128 Zeichen).
- 80 Spalten: Token wird bei 80 Zeichen abgeschnitten (Treffer 80 statt 128).
- Alle Zeilen zusammenkleben, um den Umbruch zu heilen: liefert 133 statt 128 Zeichen, weil der folgende Text ("Store…") mit angeklebt wird. Zusammenkleben ist also **falsch**.
- Schluss: PTY sehr breit setzen; Zeilenweise matchen; Länge/Format prüfen. Echte Tokenlänge ist UNVERIFIED (Fake-Wert gewählt).

### Risiken
- Ausgabeformat ändert sich (Präfix, Box-Zeichnen, Farbcodes, Umbruch, TUI statt Plaintext); Parser bricht lautlos. Gegenmaßnahme: Fallback-Eingabefeld, Test mit echtem Lauf einmal durch den User.
- Token in Scrollback/Logs: nur in-memory, kein `print`/`os_log` der Rohausgabe (Log-Sanitizer der App kennt das Muster bereits? prüfen), Crashdumps/Swap, Terminal.app wird nicht benutzt.
- Der Token ist ein Langzeit-Geheimnis mit Account-Zugriff: nicht in `UserDefaults`, nicht in Env des Hosts außer beim Spawn, nie in argv.
- Mehrere Setup-Läufe erzeugen mehrere gültige Tokens (Widerruf/Verwaltung unklar, UNVERIFIED).

---

## 3. Re-Login sparen: BSD-Gruppenvererbung

**Ausgangslage (GEMESSEN):** `id -Gn` des Users enthält `agentbar-ipc` (nicht primär: primär ist `staff`, gid 20). `dseditgroup -o checkmember` bestätigt die Mitgliedschaft; `dscl` zeigt `GroupMembership: agentbar lukaspock`. Der laufende Prozess hat die Gruppe also bereits im Credential (nach deinem Re-Login). Für den Test ist das ausreichend, denn Vererbung hängt vom Elternverzeichnis ab, nicht von der Prozessgruppe.

**Versuch** in `/private/tmp/b7-experiments/grp/` (APFS, umask 022, Eltern-Gruppe `wheel`):

| Fall | Verzeichnis | Datei / Unterverz. / Socket erhalten Gruppe |
|------|-------------|---------------------------------------------|
| a | `drwxr-xr-x lukaspock wheel` (Gruppe unverändert) | Datei: `wheel` (Gruppe des Elternverzeichnisses, **nicht** `staff`) |
| b | `chgrp agentbar-ipc`, Modus 0750, **ohne** setgid | Datei, Unterverz., Unix-Socket: **`agentbar-ipc`** |
| c | `chgrp agentbar-ipc`, 2770 (setgid) | Datei, Unterverz., Socket: `agentbar-ipc`; Unterverz. bekommt **kein** setgid-Bit (`drwxr-xr-x`) |
| d | `chgrp agentbar-ipc`, 2750 | Socket: `agentbar-ipc` |
| tief | b/d/n/f (verschachtelt) | alle `agentbar-ipc` |
| e | `chgrp agentbar-ipc datei` als Mitglied, ohne root | funktioniert |

**Ergebnis:** Auf macOS (APFS) erbt jede neu angelegte Datei/Verzeichnis/Socket die Gruppe des **Elternverzeichnisses**, unabhängig vom setgid-Bit (BSD-Semantik); die Prozess-Gruppe (`staff`) spielt keine Rolle. Das setgid-Bit ist auf macOS für die Gruppenvererbung überflüssig, es wird nicht auf Unterverzeichnisse übertragen (nur Gruppe). Bestätigung durch den Ist-Zustand: `/Users/Shared/AgentBar` ist `drwxr-x--- lukaspock agentbar-ipc` (kein setgid) und `agentbar.sock`/`token.agent` haben Gruppe `agentbar-ipc`.

**Konsequenz für B7:** Das Setup (root) legt `/Users/Shared/AgentBar` mit Besitzer = Owner und Gruppe `agentbar-ipc`, Modus 0750 an. Die App (Besitzer) kann darin Socket/Token anlegen, ohne dass die Gruppe in ihren Credentials steht, denn als **Besitzer** hat sie über die Owner-Bits Zugriff; die Datei erhält `agentbar-ipc` automatisch, und `agentbar` (Mitglied, via launchd-Daemon frisch gestartet) kann sie lesen/schreiben. Kein `chown`/`chgrp` und kein Re-Login nötig.
**Wichtige Grenzen (nicht gemessen = UNVERIFIED):**
- Ich konnte keine Gruppe testen, in der ich **nicht** Mitglied bin (bräuchte root/neue Gruppe). Die Vererbung gilt laut BSD-Semantik unabhängig davon; Test nach dem ersten echten Setup vor dem Re-Login nachholen.
- Falls der Server-Code selbst `chown`/`fchown` auf die Gruppe aufruft oder die Gruppe prüft (Fail-closed-Check "Gruppe == agentbar-ipc"), muss er ohne Credential-Mitgliedschaft funktionieren: `fchown` mit nicht-Mitglied-Gruppe schlägt fehl (EPERM). Das entfernen, auf Vererbung verlassen und nur prüfen.
- Dateien, die **agentbar** im Verzeichnis anlegt, gehören `agentbar:agentbar-ipc`; der Besitzer liest sie nur ohne Re-Login, wenn Owner-/Other-Bits es erlauben. In der aktuellen Architektur legt nur die App dort an.
- Lesen im Verzeichnis anderer Eigentümer (z. B. `ls /Users/Shared/AgentBar` durch einen frisch hinzugefügten Nicht-Besitzer) bräuchte die Gruppe im Credential, also Re-Login. Für den Besitzer entfällt das.
- Gruppenmitgliedschaft des Besitzers trotzdem im Setup eintragen (für die CLI, `agentbar` als Prozess ohne Besitzer-Rechte, und für Fallback), aber nicht darauf warten.

---

## 4. Fehler- und Rückbaupfade: Prüfungen des App-Zustandsautomaten (alles ohne Root)

**GEMESSEN (ohne Root):** `dscl . -read /Users/agentbar UniqueID NFSHomeDirectory IsHidden` (liest), `dscl . -read /Groups/agentbar-ipc GroupMembership`, `dseditgroup -o checkmember`, `launchctl print system/com.agentbar.host` (state, pid, runs, `last exit code`; alles lesbar), `stat` auf Binary/Plist, `ls -ld /Users/agentbar` (`drwx------ agentbar:staff`), `ls -l` auf IPC-Dir. **Nicht lesbar:** Inhalt von `/Users/agentbar` (Home 700), also auch `host.log`, `work`, Token-Datei (`Permission denied`, gemessen). Fehlende Dateien dort lassen sich ohne Root nicht von "nicht lesbar" unterscheiden.

Zustände und Prüfungen (Reihenfolge = Automat):

1. **Benutzer-Record fehlt**: `dscl . -read /Users/agentbar` Exit != 0 oder `id -u agentbar` schlägt fehl. Zustand "nicht eingerichtet".
2. **Record ohne UID/Home (Teil-Setup)**: `dscl` liefert Record, aber `UniqueID` oder `NFSHomeDirectory` fehlen/leer; `id -u` schlägt fehl; Home-Verzeichnis existiert nicht (`stat` ENOENT) -> "Teil-Setup, Reparatur/Entfernen nötig" (der Setup-Script-Schritt 1 skippt, wenn `id -u` klappt).
3. **Home gehört root (Lektion Nachtrag 2)**: `stat -f %Su /Users/agentbar` != `agentbar` oder Modus != 700 (lesbar, da `stat` nur den Verzeichniseintrag braucht). Reparatur: `chown agentbar:staff`, `chmod 700`.
4. **Versteckt/Admin-Status**: `dscl ... IsHidden`, `dseditgroup -o checkmember -m agentbar admin` (muss "no" sein; Admin ist ein Sicherheitsfehler).
5. **Gruppe**: existiert, enthält `agentbar` und den Besitzer (`dscl GroupMembership`); Besitzer-Prozess hat Gruppe im Credential? (`getgroups()`), nur Hinweis, nach Abschnitt 3 nicht blockierend.
6. **IPC-Verzeichnis**: Besitzer = Owner, Gruppe `agentbar-ipc`, Modus 0750 (`stat`); Socket vorhanden und verbindbar; `token.agent` Modus 0640.
7. **Binaries**: `/usr/local/libexec/agentbar/agentbar-host` root:wheel 755 und gleiche Prüfsumme wie das im App-Bundle (bei App-Update: Host veraltet -> Update-Karte); `/usr/local/bin/agentbar`; Plist `/Library/LaunchDaemons/com.agentbar.host.plist` root:wheel 644.
8. **Daemon**: `launchctl print system/com.agentbar.host`: `state = running`, `pid`, `runs`, `last exit code`. **EX_CONFIG / "spawn failed"** erscheint dort als `last exit code = 78` bzw. `job state = spawn failed`/"Service could not initialize" (genauer Wortlaut **UNVERIFIED**); typische Ursache Home gehört root oder Log-Pfad nicht schreibbar. Zusätzlich: Host verbunden (Socket-Handshake mit Rolle `.agent`, `ping`)? Läuft der Daemon, aber kein Handshake -> Hinweis auf Protokollversions-Skew oder Dead-Man.
9. **Log nicht schreibbar** (Lektion: `/var/log` falsch): ohne Root nicht prüfbar. Indirekt: Daemon `runs` hoch, `state` wechselt, kein Handshake -> "Host startet nicht, Log: `sudo tail /Users/agentbar/host.log`". Alternative: Host meldet beim Handshake seinen Log-Status ("log ok", Fehler); oder Log in den von beiden lesbaren IPC-Ordner legen (Designänderung).
10. **Token**: Datei im Agent-Home ist für den Besitzer unsichtbar. Prüfung über den Host (Op `tokenstatus`, liefert nur vorhanden/Modus/Alter, nie den Inhalt). Ohne laufenden Host: "unbekannt".
11. **Workspaces**: `/Users/agentbar/work` über den Host listen.
12. **Hooks**: über Host `hookplan`.

Reparatur/Rückbau:
- Idempotentes Setup (Script-Schritte prüfen Zustand) kann Teil-Setups reparieren; die App ruft dieselbe Admin-Aktion mit "repair"-Modus. Vorher Diff dem User zeigen ("Folgendes wird geändert").
- Rückbau: `remove-agent-user.sh` (Daemon `bootout`, Plist/Binary entfernen, `sysadminctl -deleteUser`; Home löschen ist **irreversibel**, expliziter Bestätigungsdialog nötig, Option "Home behalten").
- Abbruch mitten im Admin-Prompt: osascript liefert Fehler -128 ("User canceled"): kein Zustandswechsel. Abbruch während des Scripts: Zustand neu aus den Prüfungen ableiten, nicht aus einem gespeicherten Flag.
- Ein Notaus (`--panic`) bleibt im Script.

---

## 5. Empfehlung

**Weg:** Setup per `NSAppleScript` `do shell script "…/setup-agent-user.sh …" with administrator privileges` (ein Passwortdialog), Script aus dem Bundle vor dem Aufruf per SHA-256 geprüft (einkompiliert), Token vor dem Admin-Aufruf per PTY geholt und über eine kurzlebige 0600-Datei übergeben. `SMAppService.daemon` erst später und nur mit echter Apple-Signatur; `AuthorizationExecuteWithPrivileges` nur als Plan B (deprecated).

Begründung: einziger Weg, der mit lokaler/ad-hoc-Signatur ohne Zusatzaufwand funktioniert und das vorhandene, bereits live bewährte Script wiederverwendet. Ehrliche Einschränkung: Touch ID wahrscheinlich nicht (Passwort); erster Lauf entscheidet.

### Pakete (Aufwand grob, jeweils getrennte Dateien)
| P | Inhalt | Aufwand |
|---|--------|---------|
| B7-1 | `AdminRunner`: NSAppleScript-Wrapper (Hintergrund-Thread, Quoting, Fehler -128, Hash-Prüfung, Status-Datei-Polling) | klein (0,5 Tag) |
| B7-2 | Zustandsautomat `AgentSetupState` mit den Prüfungen aus Abschnitt 4 (rein lesend, voll unit-testbar mit injizierten Kommandos) | mittel (1 Tag) |
| B7-3 | Script-Anpassungen: Gruppen-Mitgliedschaft nicht mehr blockierend, Token-Übergabe-Datei statt `--set-token`-Prompt, Status-/Fortschrittsdatei, Bundle-Pfade (Host/CLI im Bundle) | klein-mittel (0,5-1 Tag), **Scripts/** ist heute gesperrt; neuer Auftrag |
| B7-4 | `TokenCapture` (PTY, Parser, Timeout, Fallback-Feld), mit Fake-Tool getestet | mittel (1 Tag) |
| B7-5 | Panel-UI: Karte, Fortschritt, Reparatur-/Entfernen-Flow, Bestätigungen | mittel (1 Tag) |
| B7-6 | Server: auf Gruppenvererbung statt `chgrp` umstellen (Abschnitt 3), Re-Login entfällt | klein (0,25 Tag) |
| B7-7 | Manueller Abnahmetest auf deinem Mac (Prompt, Token, Entfernen) | 0,5 Tag mit dir |

### Offene Fragen an den User
1. Ist der Apple-Development-Account (`toasty.lukas@gmail.com`) ein bezahlter Developer Program-Account? (Entscheidet, ob SMAppService/Developer ID für Verteilung später in Frage kommt.)
2. Darf ich beim nächsten Schritt den `osa`-Test mit dir zusammen ausführen (`/private/tmp/b7-experiments/admin/osa`, harmlos: `id -u`, erwartet Ausgabe `0`)? Du gibst das Passwort ein und beobachtest, ob Touch ID angeboten wird. Der Dialog erscheint nur in deiner Sitzung.
3. Echter `claude setup-token`-Lauf mit PTY-Prototyp (du loggst im Browser ein): erlaubt? Nötig, um Format/Umbruch/TTY-Bedarf zu bestätigen.
4. Token-Übergabe über kurzlebige Datei beim Besitzer akzeptabel, oder lieber zwei Passwortprompts (Token direkt per Pipe)?
5. Soll "Entfernen" das Home von `agentbar` löschen (irreversibel) oder behalten?

### Schritte für dich (falls du die Experimente selbst ausführen willst)
```
/private/tmp/b7-experiments/admin/osa
```
Erwartet: Passwortdialog "AgentBar B7 test (harmless: id -u)", danach `result: 0`. Abbrechen ergibt `ERROR: … -128`.
```
/private/tmp/b7-experiments/admin/auth
```
Erwartet: Passwortdialog; falls `Execute status` einen Fehler liefert, ist die deprecated-API auf macOS 27 nicht mehr nutzbar.

## Gemessen vs. nur gelesen vs. UNVERIFIED (Übersicht)
- Gemessen: Kompilierung der drei Swift-Programme; `SMAppService`-Status `notFound` außerhalb eines Bundles; Gruppenvererbung (Tabelle Abschnitt 3); PTY-Parser mit Fake-Tool; read-only Statusabfragen (`dscl`, `launchctl print`, `stat`); Agent-Home nicht lesbar; `claude setup-token --help`; Signatur von AgentBar.app und `agentbar-host` (beide ad-hoc, keine Team-ID); vorhandene Identität "Apple Development".
- Nur gelesen: Verhalten von SMAppService (Freigabe, ad-hoc-Warnung von Apple DTS), Deprecation von AuthorizationExecuteWithPrivileges, Touch-ID-Verhalten, `setup-token`-Dokumentation.
- UNVERIFIED: tatsächlicher Prompt-Lauf (osascript/Authorization), Touch ID, TCC-Abfrage bei NSAppleScript, echte `setup-token`-Ausgabe (Präfix, Länge, Umbruch, TTY-Pflicht), `UserName` in SMAppService-Plist, `launchctl`-Wortlaut bei EX_CONFIG, Vererbung für Gruppen ohne Mitgliedschaft.

Quellen: https://developer.apple.com/forums/thread/761249, https://developer.apple.com/forums/thread/745720, https://developer.apple.com/forums/thread/756846, https://developer.apple.com/forums/thread/757463, https://developer.apple.com/documentation/security/authorizationexecutewithprivileges, https://code.claude.com/docs/en/authentication, https://github.com/caezium/Burrow/pull/346, https://github.com/containers/podman-desktop/issues/2998, https://claudeissues.com/issue/83316-headless-login-oauth-url-cant-be-copied-c-fails-over-ssh-blocking-login-on-brows
