# dscl eDSPermissionError -14120 beim Setup (Recherche)

Stand: 2026-11-07, macOS 27.0.1 (26A434) auf dem Testrechner. Nur Recherche, keine Script-Aenderung.

## 1. Befund

Symptom: `dscl . -create /Users/agentbar UniqueID 309` als root (NSAppleScript `do shell script ... with administrator privileges`, ad-hoc-signierte App) scheitert mit `eDSPermissionError / DS Error -14120`. Der Account `agentbar` ist uid 502, Shell /bin/zsh, per `sysadminctl` angelegt.

Lokaler Ist-Zustand (lesend geprueft): Der Record hat `_writers_passwd/_writers_hint/_writers_picture/...: agentbar` (typisch fuer sysadminctl-Accounts, der User darf diese Attribute selbst schreiben), aber kein `AuthenticationAuthority`, kein admin. Alle `_`-Role-Accounts liegen < 500.

Wichtige Beobachtung aus dem Script (Zeilen ca. 222-235): Der Preflight `dscl . -create /Users/agentbar UserShell <aktuell>` hat NICHT zum Abbruch gefuehrt; erst `UniqueID` scheiterte. Schreiben auf den Record ist also grundsaetzlich moeglich (Annahme: so war der Ablauf, vom User berichtet, nicht von mir reproduziert). Das spricht gegen "root-Prozess hat generell keinen Schreibzugriff auf den lokalen Node (TCC/FDA)" und fuer "UniqueID eines BESTEHENDEN Records ist speziell geschuetzt". UNVERIFIED, nur Indiz.

### Hypothesen nach Wahrscheinlichkeit

| # | Hypothese | Evidenz | Status |
|---|-----------|---------|--------|
| H1 | opendirectoryd/Apple verbietet (oder erschwert) das Aendern von UniqueID an bestehendem Record, auch fuer root; Neuanlage mit UniqueID geht | Apple Dev Forums 119578: `-append UniqueID` auf bestehendem User gibt -14120 ab 10.15, `-create` als Workaround gemeldet; Apple Community/macosx.com: UniqueID von root nicht aenderbar, "fuer manche Properties auch mit sudo nicht" | Indiz, keine Apple-Doku. UNVERIFIED fuer macOS 27 |
| H2 | Aufrufender Prozess (App via osascript) hat nicht die Rechte, die ein Terminal mit sudo hat (TCC-Attribution / "responsible process") | Eclectic Light 2020: bei sudo im Terminal gilt Terminals Privacy-Grant; aus Script Editor/anderen Apps sieht macOS die App nicht in der Attribution Chain, Grants bringen dort nichts. macscripter: `with administrator privileges` = root, aber ohne Grants der aufrufenden App | Generelles Verhalten belegt, Bezug zu dscl-Schreibzugriffen NICHT belegt. Gegenindiz: UserShell-Write ging durch. UNVERIFIED |
| H3 | Secure Token / Volume Owner des ausfuehrenden Accounts | Jamf-/Blog-Berichte (megocollector, Jamf Community) zu -14120 beim LOESCHEN: Admin ohne SecureToken, Ziel-User mit SecureToken. Account `agentbar` hat hier keine AuthenticationAuthority, also vermutlich keinen Token, und root hat per se keinen | Nur Delete-Faelle, nur ein Blog. Fuer Create/Change nicht belegt. UNVERIFIED |
| H4 | Neuanlage generell blockiert (Lix-Installer-Issue #29: `dscl . -create /Users/_nixbld5 UniqueID 31005` -> eDSPermissionError auf Sequoia) | Issue-Suchtreffer, Seite per WebFetch 403, Details/Loesung unbekannt | Warnsignal: auch Neuanlage per dscl kann scheitern. UNVERIFIED |
| H5 | App-Management-/Full-Disk-Access-Schutz | Kein Treffer, der FDA/App Management mit dscl-Schreibzugriffen verbindet | Keine Belege |

### Sudo im Terminal vs. osascript aus App
- Terminal+sudo: Prozess erbt TCC-Attribution von Terminal (Eclectic Light, 2020, aelter als macOS 27; UNVERIFIED fuer heute). Terminal hat haeufig FDA, die App nicht.
- `do shell script ... with administrator privileges`: laeuft als root, aber ohne Grants der App; TCC/SIP werden separat geprueft (pimylifeup/Apple Dev Forums 123489, Sekundaerquellen).
- Konsequenz: Ein Terminal-Test allein trennt H1 von H2 NICHT sauber, weil beides gleichzeitig abweicht. Test unten deshalb gestaffelt.

### Rechtliche/Sicherheitsrelevante Randnotiz
`sysadminctl -addUser` ist der von Apple vorgesehene Weg zur Anlage (setzt u.a. GeneratedUID, ggf. SecureToken-Logik). Mit `-UID` wird laut Apple-Discussions-Treffer (macOS 10.12, `sysadminctl unable to create users with specified UID`) -14120 gemeldet; fuer 2024+ nicht verifiziert.

## 2. Auswirkungen eines anderen Namens/uid (Repo-grep)

- UID ist NICHT hartkodiert: `TransportSecurity.detected` loest den Agent-User per `getpwnam(agentUserName)` und Gruppe per `getgrnam(groupName)` auf; Peer-uid wird zur Laufzeit mit `pw_uid` verglichen. Eine andere uid (502 statt 309) funktioniert fuer die Hostpruefung ohne Codeaenderung, sofern Name und Gruppe stimmen.
- Der NAME ist an mehreren Stellen fest: `TransportSecurity.swift:31` (`defaultAgentUserName`), `SetupProbes.swift:110-113` (`agentUser`, `agentHome=/Users/agentbar`, `ipcGroup`, `ipcDirectory`), `AgentUser.name` (App-UI: RunsAsChip, Settings, PanelPages), `agentbar-host/main.swift` (Kommentar, `UserName=agentbar`), `Scripts/com.agentbar.host.plist.template` (`@AGENT_USER@`, `UserName`), `setup-agent-user.sh` und `remove-agent-user.sh` (Konstante `AGENT_USER`, `remove` verweigert sogar Namen != agentbar, Zeile 119), `SharedEndpointTrust.ipcGroupId("agentbar-ipc")`.
- SetupProbe verlangt "dscl UID < 500 und Shell /usr/bin/false" sowie Home-Owner == Name: uid 502 wuerde den Check `agentUser` als nicht erledigt/legacy melden.
- Umbenennung (z.B. `_agentbar`) braucht: Konstanten zentral machen (ein `AgentUser.name`/`AgentUserPaths`), Script-Variable `AGENT_USER`, Home `/var/agentbar` oder `/Users/_agentbar` (Hinweis: Role-Accounts liegen meist in `/var/empty` oder `/var/<name>`; fuer Claude-Config/Workspace wird aber ein beschreibbares Home gebraucht), remove-Script-Guard, Tests (Probes, TransportSecurity). Gruppe `agentbar-ipc` und IPC-Dir koennen bleiben (unabhaengig vom Usernamen).
- Pfadpruefung des Hosts (root-eigenes `/usr/local/libexec/agentbar/agentbar-host`) ist vom Usernamen unabhaengig.

## 3. Optionen

| Option | Robustheit | Sicherheit | Aufwand |
|--------|-----------|------------|---------|
| (a) Frischer Role-Account unter neuem Namen (`_agentbar`, uid 200..399), alter uid-502-Account bleibt/optional spaeter entfernen | Hoch, wenn Neuanlage per dscl im App-Kontext geht (H1). Umgeht UniqueID-Aenderung komplett. Falls H4 zutrifft, scheitert auch das | Hoch: kein Login-Account, Konvention `_` fuer Dienstaccounts, kein In-Place-Umbau | Mittel: Namen zentralisieren (s.o.), Script-Zweig fuer Legacy "lassen", Home neu, Token neu setzen, Doku. ca. 0,5-1 Tag |
| (b) `sysadminctl` als Fallback bei dscl-Fehler | Mittel: Apple-supported, aber UID-Wahl/Hidden/Shell danach per dscl nachziehen (kann wieder -14120 geben); erzeugt Login-Account (uid >= 501), Secure-Token-Nebenwirkungen | Mittel: normaler Login-Account mit Passwort-Option, Hardening noetig (Shell false, Passwort `*`, hidden) | Niedrig-mittel. Erfordert ggf. Admin-Credentials als Argument (nicht in Prozessliste!) -> eher unschoen |
| (c) Hinweis auf Full Disk Access fuer Terminal/App | Nur wirksam bei H2; Evidenz gering. FDA fuer eine ad-hoc-signierte App ist zudem fragil (Signatur wechselt bei Rebuild, Grant verfaellt) | Schlecht: FDA ist weitreichender Grant, nur fuer Setup unverhaeltnismaessig | Niedrig, aber unzuverlaessig. Nur als Diagnose, nicht als Loesung |
| (d) Migration ohne UID-Aenderung (neuer Account, Home kopieren, Rechte neu setzen) | Hoch, und es ist im Kern (a) plus Datenuebernahme | Hoch, wenn Kopie per `ditto`/`rsync -a` ohne Symlink-Folgen und danach `chown -R -P` | Mittel: zusaetzlich Kopierschritt, Token/Claude-Config pruefen. Meist unnoetig, da Home des Agenten wenig Wertvolles enthaelt (Token wird ohnehin neu installiert) |
| (e) uid 502 akzeptieren (Role-Account-Definition lockern: UID-Grenze/Shell nicht mehr verlangen) | Hoch, null dscl-Aenderung am Bestand | Niedriger: Login-Account bleibt sichtbar/loginfaehig (Shell /bin/zsh, evtl. Passwort); Hardening der Shell per `chsh`/dscl braucht weiter Schreibzugriff (UserShell-Write ging) | Niedrig. Kompromiss, falls (a) scheitert |

## 4. Empfehlung

1. Primaer (a)+(d): neuen Role-Account `_agentbar` per dscl NEU anlegen (UID 200..399), alten `agentbar` (uid 502) nicht anfassen; Home nicht kopieren, nur falls echte Daten drin liegen. Begruendung: Der Fehler tritt laut Indiz (H1) bei der UniqueID-Aenderung eines bestehenden Records auf, Neuanlage ist der klassische, gut belegte Weg (talkingmoose-Gist), und es entfaellt das riskante "Daemon stoppen, in-place umbauen".
2. Fallback (e), wenn Neuanlage im App-Kontext ebenfalls -14120 gibt: uid 502/Name `agentbar` weiterverwenden, nur Shell/Hidden/Passwort haerten, SetupProbe-Regel auf "kein admin, Shell false, nicht loginfaehig" statt UID < 500 umstellen.
3. FDA (c) nicht empfehlen; nur als Diagnoseschritt.
4. Erst nach Terminal-Test entscheiden; Script bleibt unveraendert.

## 5. Terminal-Test fuer den User (staffelt H1/H2/H4)

Alles als dein Admin im Terminal mit sudo. Testuser ist ein Wegwerf-Account, danach loeschen.

```
# A) Neuanlage per dscl im Terminal (zeigt, ob Neuanlage generell geht = H4 widerlegen)
sudo dscl . -create /Users/_abtest
sudo dscl . -create /Users/_abtest UniqueID 399
sudo dscl . -create /Users/_abtest PrimaryGroupID 20
sudo dscl . -create /Users/_abtest UserShell /usr/bin/false
sudo dscl . -create /Users/_abtest NFSHomeDirectory /var/empty
sudo dscl . -create /Users/_abtest Password '*'
sudo dscl . -read /Users/_abtest UniqueID

# B) UniqueID eines BESTEHENDEN Records aendern (zeigt H1)
sudo dscl . -create /Users/_abtest UniqueID 398
sudo dscl . -read /Users/_abtest UniqueID

# C) Am echten Account (nur Test, danach zurueck auf 502 nur wenn es klappte)
sudo dscl . -create /Users/agentbar UniqueID 309     # erwartet: -14120 wie in der App?

# D) Aufraeumen
sudo dscl . -delete /Users/_abtest
```

Auswertung:
- A ok, B fehlschlaegt, C fehlschlaegt: H1 -> Option (a).
- A, B und C ok im Terminal, aber in der App nicht: H2 (Kontext). Dann in der App denselben Block A nur mit Testuser pruefen; scheitert A dort, ist App-Kontext das Problem (Alternative: Setup per signiertem Helper oder Terminal-Befehl, den die App anzeigt).
- A scheitert schon im Terminal: H4/H3. Dann `sysadminctl -secureTokenStatus <dein Admin>` pruefen und Option (b)/(e).
- Bitte die genauen Fehlerzeilen zurueckmelden. Fuer H3 zusaetzlich `sysadminctl -secureTokenStatus agentbar`.

## Quellen (alle Sekundaerquellen, keine Apple-Doku zum Fehlercode gefunden)
- Apple Developer Forums: dscl appending a UniqueID to a user failing in 10.15 - https://developer.apple.com/forums/thread/119578
- Lix installer issue #29 (dscl -create UniqueID eDSPermissionError auf Sequoia; WebFetch 403, nur Suchsnippet) - https://git.lix.systems/lix-project/lix-installer/issues/29
- Determinate Systems: Nix und macOS Sequoia (UID-Kollisionen _nixbld) - https://determinate.systems/blog/nix-support-for-macos-sequoia
- Jamf Community (Delete -14120) - https://community.jamf.com/t5/jamf-school/macos-script-deleting-users-in-jamf-school-resulting-in-error/m-p/293091
- Jamf Community - https://community.jamf.com/t5/jamf-pro/can-t-remove-student-profiles-via-script-delete-status/m-p/308805
- Blog: Can't delete a macOS user with dscl (Secure Token) - https://it.megocollector.com/macos/cant-delete-a-macos-user-with-dscl-resolution/
- Apple Community: Can create users via dscl but not delete - https://discussions.apple.com/thread/253745292
- Eclectic Light: Why privileged commands may never be allowed (TCC-Attribution bei sudo vs. Apps, 2020) - https://eclecticlight.co/2020/02/15/why-privileged-commands-may-never-be-allowed/
- MacScripter: do shell script with administrator privileges Sonoma/Sequoia - https://www.macscripter.net/t/do-shell-script-with-administrator-privileges-bug-in-sonoma-and-sequoia/77065
- Apple Developer Forums: Catalina, bash via AppleScript - https://developer.apple.com/forums/thread/123489
- talkingmoose Gist: dscl-Nutzeranlage - https://gist.github.com/talkingmoose/4be6ae23c687469098c43fb6f9c06eab
- MacPorts ticket 72676 (Anubis-Block, Inhalt nicht gelesen) - https://trac.macports.org/ticket/72676
- Apple Discussions: sysadminctl -UID - https://discussions-jp-prz.apple.com/thread/254671708 (nur Suchsnippet)

Offen/UNVERIFIED: Keine Quelle erklaert -14120 fuer macOS 15-27 verbindlich; Zuordnung H1 beruht auf Indizien und dem Ablauf des Scripts.

## 6. Entscheidung (2026-11-07, vom Orchestrator getroffen, User nicht erreichbar)

Adopt statt migrate: Ein bestehender Account `agentbar` (uid >= 100, kein Admin) wird uebernommen, die UniqueID bleibt unveraendert; Haertung (hidden, Shell /usr/bin/false, Passwort `*`, AuthenticationAuthority/PasswordPolicyOptions loeschen) nur best effort mit Warnung. Nur neue Accounts werden als Role-Account (UID 200..399) angelegt. Das entspricht Option (e) mit nachgezogener Haertung; `--migrate`, Exit 20 und die Migrate-Karte in der App entfallen. SetupProbe: done bei uid >= 100, nicht Admin, Home ok und (Shell false ODER ohne AuthenticationAuthority mit Passwort `*`/leer). UNVERIFIED: ob die Neuanlage per dscl im App-Kontext (osascript) klappt (H4), und ob die Haertungs-Schreibzugriffe auf einen bestehenden Record durchgehen (nur UserShell-Write ist indirekt berichtet). Der User testet beides.
