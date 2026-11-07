# ZUM TESTEN (Stand 2026-11-07)

Alles hier braucht dich am Rechner (Passwort, Browser-Login, echtes System). Reihenfolge von oben nach unten. Schreib mir pro Punkt kurz "ok" oder die Fehlermeldung bzw. einen Screenshot.

## 0. Ausgangslage
- Der Daemon `agentbar-host` läuft vermutlich NICHT (ein Migrationsversuch hat ihn gestoppt). Der Account `agentbar` ist unverändert (uid 502, Shell `/bin/zsh`).
- Der Onboarding-Durchlauf lief am 2026-11-07 durch (Daemon läuft, Account übernommen). Offen: Abschnitte 5 bis 8 (Chat als Agent-Benutzer, nur lokal, Hooks, Eindruck am Notch) und neu: Abschnitt 10.
- Neu: Ein vorhandener Account `agentbar` (uid 502) wird jetzt ÜBERNOMMEN, die UID bleibt (macOS erlaubt den UID-Wechsel nicht, siehe `Docs/research/dscl-permission.md`). Es gibt keine Migrate-Karte mehr.

## 1. Daemon wieder starten (Terminal)
```bash
sudo launchctl bootstrap system /Library/LaunchDaemons/com.agentbar.host.plist; sudo launchctl print system/com.agentbar.host | grep -E "state|pid|last exit"
```
Erwartet: `state = running`.

## 2. dscl-Probe (Terminal), klärt den eDSPermissionError
Legt einen Probe-Benutzer an und löscht ihn gleich wieder. Dein Account wird nicht angefasst.
```bash
sudo dscl . -create /Users/zzprobe && sudo dscl . -create /Users/zzprobe UserShell /usr/bin/false && echo CREATE_OK; sudo dscl . -delete /Users/zzprobe && echo DELETE_OK
```
- Beides OK: Anlegen geht im Terminal. Problem liegt am Aufruf aus der App oder am Ändern der UID eines bestehenden Accounts (siehe `Docs/research/dscl-permission.md`).
- `eDSPermissionError`: Terminal braucht evtl. "Vollständigen Festplattenzugriff" (Systemeinstellungen → Datenschutz & Sicherheit).

Zusatz (optional, Terminal): Kann root den UID-Wert eines Probe-Accounts ändern?
```bash
sudo dscl . -create /Users/zzprobe && sudo dscl . -create /Users/zzprobe UniqueID 399 && echo UID_SET_OK; sudo dscl . -delete /Users/zzprobe && echo DELETE_OK
```

## 3. Onboarding mit Agent-Benutzer (App)
1. Menü → "Setup…" (oder das Fenster erscheint von selbst).
2. Willkommen: Schalter "Use a separate agent user" an, "Get started".
3. Login-Seite: "Sign in with Claude" → Browser öffnet sich → freigeben. Achte darauf, ob der Token im Fenster NIE erscheint. Falls der Browser nicht aufgeht oder nichts passiert: "Paste token instead" testen (echten Token nicht in den Chat posten).
4. Setup-Seite: ein Passwortdialog von macOS. Beobachte: Bietet er Touch ID an? Wie oft wirst du gefragt (erwartet: einmal)?
5. Der bestehende Account `agentbar` (uid 502) wird übernommen und gehärtet (Shell false, hidden, kein Login). Prüfe, ob dabei Warnungen ("warn") in den Details der Zeile "Agent user" stehen, und schick mir diese.
6. Fertig-Seite: Autostart und Benachrichtigungen schalten, "Done".

## 4. Danach prüfen (Terminal, ohne sudo)
```bash
dscl . -read /Users/agentbar UniqueID UserShell
launchctl print system/com.agentbar.host | grep -E "state|pid|last exit"
ls -ld /Users/Shared/AgentBar /Users/agentbar
tail -5 "/Library/Application Support/AgentBar/setup-status.jsonl" | cut -c1-200
```
Erwartet: uid 502 bleibt (übernommener Account) bzw. 200..399 bei Neuanlage, Shell `/usr/bin/false` (falls die Härtung durchging), `state = running`.

## 5. Chat unter dem Agent-Benutzer
Im Panel "New session", Run as = Agent user, Bot wählen, kurzen Prompt senden. Erwartet: Chip "as agentbar", Antwort kommt. Hier siehst du, ob das Token wirklich funktioniert.

## 6. Nur lokal ohne Admin (Gegenprobe)
Setup erneut öffnen, Schalter "Use a separate agent user" AUS: kein Passwortdialog, Hooks werden eingerichtet, Fertig-Seite.

## 7. Hooks (Claude im Terminal)
In einem Terminal `claude` starten, kurz etwas tun lassen: Taucht die Session in der Bar auf? "Immer erlauben" einmal im Panel testen. Nichts an `~/.claude` manuell ändern.

## 8. Eindruck am Notch (Design)
- Idle-Farbe wärmer (`BarTheme.idleDim` 0,55 → ca. 0,65) und Glow-Ring kräftiger? Sag, ob es dir zu blass ist.
- Maskottchen, Atmen, Schlaf-"z", Aufwach-Hüpfer in Bewegung ansehen.
- Onboarding-Fenster: gefällt dir der Look (Blob, Abstände, Texte)? Was stört?

## 9. Aufräumen, falls nötig
- Account und Daemon entfernen: `sudo Scripts/remove-agent-user.sh --owner "$USER"` (löscht Home inkl. Workspaces nach Bestätigung; vorher `--dry-run` ansehen).

## 10. Im Panel fortsetzen (neu)
In einem Terminal `claude` benutzen, dann im Panel die Session wählen und "Continue in panel" drücken. Erwartet: neue Session "<name> (fork)", Notiz "Forked from …", Antworten auf eine Nachricht. Prüfe, dass die Terminal-Session unverändert bleibt. Falls es nicht klappt: Fehlerblase bzw. Text schicken (`claude --resume` braucht das gleiche Arbeitsverzeichnis).

## Bekannte Lücken (nie real gelaufen)
Admin-Prompt aus der App, Account-Anlage per dscl, Daemon-Start mit Post-Check, Token-Übergabe als `agentbar`, `claude setup-token` im PTY (echte Ausgabe), Autostart/Benachrichtigungen in der ad-hoc-signierten App, Codex-Hooks.
