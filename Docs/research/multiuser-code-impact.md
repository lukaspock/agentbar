# Multi-User-Betrieb: Code-Auswirkungen (Owner + Benutzer `agentbar`)

Stand 2026-11-02, reine Code-Analyse (nichts gebaut, nichts verändert). Ziel: Agents (claude, später codex) laufen unter dem macOS-Benutzer
`agentbar` (eigene Workspaces, kein Zugriff auf Owner-Daten) und werden nur über die AgentBar-App in der Owner-Sitzung gesteuert
(Freigaben, Chat, Stop, neue Session). Alles zu Claude-Code-Verhalten unter einem Fremdbenutzer ist UNVERIFIED.

## 0. Kernidee (empfohlene Architektur)

`ChatSession` bleibt komplett app-seitig (Owner). Es gibt schon die richtige Naht: das Protokoll `ChatProcess` + `ChatProcessFactory`
(`Adapters/ChatSessionProcess.swift`). `PosixChatProcess` wird zur **Host-Seite**, eine neue `RemoteChatProcess` (app-seitig) tunnelt
`start/write/terminate/kill` und `onLine/onStderr/onExit` über eine Verbindung zu einem kleinen **Agent-Host** (`agentbar-host`), der als
`agentbar` läuft und nur ein dummes Rohr ist (spawn, stdin, stdout, stderr, exit). Damit bleiben `renderApproval`, `safeAlwaysRule`,
`chatOwned`, Log-Sanitizing, Idle-Watchdog usw. unverändert beim Owner, und der Host muss nichts "Sicherheitsrelevantes" richtig rendern.

```
Owner-Sitzung                                              Benutzer agentbar (LaunchDaemon UserName=agentbar)
AgentBar.app: SessionStore, TransportServer, ChatSession   agentbar-host  --spawn-->  claude -p stream-json (cwd im Workspace)
   RemoteChatProcess  <== Host-Kanal (Unix-Socket, Gruppe) ==  HostService (PosixChatProcess je Session)
agentbar hook (Terminal-Sessions von agentbar) ----------- gleicher Socket, Rolle "agent" ---------->
```

## 1. Benutzer-Bindung heute und nötige Änderungen

### 1.1 Wo fest verdrahtet

| Stelle | Datei / Symbol | Verdrahtung |
|---|---|---|
| Standardverzeichnis | `Transport/TransportServer.swift` `defaultDirectory` | `~/Library/Application Support/AgentBar` (nur Owner-Home; `~/Library` ist 0700 => `agentbar` kann nicht einmal traversieren) |
| Verzeichnis-Check | `TransportServer.start()` | `lstat`: Verzeichnis, `st_uid == geteuid()`, dann `chmod 0700` |
| Socket-Rechte | `start()` | `umask(0o177)` beim `bind`, danach `chmod 0600` |
| Token | `start()`, `writeTokenFile` | 1 Zufallstoken (32 Byte hex) pro Start, Datei `token` `O_EXCL|O_NOFOLLOW` 0600, `tokenBytes` global, in `stop()` gelöscht |
| Peer-Check | `acceptLoop` | `getpeereid(c) ... peerUid == geteuid()` sonst `close` |
| Token-Prüfung | `process()` | `constantTimeEqual` gegen das eine Token, kein Rollen-Konzept |
| Verzeichnisauflösung App | `App/Sources/App/AppEnvironment.swift` `transportDirectory` | `AGENTBAR_DIR` oder `TransportServer.defaultDirectory` |
| Verzeichnisauflösung CLI | `Sources/agentbar/main.swift` `defaultDir()`, `readToken` | `AGENTBAR_DIR` oder `NSHomeDirectory()+"/Library/Application Support/AgentBar"`; Token wird bei jedem Aufruf neu gelesen (gut für Rotation) |
| Testhost | `Tests/agentbar-testhost/main.swift`, `Tests/e2e.sh` | `--dir`/`AGENTBAR_DIR` |
| Claude-Fundort | `ChatSessionConfig.swift` `locateClaude(home: NSHomeDirectory())` | `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` des Owners |
| Env-Weitergabe | `ChatConfig.defaultPassthrough` + `launchSpec(environment:)` | kopiert HOME/USER/LOGNAME/SHELL/PATH/TMPDIR, `ANTHROPIC_*`, `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`, Proxys aus der **App-Umgebung** |
| Hook-Datei | `Adapters/HookSetup.swift` `defaultSettingsURL`, `Adapters/CodexHookSetup.swift` (Zeile ~24) | `homeDirectoryForCurrentUser/.claude/settings.json` bzw. `.codex/hooks.json` |
| CLI-Pfad | `HookSetup.locateCLI(bundle:)` | im App-Bundle (`Contents/Resources/agentbar`, vom Script `App/Scripts/bundle-cli.sh` dorthin gelegt) |

### 1.2 Änderungen für zwei Benutzer über einen gruppenfähigen Socket

1. **Verzeichnis außerhalb von `~/Library`:** z. B. `/Users/Shared/AgentBar` (Owner = Owner-Benutzer, Gruppe = `agentbar-ipc`, Mode 0750; die Gruppe enthält
   `agentbar`). Der Owner braucht keine Gruppenmitgliedschaft für den Socket, weil er Dateibesitzer ist (spart Re-Login). `TransportServer.defaultDirectory`
   bleibt als Fallback; neues Konfigurationsobjekt statt weiterer Env-Variablen:
   ```swift
   public struct TransportSecurity {
       var directory: URL
       var ownerUid: uid_t            // geteuid()
       var agentUid: uid_t?           // nil = Einzelbenutzer-Modus wie heute
       var sharedGid: gid_t?          // Gruppe für Verzeichnis/Socket/Token.agent
       var dirMode: mode_t = 0o700    // 0o750 im Zwei-Benutzer-Modus
       var socketMode: mode_t = 0o600 // 0o660
       var peerCredentials: (Int32) -> (uid_t, gid_t)? = getpeereid-Wrapper   // Test-Injektion
   }
   ```
   `init(store:adapters:directory:)` bleibt (Default = bisheriges Verhalten, alle 60+ Tests bleiben gültig); neuer Zusatz-Initializer mit `security:`.
2. **`start()`:** `st_uid == ownerUid`, bei gesetzter Gruppe `st_gid == sharedGid` und Mode-Prüfung "kein World-Zugriff" (`mode & 0o007 == 0`)
   statt hartem `chmod 0700`; `chown(dir, -1, gid)`; Socket nach `bind` `chmod(socketMode)` und `chown(sock, -1, gid)`. `umask(0o177)` bleibt für das
   Bind-Fenster (kein Zeitfenster mit offenen Rechten). Die `alreadyRunning`-Probe und Stale-Cleanup bleiben.
3. **`acceptLoop`:** `peerUid == geteuid()` ersetzen durch Tabelle `[uid_t: PeerRole]` (`.owner`, `.agent`); unbekannte uid => `close`. Rolle pro Verbindung
   in `handle(fd:)`/`process(_:fd:)` durchreichen (neuer Parameter).
4. **Rollenbasierte Autorisierung in `process()`:**
   - `.owner`: wie heute (CLI des Owners, `hook`, `ask`, ...).
   - `.agent`: erlaubt `update|log|end|ask|payload|watch` und `host` (neu), aber **nur für Session-IDs, die nicht Owner-Ursprungs oder `chatOwned` sind**.
     Dafür Seitentabelle `origin[sessionId] = role` im Server (Contract-Dateien `Model.swift`/`Interfaces.swift` sind FROZEN; die Tabelle gehört
     in `TransportServer`, nicht in `AgentSession`). `remove` für Agent-Rolle nur auf eigene IDs. Ohne diese Tabelle könnte ein `agentbar`-Prozess per
     `update --session <fremde-id>` eine Owner-Session umbenennen/beenden (heute verhindert nur die Einzelbenutzer-Annahme das).
   - Bestehende Regeln bleiben rollenunabhängig: `isChatOwned`-Reservierung ("session reserved"), Ablehnung der `log`-Kinds `answer`/`request`
     ("kind not allowed"), Limits (`AgentBarLimits`), Zeilenlimit 64 KiB.
5. **Tokenmodell:**
   - Heute: ein Token, global, bei jedem Start neu. Neu: **ein Token pro Rolle**: `token` (0600, Owner) und `token.agent` (0640 `owner:agentbar-ipc`). Der
     Server hält `tokens: [PeerRole: [UInt8]]`; `process()` vergleicht gegen das Token **der Rolle des Peers** (uid ist die kernel-verifizierte Autorität,
     das Token ist zusätzliche Hürde gegen fremde Prozesse derselben uid, nicht gegen den Agent selbst: Claude läuft als gleicher Benutzer wie der Hook-CLI und
     kann `token.agent` zwangsläufig lesen).
   - "Pro Quelle": zusätzlich `host`-Token (nur für den Host-Kanal) denkbar, bringt aber nur etwas, wenn Host und Agent verschiedene uids haben
     (Härtungsoption: Host als `_agentbar-host`, claude via Wechsel auf `agentbar`; Aufwand hoch, nicht für v1).
   - Rotation: Bei jedem Start neu (existiert). Zusätzlich `rotateTokens()`: neue Datei per `temp + rename` schreiben (atomar, `O_EXCL|O_NOFOLLOW`
     wie `writeTokenFile`), altes Token noch ~60 s gültig (Set mit Ablaufzeit), weil der CLI das Token pro Aufruf neu liest und nur lang laufende
     Verbindungen (`watch`, Host) einmal authentifizieren. Aufruf z. B. aus Menü "Zugang erneuern" und bei Host-Reconnect.
   - `stop()` löscht beide Dateien (heute nur `token`). Reihenfolge Socket vor Token behalten.
6. **Clients:** `main.swift` `defaultDir()`: Reihenfolge `AGENTBAR_DIR`, dann Konfigdatei (`/Users/Shared/AgentBar` falls Verzeichnis existiert und
   `token.agent` lesbar), dann bisheriger Pfad. `readToken` liest `token.agent` falls `token` fehlt/nicht lesbar. Alternativ Hook-Command mit
   `AGENTBAR_DIR=... ` Präfix (siehe 3). Kein Fail-Closed-Risiko: unerreichbar => stiller Exit 3 => Claude zeigt eigenen Dialog (Safety-Default bleibt).
7. **App:** `AppEnvironment.transportDirectory`/`startTransport()` bauen `TransportSecurity` aus Einstellungen (UserDefaults `AgentUserEnabled`,
   erkannter `agentbar`-uid via `getpwnam("agentbar")`, Gruppe via `getgrnam`). Menüzeile mit Status.

## 2. ChatSession / PosixChatProcess und Agent-Host

### 2.1 Wie claude heute startet
`LiveChatBackend.startSession(directory:)` -> `ChatConfig.locateClaude()` (Owner-Home) -> `ChatSession(config:store:)`.
`ChatSession.start()`: `store.markChatOwned(id)`, `config.launchSpec(environment: ProcessInfo.processInfo.environment)` (validiert Executable, cwd existiert
und ist nicht `/`, baut Args `-p --input-format stream-json --output-format stream-json --verbose [--model/--max-budget-usd/--tools/--permission-mode]`,
Env = nur Allowlist `defaultPassthrough` + `extraEnvironment`), `PosixChatProcess` (Foundation `Process`, kein Shell, argv, eigene Pipes, stdout-Zeilen bis
1 MiB, Exit erst nach stdout-EOF oder 1 s Force). `permissionMode` bietet bewusst kein `bypassPermissions/auto`. Stop: `terminate()` (SIGTERM, Pipe zu),
Kill nach `killGrace` (2 s). Bekannte Lücke: `kill` trifft nur claude, nicht dessen Kindprozesse (gleiche Prozessgruppe, aber kein `killpg`).

### 2.2 Aufteilung host-seitig vs UI/Owner-seitig

| Teil | Seite | Begründung |
|---|---|---|
| `PosixChatProcess` (spawn, Pipes, Zeilenpuffer, Exit-Logik) | **Host** (unverändert wiederverwendbar) | braucht uid `agentbar` |
| Aufbau von `ChatLaunchSpec` (Executable-Pfad, cwd, Env, Args) | **Host** (Args aus strukturierten Feldern, Whitelist) | Pfade/Home gehören dem Agent-Benutzer; Env darf kein Owner-HOME/Secrets enthalten |
| Workspace-Wurzel, Pfad-Containment (`realpath` darf `Workspaces/` nicht verlassen), Anlegen/Listen | **Host** | Owner darf Agent-Home nicht lesen |
| Prozessgruppe + `killpg`, Dead-Man (Verbindung weg => SIGTERM/SIGKILL aller Kinder) | **Host** | Owner kann Fremd-uid-Prozesse nicht signalisieren |
| `ChatWire.parse/encode`, `handle(line:)`, `handlePermission`, `handleQuestion`, `safeAlwaysRule`, `answered`, `denyAllPending` | **Owner (ChatSession)** | Sicherheitsregeln, Rendering |
| `ClaudeCodeAdapter.renderApproval`, `clean`, Truncation-Regel "nie kürzen, kein Allow" | **Owner** | Anzeige muss aus dem Owner-Prozess stammen, nie vom Host/Agent |
| `markChatOwned/unmarkChatOwned`, Store-Events, History-Einträge `answer` ("You: ") | **Owner** | Fälschungsschutz |
| Idle-Watchdog (`startWatchdog`), `stop()`-Phasen, `scheduleKill` | Owner (Entscheidung), Host führt `terminate`/`kill` aus | |
| `ChatConfig.locateClaude` | Host (liefert Pfad zurück) | |

Konsequenz: Die Datei `ChatSession.swift` ändert sich fast nicht. Anpassungen: (a) `ChatConfig.launchSpec` braucht einen Remote-Modus ohne lokale
`FileManager`-Prüfungen und ohne Owner-Env (neues Feld `ChatConfig.location` / `ChatLaunchSpec.target`; Env = `[:]`, Host ergänzt); (b) `start()` muss
einen asynchron scheiternden Spawn verkraften (siehe Spawn-Ergebnis unten); (c) `init`-Default `environment: ProcessInfo...` im Remote-Fall irrelevant.

### 2.3 Schnittstelle (Swift)

```swift
// Owner-seitig
public enum ExecutionTarget: Sendable, Equatable { case thisUser; case agentUser(host: String /* id des Host */) }
public protocol AgentHostLink: AnyObject, Sendable {           // Verbindung zum Host (RemoteHostClient)
    var isConnected: Bool { get }
    func spawn(_ req: HostSpawnRequest, ...) -> ChatProcess      // = RemoteChatProcess (start/write/terminate/kill)
    func listWorkspaces(completion:)  func createWorkspace(name:completion:)
}
public struct HostSpawnRequest: Codable { id, agent: "claude"|"codex", workspace: String /* Name oder relativer Pfad */,
    model?, maxBudgetUSD?, tools?, permissionMode? }           // KEIN Executable, KEIN Env, KEIN absoluter Pfad
```
`RemoteChatProcess: ChatProcess` hält die Session-ID, schickt `spawn` beim `start`, mappt `write(line:)` -> `stdin`, `terminate` -> `terminate`,
`kill` -> `kill`, und ruft die drei Callbacks aus eingehenden Host-Frames. `ChatProcessFactory` für Remote wird in `LiveChatBackend` gebaut
(`ChatSession(config:store:processFactory:)` hat den Parameter bereits).

**Spawn-Ergebnis:** `ChatProcess.start` ist synchron/throws. Remote: `start` kehrt sofort zurück; Fehler kommen als Frame `spawnFailed` und werden als
`onStderr(text)` + `onExit(127)` geliefert => `ChatSession.handleExit` loggt "claude exited with 127: <text>" (bestehender Pfad). Kein API-Bruch.

### 2.4 Wire-Protokoll (Ops) und Transport-Wiederverwendung

Der bestehende Transport ist "eine Anfrage pro Verbindung" plus der halb-duplex `watch`. Der Host-Kanal braucht eine **voll-duplexe, langlebige** Verbindung:
neues Op `host` (nur Rolle `.agent`), danach Zeilen-JSON in beide Richtungen. Das ist die einzige Erweiterung des Transports (neuer Zweig neben
`processWatch` in `TransportServer.process`, vermutlich in eigener Datei `HostChannel.swift` als Extension). Zeilenlimit für diesen Kanal getrennt anheben
(stdout-Zeilen bis 1 MiB `ChatWire.maxLineBytes`; globales Limit 64 KiB `AgentBarLimits.maxLineBytes` gilt weiter für alle anderen Ops). Alternative:
Host lauscht selbst auf einem zweiten Socket (App verbindet sich); verworfen, weil dann zwei Sockets/Rechtepfade + Gruppen in beide Richtungen nötig wären und der Hook-Pfad den
App-Socket ohnehin freigeben muss.

Handshake (Host -> App): `{"token","op":"host","protocol":1,"user":"agentbar","uid":599,"workspaceRoot":"/Users/agentbar/Workspaces","agents":{"claude":"2.1.x","codex":null}}`
=> `{"ok":true,"event":"ready","maxLine":1048576}`. Danach:

App -> Host:
- `{"op":"spawn","id":"chat-ab12cd34","agent":"claude","workspace":"projekt-x","model":..,"maxBudgetUSD":..,"tools":[..],"permissionMode":".."}`
- `{"op":"stdin","id":..,"line":"<eine JSON-Zeile als String>"}`
- `{"op":"terminate","id":..}` (SIGTERM an Prozessgruppe), `{"op":"kill","id":..}` (SIGKILL Gruppe)
- `{"op":"workspaces"}`, `{"op":"mkworkspace","name":"projekt-x"}`, `{"op":"hookplan"|"hookapply", ...}` (siehe 3), `{"op":"ping"}`

Host -> App:
- `{"ev":"spawned","id":..,"pid":..}` / `{"ev":"spawnFailed","id":..,"error":".."}`
- `{"ev":"stdout","id":..,"line":".."}`, `{"ev":"stderr","id":..,"b64":".."}`, `{"ev":"exit","id":..,"status":N}` (exakt einmal, nach stdout-Ende)
- `{"ev":"workspaces","items":[{"name":..,"mtime":..}]}`, `{"ev":"pong"}`, `{"ev":"error","id":..,"error":..}`

Regeln: IDs werden **nur von der App vergeben** (`chat-…`); der Host kann keine Session erzeugen und keine Events für fremde IDs einschleusen (App verwirft
Frames mit unbekannter ID). Host-Kanal darf keine Store-Ops (`update/log/ask`) ausführen; die Roh-Zeilen laufen ausschließlich durch `ChatSession.handle(line:)`
(Parser + `clean`). Backpressure: stdin klein; stdout-Weitergabe blockiert nicht den Host-Lesethread (Queue mit Obergrenze, bei Überlauf Session beenden).
Verbindungsabriss: App behandelt alle Remote-Sessions des Hosts als `onExit(…)` mit Fehler "agent host disconnected"; Host beendet bei Abriss alle Kinder
(Grace 2 s, dann Kill), sonst entstehen unbeobachtete Prozesse. v1: kein Re-Attach nach App-Neustart.

### 2.5 Sicherheitsregeln, die bestehen bleiben müssen
- `renderApproval` und die Nicht-kürzen-Regel laufen weiter im Owner-Prozess; Host liefert nur Roh-JSON. Nie "Anzeigetext" vom Host übernehmen.
- `chatOwned`: `markChatOwned` vor Spawn; `TransportServer.process()` lehnt `update/log/end/remove/ask` und `payload` auf diesen IDs ab (bleibt, jetzt auch
  für Agent-Rolle wichtig, weil `agentbar`-Prozesse ID `chat-…` raten könnten); `SessionStore.remove` stoppt Chat vor dem Entfernen (ruft `stopHandler` -> Remote `terminate`).
- Forged log kinds: `log`-Op verbietet `answer`/`request`; GenericCLI/ComputerUse-Adapter ignorieren sie ebenfalls. Der Host-Kanal hat gar kein `log`.
- Timeout/Cancel/unbekannte Option => deny (nie allow): unverändert, weil `ChatSession.answered` unverändert.
- Ehrliche Grenze: Der Host läuft mit derselben uid wie claude. Ein kompromittierter Agent kann den Host manipulieren; die Freigabe-UI ist keine Barriere gegen
  Code, der bereits als `agentbar` läuft. Die Barriere ist die OS-Trennung (Owner-Daten unlesbar), nicht die Approval-Karte.

## 3. Hooks (ClaudeCodeAdapter / HookSetup)

Heute: `HookSetup` (pure Logik, `settingsURL` ist Parameter) schreibt `~/.claude/settings.json` des laufenden Benutzers; `command()` verlangt absoluten Pfad,
`lastPathComponent == "agentbar"`, escaped Shell-Metazeichen und produziert `<pfad> hook --adapter claudeCode`; Erkennung eigener Einträge über Teilstring `agentbar hook`.
`HookSetupMenu`/`CodexHookSetupMenu` zeigen Diff-Vorschau (`informativeText` hartkodiert "~/.claude/settings.json"), Backup, Bestätigung, `apply` mit
"changedOnDisk"-Prüfung. Die App darf `/Users/agentbar/.claude` nicht schreiben.

Änderungen:
1. **Wer schreibt:** der Host (als `agentbar`) führt `HookSetup(settingsURL: <agent-home>/.claude/settings.json, agentbarPath: <cli>)` aus. Zwei Ops
   `hookplan` -> Antwort mit `original` (Base64 oder Hash), `proposed`, `summary`, `preview`; `hookapply{expectedOriginalHash, proposedBase64}` -> Host prüft,
   dass die Datei noch `original` entspricht (bestehende `changedOnDisk`-Logik), Backup, atomar schreiben. **Bestätigungsdialog bleibt in der App** (Owner
   sieht Pfad `/Users/agentbar/.claude/settings.json` und Diff). `apply(_:confirm:)` ist bereits von der Dateiebene getrennt; `Plan` muss `Codable` werden
   oder der Host sendet die Einzelteile. Gleiches für `CodexHookSetup`.
2. **CLI-Pfad für `agentbar` lesbar/ausführbar:** `locateCLI` liefert den Pfad im Owner-Bundle. Liegt die App in `/Applications` (0755), kann `agentbar` ihn
   ausführen; liegt sie unter `~/...` oder DerivedData, nicht (Home 0700). Empfehlung: bei "Agent-Benutzer einrichten" das CLI nach
   `/usr/local/bin/agentbar` oder `/Library/Application Support/AgentBar/bin/agentbar` kopieren (root-eigen, 0755, signiert; braucht Admin einmalig, im
   Setup-Script). `HookSetup.command()` bleibt gültig (Name `agentbar`, absoluter Pfad). Versionsabgleich: CLI schickt `protocol`-Nummer im Request (neues optionales Feld);
   App meldet Mismatch im Menü. Die ROADMAP-Idee "Kopie nach `~/Library/Application Support/AgentBar/bin`" (offener Punkt 4) wird dadurch ersetzt.
3. **Verzeichnisfindung im Hook-Aufruf:** entweder `HookSetup.command()` erhält optionales `environment: [String:String]` und erzeugt
   `AGENTBAR_DIR=/Users/Shared/AgentBar /usr/local/bin/agentbar hook --adapter claudeCode` (Marker `agentbar hook` bleibt enthalten, Escaping der
   Werte wie beim Pfad prüfen, `isOurs` greift weiter) oder der CLI nutzt den Fallback aus 1.2 (6). Letzteres ist wartungsärmer (Hook-Zeilen ändern sich nicht).
4. **Timeouts:** PermissionRequest-Timeout 600 s in `HookSetup.entries` und 130 s im CLI bleiben; keine Änderung nötig.
5. **Chat-Prozess und Hooks:** Der vom Host gestartete claude liest `~agentbar/.claude/settings.json`. Sind dort AgentBar-Hooks eingetragen, fragt ein Chat-Tool-Call
   evtl. doppelt (Hook-Session-ID ist Claudes UUID, nicht `chat-…`, `chatOwned` greift also nicht): offene Frage laut `chat-input.md`. Lösung: Host startet claude
   mit `--settings`/`CLAUDE_CONFIG_DIR` auf ein eigenes Chat-Profil ohne AgentBar-Hooks (UNVERIFIED, Verhalten testen).

## 4. UI-Änderungen

| Datei | Änderung |
|---|---|
| `UI/ChatBackend.swift` | `ChatBackend.startSession(directory:completion:)` -> `startSession(_ request: NewSessionRequest, completion:)` mit `target: ExecutionTarget`, `workspace: WorkspaceChoice` (`.localDirectory(URL)` / `.agentWorkspace(name)` / `.newAgentWorkspace(name)`); `NewChatFlow.run()` wird von `NSOpenPanel`-only zu einem Dialog (NSAlert mit Accessory oder eigenes Panel): Segment/Popup "Ausführen als: Dieser Benutzer (<name>) \| agentbar (isoliert)"; bei "agentbar" statt `NSOpenPanel` Popup mit Workspaces vom Host + "Neuer Workspace…" (Namensfeld, validiert `[A-Za-z0-9._-]{1,60}`). Deaktiviert mit Grund, wenn Host nicht verbunden. `FakeChatBackend` anpassen (Demo). |
| `App/LiveChatBackend.swift` | Wahl der `processFactory`: lokal `PosixChatProcess.factory`, remote `RemoteHostClient.factory`; `locateClaude` nur lokal; Seitentabelle `target[sessionId]`; Fehlermeldung "Agent-Host nicht verbunden". |
| `UI/DetailPanel.swift` | `ChatPanel`-Header: "Chat · name · läuft als agentbar" (vom UI aus vertrauenswürdiger Herkunft gezeichnet, **nie** aus Agent-Text); Session-Zeile mit kleinem Schloss-Chip "agentbar"; Freigabekarte: Herkunftszeile außerhalb des monospaced Approval-Textes. Footer `NewSessionButton` unverändert. |
| `UI/ChatBackend.swift` (`ChatHub`) | `func location(of session:) -> ExecutionTarget`; v1 Seitentabelle in der App. Für Hook-Sessions der Agent-Rolle könnte der Server die Herkunft kennen (Rolle pro Verbindung): additives Feld `AgentSession.runsAs: String?` wäre eine Änderung im FROZEN `Contract/Model.swift` (Koordinator; additiv mit Default kompatibel) und würde die Seitentabelle ersetzen. |
| `App/MenuBarController.swift` | Menü "Agent-Benutzer…" (Status: Host verbunden/getrennt, uid/Name, CLI-Version, Hooks im Agent-Home ja/nein, "Zugang erneuern", "Alle Agent-Prozesse stoppen"); "New chat session…" öffnet den neuen Dialog. |
| `Setup/` (neu `AgentUserSetupMenu.swift`) | zeigt Setup-Anleitung/Script-Pfad, Hook-Plan für Agent-Home (siehe 3.1). |
| `App/AppEnvironment.swift` | `TransportSecurity` aufbauen, Host-Link und Status veröffentlichen (`@Published`). |
| `UI/Preview/FakeSessionStore.swift` | Demo-Zustände "agentbar-Session" für Screenshots. |

Workspace-Auswahl im Agent-Home: Owner kann `/Users/agentbar` nicht durchsuchen (0700) => Liste und Anlegen laufen ausschließlich über den Host (`workspaces`,
`mkworkspace`). Optional später: `clone <url>`, `import` (Kopie eines Owner-Ordners via `ditto` durch Admin-Hilfsskript; bewusste Owner-Aktion). Ergebnisse
lesen: Workspace-Wurzel Gruppe `agentbar-ipc` mit Mode 0750 und Host-`umask 027`, damit der Owner (nach Gruppenaufnahme + Re-Login) lesen kann; Schreibzugriff nein.

## 5. Teststrategie ohne zweiten echten Benutzer

Automatisiert (im Package, `swift test`):
- **Fake-Peer-UID:** `TransportSecurity.peerCredentials` injizierbar. Test A: `ownerUid = geteuid()+1`, `agentUid = nil` => Verbindung des Testprozesses wird geschlossen (alter
  Test `uid mismatch`). Test B: `ownerUid = geteuid()+1`, `agentUid = geteuid()` => Rolle `.agent`: `update/ask/payload` auf Agent-eigenen IDs ok, auf
  Owner-Session-ID und `chatOwned`-ID => `session reserved`/`forbidden`; `host` ok; mit `token` (Owner) statt `token.agent` => `unauthorized`. Test C: injizierte Funktion
  liefert wechselnde uids, Rollenmatrix je Op (Tabelle).
- **Zwei Sockets/Verzeichnisse:** nur nötig für Regression "Einzelbenutzer-Default unverändert" (bestehende `TransportTests` unverändert grün).
- **Modi/Gruppe:** Test mit der eigenen Primärgruppe (`getgid()`): Verzeichnis 0750/Gruppe, Socket 0660, `token.agent` 0640, `token` 0600, Verzeichnis ohne World-Bits;
  `stop()` löscht beide Tokens; Rotation: altes Token nach Grace ungültig, neues gültig, laufende `watch`-Verbindung bleibt.
- **Host-Protokoll:** `HostService` (Host-Seite, nimmt `ChatProcessFactory`) und `RemoteHostClient` über `socketpair(AF_UNIX)` im selben Prozess. Fake-Prozess aus
  `ChatSessionTests` und echtes `/bin/cat` (wie dort) liefern: spawn/stdin/stdout/stderr/exit, Spawn-Fehler => Exit 127 + stderr, Verbindungsabriss => Kinder beendet, fremde
  IDs verworfen, Zeile >1 MiB, Stop während Prompt (deny + SIGTERM -> Kill-Grace), Pfad-Containment (`../`, Symlink aus dem Workspace heraus, absolute Pfade, `/`).
  Ende-zu-Ende: `ChatSession` + `RemoteChatProcess` ⇄ socketpair ⇄ `HostService` + `PosixChatProcess` mit Shell-Skript als "claude" (Stream-JSON-Fixtures).
- **Env-Test:** Host-Env enthält weder Owner-HOME noch `ANTHROPIC_API_KEY` der App (Spy auf `ChatLaunchSpec.environment`).
- **Hooks:** `HookSetup(settingsURL: temp/.claude/settings.json, agentbarPath: ...)`-Tests existieren bereits parametrisch; neu: `hookplan/hookapply`-Roundtrip,
  `changedOnDisk` bei Änderung zwischen Plan und Apply, Env-Präfix im Command (falls gewählt) inkl. `isOurs`.
- `Tests/e2e.sh` + `agentbar-testhost`: Parameter `--agent-uid-mode` (Fake-Peer) für einen Shell-E2E des CLI mit `token.agent`.

Nur manuell prüfbar: echter zweiter Benutzer (Anlegen via `sysadminctl`/`dscl`, versteckt, ohne Login-Shell-Zugang für GUI), dass `agentbar` weder `/Users/<owner>`
noch den Socket ohne Gruppenmitgliedschaft öffnen kann (`sudo -u agentbar ls`, `nc -U`), `connect()`-Verhalten mit Gruppenrechten auf macOS, LaunchDaemon-Start mit `UserName`,
`claude login` bzw. Credential-Ablage als `agentbar` (Keychain ohne GUI-Sitzung, UNVERIFIED), echte Claude-Hooks im Agent-Home, `getpeereid`-Werte über den realen uid-Wechsel,
Prozessgruppen-Kill echter Tool-Kindprozesse, Verhalten bei Fast-User-Switching/Sperrbildschirm/Ruhezustand, Gruppenänderung wirkt erst nach Neustart des betroffenen Prozesses/Re-Login,
Gatekeeper/Quarantäne der kopierten Binaries.

## 6. Risiken / Bruchstellen

1. **`~/Library` ist 0700**: Socket muss nach `/Users/Shared/AgentBar`; alle Pfadannahmen (CLI, App, Testhost, Docs, `e2e.sh`) prüfen; Socketpfadlänge (~104) beachten.
2. **Fremdbenutzer-Signale unmöglich**: Owner kann Agent-Prozesse nicht killen. Stop hängt am Host; ohne Dead-Man im Host bleiben Prozesse bei App-Absturz laufen. Zusätzlich Admin-Notaus (`sudo pkill -u agentbar`, im Setup-Script/Menü als Kommando anzeigen).
3. **Claude-Credentials als `agentbar`**: Keychain im Daemon-Kontext nicht gesichert; Fallback API-Key/`CLAUDE_CODE_OAUTH_TOKEN` in 0600-Datei im Agent-Home, vom Host eingefügt (kein Owner-Secret durchreichen; `defaultPassthrough` im Remote-Modus komplett leer).
4. **Gleiche uid für Host und Agent**: kompromittierter Agent kann Host-Binary/Konfig verändern, wenn schreibbar => Host-Binary root-eigen (`/usr/local/libexec/agentbar-host`, 0755), Konfig root-eigen, Workspaces getrennt vom Host-Code.
5. **Token-Vertraulichkeit**: `token.agent` ist für den Agent lesbar (unvermeidbar). Schutz = uid-Check + Rollenrechte + Quoten (`maxConnections`, `maxPendingRequests` global teilen sich Owner und Agent: ein spammender Agent kann Owner-Fragen verdrängen => Quoten pro Rolle).
6. **Session-ID-Kollision/Übernahme** zwischen Rollen (siehe 1.2 (4)); `remove`-Semantik ("later event re-creates session") erlaubt dem Agent, entfernte Zeilen wieder aufzumachen: Rolle-Tabelle behalten.
7. **Frozen Contracts** (`Contract/Model.swift`, `Interfaces.swift`): Rollen-/Herkunftsfeld nur additiv und über den Koordinator.
8. **Transport-Umbau**: neues langlebiges Duplex-Op im Thread-pro-Verbindung-Modell (`handle` -> `readLine` -> `drain`); `process` liefert heute genau eine Antwort. `host` muss die Verbindung selbst besitzen (wie `watch`, "returns nil"), Lese-/Schreibthread trennen, Shutdown in `stop()` (Connections-Set beachten), `readDeadline` 15 s gilt nur für die erste Zeile.
9. **Asynchroner Spawn** gegenüber synchronem `ChatSession.start()` (siehe 2.3); `phase`-Übergänge und "failed to start"-Pfad testen.
10. **Prozessgruppen**: `Process` kann kein `setpgid`; Host auf `posix_spawn` (`POSIX_SPAWN_SETSID`/`SETPGROUP`) umstellen => `PosixChatProcess` bekommt Spawn-Variante, bestehende Tests mit `/bin/cat` weiter nutzen.
11. **Doppel-Freigabe** durch Hooks im Agent-Home (3.5), **Version-Skew** App/CLI/Host (Protokollnummer, Menü-Warnung).
12. **Setup braucht Admin** (Benutzer, Gruppe, LaunchDaemon-Plist, Binaries nach `/usr/local`): kann die App nicht still erledigen; Script `Scripts/setup-agent-user.sh` zum manuellen Ausführen (Prohibited-Aktionen: keine Systemänderung durch den Agent). Entfernen/Rollback-Script mitliefern.
13. **Dateirechte der Ergebnisse** (umask, Gruppe) und Git-"dubious ownership", wenn Owner im Workspace arbeitet.
14. **Codex später**: anderes stdio-Protokoll; Host bleibt ein Rohr mit Executable-Tabelle `agent -> Pfad` (kein Pfad vom Owner), `ChatSession` wird pro Agent in ein Protokoll-Modul (`ChatWire` je Agent) aufgeteilt; `CodexHookSetup` über dieselben Host-Ops `hookplan/hookapply`.
15. **Ruhezustand/Reconnect**: Host-Reconnect-Schleife mit Backoff, App zeigt "getrennt"; offene Prompts werden bei Abriss als deny/cancel abgeschlossen (existierende Pfade).

## 7. Arbeitspakete (disjunkte Dateien) und Reihenfolge

Parallel nur dort, wo die Dateimengen disjunkt sind; Contract-Dateien nur Koordinator.

| Paket | Inhalt | Dateien (exklusiv) | hängt ab von |
|---|---|---|---|
| **P0 Koordinator** | Protokoll- und Rollenspezifikation festschreiben (diese Datei -> CONTRACTS.md Abschnitt "Phase 4"), additive Contract-Änderungen (`runsAs`, falls gewünscht) | `CONTRACTS.md`, `ROADMAP.md`, `Contract/*` | - |
| **P1 Transport-Sicherheit** | `TransportSecurity`, Rollen, Gruppenrechte, Tokens pro Rolle, Rotation, Session-Herkunftstabelle, Quoten pro Rolle | `Transport/TransportServer.swift`, `Transport/SocketIO.swift` (+ neu `Transport/PeerRole.swift`), `Store/Limits.swift`, Tests `TransportTests.swift`, neu `MultiUserTransportTests.swift` | P0 |
| **P2 CLI** | `defaultDir`-Fallback, `token.agent`, Protokollnummer, Env | `Sources/agentbar/main.swift`, `Tests/e2e.sh`, `Tests/agentbar-testhost/main.swift` | P1 (Dateinamen/Pfade) |
| **P3 Host-Kern** | `HostService`, Frames (Codable), Workspace-Containment, Env-Bau, Dead-Man, `posix_spawn`+Prozessgruppen | neu `Sources/AgentBarCore/Host/*`, neu Target `Sources/agentbar-host/main.swift`, `Package.swift`, `Adapters/ChatSessionProcess.swift` (Spawn-Variante), Tests `HostServiceTests.swift` | P0 (Frames) |
| **P4 Host-Kanal im Server + Remote-Prozess** | Op `host` (Duplex), `RemoteHostClient`, `RemoteChatProcess`, `ChatConfig` Remote-Modus (`launchSpec`), Anpassungen `ChatSession.start` für Async-Fail | neu `Transport/HostChannel.swift`, neu `Adapters/RemoteChatProcess.swift`, `Adapters/ChatSessionConfig.swift`, `Adapters/ChatSession.swift`; Teile von `TransportServer.swift` => **nach P1 seriell**, nicht parallel | P1, P3 |
| **P5 Hooks** | `hookplan/hookapply` (Host-Seite + Codable Plan), Env/Dir im Command oder CLI-Fallback, Codex-Pendant | `Adapters/HookSetup.swift`, `Adapters/CodexHookSetup.swift`, `Setup/HookSetupMenu.swift`, `Setup/CodexHookSetupMenu.swift`, Hook-Tests | P3 (Ops), unabhängig von P4 |
| **P6 UI** | Neuer Session-Dialog, Ziel-/Workspace-Auswahl, "läuft als agentbar", Menüeintrag, Status | `UI/ChatBackend.swift`, `UI/DetailPanel.swift`, `UI/Theme.swift`, `UI/Preview/FakeSessionStore.swift`, `App/LiveChatBackend.swift`, `App/MenuBarController.swift`, `App/AppEnvironment.swift`, neu `Setup/AgentUserSetupMenu.swift` | Schnittstellen aus P0/P4 (kann gegen `FakeChatBackend` parallel starten) |
| **P7 Installation** | `Scripts/setup-agent-user.sh` + Rollback, LaunchDaemon-Plist, CLI/Host-Kopie, Gruppe, Doku | `App/Scripts/*`, neu `Scripts/`, `App/project.yml` (Bundle-Schritt für Host-Binary) | P3 |
| **P8 Integration/Review** | Zusammenführen, Build ohne Warnungen, Regression, manuelle Checkliste mit echtem Benutzer, Docs-Update | `CONTRACTS.md`, `ROADMAP.md`, `Docs/research/e2e-multiuser.md` | alle |

Reihenfolge: P0 -> (P1 ‖ P3 ‖ P6-gegen-Fake ‖ P7-Entwurf) -> P2 + P4 + P5 -> P6-Verdrahtung -> P8. Minimaler erster Nutzen (MVP): P1 + P2 (Hooks/`agentbar`-Terminal-Sessions
über Gruppen-Socket mit Rollen) ohne Host, danach P3/P4 für Chat-Sessions im Agent-Benutzer.

Offene Produktentscheidungen für den User: (a) Socket-Ort `/Users/Shared/AgentBar` ok? (b) Owner soll Agent-Workspaces lesen können (Gruppe) oder nur über die App? (c) Host-Neustart/Re-Attach nach App-Neustart gewünscht? (d) Credentials des Agent-Benutzers: eigener Login oder API-Key-Datei? (e) Admin-Setup per Script akzeptabel?
