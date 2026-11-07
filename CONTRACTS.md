# AgentBar ("Agent Companion") – Contracts

Product: tiny always-on bar for all AI agents. Circle when idle (grey calm / soft pulse working / accent = needs user),
hover → small panel (requests, Allow/Deny/Always, reply field, short history), collapses ~0.5 s after hover ends.
Swift 5.9, SwiftUI + AppKit, macOS 14, LSUIElement, XcodeGen, non-activating NSPanel above the menu bar, never steals focus.
Code, comments, names in English. Pure black, SF font, springs response ~0.45 / damping ~0.86.
Separate from the existing `../Notchy` project; do not touch `../Notchy`.

## Layout (root: <repo root>)
```
CONTRACTS.md                      coordinator
Docs/research/                    A (research output only)
Packages/AgentBarCore/            SwiftPM package
  Package.swift                   B may add targets/tests/executable `agentbar`; keep platform + product names
  Sources/AgentBarCore/Contract/  FROZEN (coordinator): Model.swift, Interfaces.swift
  Sources/AgentBarCore/Store/     B  (SessionStore: SessionStoreReading + ResponseSink)
  Sources/AgentBarCore/Transport/ B  (UDS server, wire protocol, token, limits)
  Sources/agentbar/               B  (CLI)
  Tests/                          B
App/                              Xcode app (XcodeGen)
  project.yml                     C (owner until integration; D/E only request additions)
  Sources/App/                    C  (AppDelegate, MenuBarController with extension point, wiring)
  Sources/UI/                     C  (circle, panel, presentations, fake-event preview source)
  Sources/Adapters/               D  (ClaudeCodeAdapter)
  Sources/Setup/                  D  (HookSetup: preview + confirmed write, menu item factory)
```
Parallel agents own disjoint paths. Never edit a path you do not own.

## Wire protocol (transport)
- Unix domain socket: `~/Library/Application Support/AgentBar/agentbar.sock` (dir 0700, socket 0600).
- Token: random 32 bytes hex, file `~/Library/Application Support/AgentBar/token` (0600), regenerated at app start.
- Framing: one JSON object per line (UTF-8, `\n`), max 64 KiB per line, max 100 pending requests, text capped to 4000 chars,
  names to 80 chars, options max 6. Violations → `{"ok":false,"error":"..."}` and close.
- Every request carries `"token"`. Wrong/missing token → `{"ok":false,"error":"unauthorized"}`, connection closed, no state change.
- Request ops (field `op`):
  - `update`: `{token, op, session, name?, kind?, state?, action?, supportsStop?}` → `{"ok":true}`
  - `ask`: `{token, op, session, requestId?, type, text, options?:[{id,label,style?}], timeout?, default?}` →
    connection stays open until answered, then `{"ok":true,"requestId":..,"reason":"answered|timeout|cancelled","option":..,"text":..}`.
    On timeout the store answers with `default` if given (reason `timeout`). Client disconnect = cancel.
  - `log`: `{token, op, session, kind, text}` → `{"ok":true}`
  - `end`: `{token, op, session}` → `{"ok":true}`
  - `remove`: `{token, op, session}` → `{"ok":true}` (always ok, also for unknown ids). Deletes the session; its pending asks are answered
    with reason `cancelled` (agent falls back to its own dialog). A later event for the same id re-creates a fresh session.
  - `payload`: `{token, op:"payload", adapter:"claudeCode", payload:<json>}` → adapter translates (used by hooks, which may block
    for an answer; reply is the adapter-encoded answer wrapped as `{"ok":true,"output":"<string>"}`; empty output = no decision).
- Received text is data, never executed.

## CLI `agentbar` (B)
`agentbar update --session ID [--name N] [--kind K] [--state S] [--action TEXT]`
`agentbar ask --session ID --type approval|question|info --text T [--option id:label[:style]]... [--timeout SEC] [--default ID]`
  stdout: JSON answer; exit 0 answered, 2 timeout, 3 app not reachable, 4 unauthorized/invalid.
`agentbar log --session ID --kind K --text T`, `agentbar end --session ID`, `agentbar remove --session ID` (exit 0)
`agentbar hook --adapter claudeCode` reads hook JSON on stdin, sends `payload`, prints `output` on stdout (empty if app unreachable → never blocks the agent).

## Presentation contract
`BarPresentation` (see Interfaces.swift). UI reads `SessionStoreReading`, writes `ResponseSink`. Variants: notch island,
floating pill (Macs without notch), draggable circle. Variant selection by menu item; default = notch if present else pill.

## Safety defaults
Timeout/unreachable → never auto-allow. Approvals default `deny` or "agent's own dialog" (empty adapter output).
Foreign configs (Claude `settings.json`) are written only after the user confirmed a diff preview, with a timestamped backup.

## Test rules
`pkill AgentBar` before each relaunch. Own `-derivedDataPath` per build session (e.g. `/tmp/ab-dd-<owner>`; use the scratchpad if told).
Do not move the mouse unless needed; no controlling other apps; no system changes.

## Phase 1 as built (integration, subagent E)
- App uses the real `SessionStore` unless `--demo*` is given (then `FakeSessionStore`). `TransportServer` starts at launch
  (`AGENTBAR_DIR` overrides the directory, same variable as the CLI) and stops on quit and on SIGTERM/SIGINT.
  Start failure => warning icon + disabled menu line, app keeps running. A second instance (live socket) exits silently
  before touching socket/token. Stale socket/token of a crashed instance are replaced on start.
- CLI is bundled by `App/Scripts/bundle-cli.sh` (XcodeGen post-build script) to `AgentBar.app/Contents/Resources/agentbar`, ad-hoc signed.
- CLI timeouts: connect 5 s; update/log/end and non-PermissionRequest hooks wait max 5 s for the reply (exit 3 / silent);
  `ask --timeout N` waits N+5 s then prints nothing, exit 3; `ask` without timeout waits indefinitely; PermissionRequest hooks 130 s, then silent.
- Store: answering the last pending request sets state `working` immediately. Ended sessions (via `end`) are pruned after 10 min
  or, beyond 20 listed sessions, oldest ended first (`SessionStore.startMaintenance()` runs the prune every 30 s).
- Server rejects peers whose uid differs from ours (getpeereid) in addition to dir 0700 / socket 0600 / token.
- DEBUG only: `--auto-answer <optionId>` answers each pending request 2 s after it appeared.
- Removing agents: `ResponseSink.remove(sessionId:)` (store: cancels pending with `.cancelled`, drops session; idempotent). UI: xmark per row
  (hover, always visible for done/idle/error; working/pending needs a second click "Wirklich?" within 3 s) and footer "Erledigte entfernen".

## Approval display + click safety (security correction, core)
**Approval text** (`ClaudeCodeAdapter.renderApproval`, plain text, shown monospaced/scrollable by the UI):
```
Allow <Tool>?
cwd: <cwd>                       (only if present)
<key>: <value>                   one entry per top-level key of tool_input, keys sorted
  <continuation line>            further lines of a value are indented by 2 spaces
```
- Values: strings as is; numbers/bools/null/nested objects as compact JSON (sorted keys, no escaped slashes). Empty value => `(leer)`.
- Sanitizing: CR/LF/U+2028/2029/NEL are line breaks (max 2 in a row); tabs become spaces; other space separators become " ".
  Single hidden scalars (control, format incl. zero-width/bidi/tag, private-use, unassigned, surrogate, variation selectors, CGJ, Hangul fillers,
  braille blank) become a visible U+FFFD while the base character stays visible. Grapheme-cluster rule: max 3 scalars per cluster; emoji
  sequences (ZWJ, VS16, skin tones, flags, up to 12 scalars) are kept. A cluster with more marks, an enclosing mark, or starting with a mark is
  replaced by one U+FFFD in `clean()` (display-only text). **In approvals this fails closed** (see below): the base character would vanish, so the
  display would differ from the real input.
  The 2-space indentation makes it impossible for a value to forge a `key:` line. Header fields (tool, project, cwd) are single line.
- **Truncation rule: never cut, never summarise.** If the full text would exceed `ClaudeCodeAdapter.maxApprovalText` (= 4000 - 100, measured in
  Characters AND unicode scalars), or any tool/project/cwd/key/value contains a collapsing cluster (reason "unlesbare Zeichen"), or a key is empty/longer than 60, the tool name is empty/longer than 60, or `tool_input` is missing/empty/not an
  object, then NO request is created. `translate` returns only `sessionUpdate(state: needsInput, action: "<tool>: <reason> … [gekürzt, im Terminal prüfen]")`
  plus a status log entry; the transport answers the hook with `{"ok":true,"output":""}` (empty), so Claude Code shows its own dialog.
  The store cap (4000) therefore never shortens an approval text (tested).
- Option ids unchanged: `allow` / `deny` / `always`. Timeout/cancel/unknown => empty output.

**Click guard (UI contract)**
- `RequestOrdering.stable(_:)`: oldest request first (ties by requestId); session state never influences the order. New requests appear at the bottom.
- `ApprovalClickGuard` (value type, UI owns one instance): `observe(order:now:)` on every change of the ordered request ids (new or moved card
  restarts its 0.5 s window), `layoutChanged(now:)` on panel height/expansion changes (disarms all cards for 0.5 s),
  `isArmed(requestId, currentOrder:, now:)` called at click time with the CURRENT order; false for unknown cards, cards whose index changed, or inside
  `settleInterval` (0.5 s). Buttons are disabled/dimmed while not armed. The answer must use the requestId of the drawn card, never "first pending".

## Phase 2: `agentbar run` (GenericCLI) + transport hardening
`agentbar run --session ID [--name N] [--log] -- <cmd> [args...]`
- Starts `<cmd>` (PATH lookup, posix_spawn, signal dispositions reset) with inherited stdin/stderr. Sends `update` (kind `genericCLI`, state
  `working`, action `running: <cmd>`) before the start. Exit code of the CLI = exit code of the command (signal death = 128+n; not found 127,
  not executable 126; usage errors 4).
- End state by exit: 0 => `end` (done) + status log `exit 0`; signal we forwarded (stop) => `end` + status log `stopped (...)`;
  anything else => `update state=error action="exit N"` + error log.
- `--log`: the command's stdout goes through a pipe (it is then NOT a tty for the child), is passed through verbatim, and each non-empty line
  is sent as a `log` entry of kind `action` (max 300 lines per run, 500 chars each). Without `--log` stdout is inherited unchanged.
- Signals: SIGTERM/SIGHUP are forwarded to the child. SIGINT/SIGQUIT are forwarded unless `run` is in the foreground of a tty (then the
  terminal's Ctrl-C already reaches the whole process group; no double signal). `run` itself waits for the child, then exits with its code.
- The app is never required: notifications run on a background queue, each bounded to 5 s; once the app is unreachable, log lines are dropped
  and the command runs undisturbed. Final flush waits at most 8 s.
- `agentbar hook ... --argv JSON` takes the payload from the argument instead of stdin (Codex `notify`).
- `GenericCLIAdapter` (`agentbar hook --adapter genericCLI`, payload `{session,name?,state?,action?,log?:{kind,text}}`): never blocks,
  never creates requests, `state:"done"` ends the session, output is always empty. `request`/`answer` log kinds are ignored (cannot be forged).

Transport changes: listen backlog 1024 (kernel-clamped); the CLI retries a refused connect up to 4 times (50..200 ms) when the socket file exists
(burst load); the server ignores SIGPIPE process-wide (a client dying right after connect used to be able to kill the app via the reply write).
Client disconnect while `ask`/`payload` waits cancels exactly that request (tests: payload disconnect with a second pending request, 20x instant
disconnect, e2e SIGKILL of a hook client).

## Phase 3: stop channel (app -> CLI) and ComputerUse adapter
- Wire op `watch` (`{"token","op":"watch","session":ID}`): long-lived connection. Server replies `{"ok":true,"event":"watching"}`, then one line
  `{"ok":true,"event":"pause"|"resume"|"stop"}` per command the app issues for that session (`SessionStore.pause/resume/stop(sessionId:)`;
  `stop` is also `ResponseSink.stop`). After `stop` the server closes the connection. Commands for unknown sessions are dropped.
  Disconnect unregisters the observer. `SessionStore.addCommandObserver/removeCommandObserver` + `AgentCommand` are the in-process API;
  `stopHandler` is still called on stop. No confirmation anywhere; the history gets a status entry `stop requested`.
- `agentbar run`: sets `supportsStop` true, keeps a watch connection (reconnects every 2 s while the child lives, re-announcing supportsStop).
  stop -> SIGTERM (+SIGCONT) to the child, ends as `stopped (...)`/`end`; pause/resume -> SIGSTOP/SIGCONT, action `paused: <cmd>`.
  supportsStop is reset on end and on error exit (the store also clears it on `end`).
- `agentbar watch --session ID`: prints `pause`/`resume`/`stop` lines, exit 0 after stop, 3 if the app is/gets unreachable. For agents that
  are not wrapped by `run` (computer-use agents run it in the background and obey the lines).
- `ComputerUseAdapter` (`agentbar hook --adapter computerUse`, kind `computerUse`): payload `{session,name?,state?,action?,supportsStop?,log?:{kind,text}}`.
  `action` -> `currentAction` (plain text, <= 300 chars, ClaudeCodeAdapter.clean rules, empty string clears it). Never creates requests (no
  one-click-allow path), `state:"done"` ends the session, output always empty, forged `request`/`answer` logs ignored. Via `update --action` the
  store applies the same sanitizing for sessions of kind `computerUse`.
- Pause is not in the frozen `ResponseSink`; UI can call `SessionStore.pause/resume` directly (state stays unchanged, the agent reports `paused` via action).

## Phase 4: agent user (role model, group socket) - additive, Contract/ untouched
Spec: `Docs/PLAN-agent-user.md`. Stage 1: hooks of `claude` running as another macOS user (`agentbar`) report to the owner's bar.
- **Roles** (`PeerRole`, decided by the kernel-reported peer uid via `getpeereid`, never by request content): `.owner` (uid running AgentBar) and
  `.agent` (uid of the agent user). `TransportSecurity` holds `ownerUid`, `agentUid?`, the shared directory/group/modes, per-role quota and an
  injectable `peerCredentials` (tests use fake uids). Unknown uid => connection closed. `TransportSecurity()` = single-user mode as before.
  `TransportSecurity.detected()` (used by the app) enables two-user mode only if user `agentbar` AND group `agentbar-ipc` exist and no `AGENTBAR_DIR` is set.
- **Sockets**: owner socket unchanged (`~/Library/Application Support/AgentBar/agentbar.sock`, dir 0700, socket 0600, serves `.owner` only).
  Group socket `/Users/Shared/AgentBar/agentbar.sock` (dir 0750 owner:`agentbar-ipc` - group write is refused on purpose, it would let the agent
  swap socket/token; socket 0660 same group; serves `.owner` and `.agent`). Group missing / mode insecure / chown refused => group listener stays off
  (`TransportServer.sharedStatus == .unavailable(reason)`), owner socket unaffected.
- **Tokens per role**: `token` (0600, owner dir, role owner) and `token.agent` (0640 owner:group, shared dir, role agent). A token only opens its own role.
  Written temp+rename. `rotateTokens(grace:)` replaces all tokens; old ones stay valid `grace` s (default 60); connections that already
  authenticated (`watch`) are unaffected. Both files are removed on `stop()` (socket first).
- **Agent role may use**: `update log end remove ask payload watch`; any other op => `{"ok":false,"error":"forbidden"}`. Only on session ids it created
  itself: an id that is chat-owned, was touched by the owner role, or exists in the store without agent origin => `session reserved`. The owner may touch
  any id and thereby takes it over. Side table `SessionOrigins` (transport-internal, FROZEN `AgentSession` untouched).
- **Quotas (agent role)**: 128 connections, 40 sessions (`too many sessions`), 40 pending requests (`too many pending requests`; for hook payloads: no
  decision = agent's own dialog). Global caps stay.
- **Double-approval guard**: `ChatSession` reserves claude's own session id (from `system/init`) as chat-owned while the process lives, so hooks of that
  claude (e.g. via the agent user's `~/.claude/settings.json`) get `session reserved` instead of a second approval.
- **CLI**: endpoint order `AGENTBAR_DIR` > owner dir (`$HOME/Library/Application Support/AgentBar`) if its socket exists > shared dir
  (`AGENTBAR_SHARED_DIR` or `/Users/Shared/AgentBar`) if socket exists and a token file is readable > owner dir (unreachable). Token: `token`, else `token.agent`.

## Phase 5: agent-user host (stage 2, packages P0+P3+P4) - additive, Contract/ untouched
Spec: `Docs/PLAN-agent-user.md`. Chats started from the bar run `claude` as the agent user via `agentbar-host`. The host is a DUMB PIPE: all
security logic (approval rendering, `safeAlwaysRule`, chat-owned reservation incl. claude's own session id, sanitizing, `answered`) stays in the
owner's `ChatSession`. NOT part of this phase: `hookplan`/`hookapply` (hooks through the host), UI, LaunchDaemon/scripts.

**Op `host`** (`TransportSecurity.agentOps` + `TransportServer.process` -> `HostClient.acceptHost`): role `.agent` only (owner => `forbidden`), token of the
agent role as for every op. Long-lived duplex connection; at most ONE host at a time (`host already connected`, a dead link is detected within 20 s).
Handshake, host -> app, one line (`HostHello`):
`{"token","op":"host","protocol":1,"user":"agentbar","uid":N,"workspaceRoot":"/Users/agentbar/work","agents":{"claude":"/path"}}`
Agent account: `agentbar` is resolved by name (`getpwnam`), the UID is never hard-coded. A NEW account is a role account (UID 200..399, shell /usr/bin/false, hidden); an EXISTING account (e.g. uid 502) is adopted without changing its UniqueID and hardened best effort (decision 2026-11-07, see Docs/research/dscl-permission.md). The setup probe accepts uid >= 100, non-admin, with shell /usr/bin/false or no AuthenticationAuthority and password `*`/empty.
=> app replies `{"ok":true,"event":"ready","protocol":1,"maxLine":1048576}` (errors: `unsupported protocol`, `invalid hello`, `host already connected`).
The host must not send frames before `ready`. `user`/`workspaceRoot`/`agents` are display data (control/format characters rejected, bounded); the
identity is the kernel peer uid (`HostClient.Info.uid`). After `ready` both directions are `\n`-separated JSON frames, **max 1 MiB per line for this channel
only** (all other ops keep 64 KiB; oversize => link closed). No store op (`update/log/ask/...`) exists on this channel.

**App -> host** (`HostCommand`, discriminator `op`):
`spawn {id,agent:"claude",workspace,model?,maxBudgetUSD?,tools?,permissionMode?}` (no executable, no env, no absolute path), `stdin {id,line}`,
`terminate {id}` (SIGTERM to the process GROUP + close stdin), `kill {id}` (SIGKILL group), `workspaces {rid}`, `mkworkspace {rid,name}`, `ping`.
**Host -> app** (`HostEvent`, discriminator `ev`): `spawned {id,pid}`, `spawnFailed {id,error}`, `stdout {id,line}`, `stderr {id,b64}`,
`exit {id,status}` (exactly once, after stdout ended; 128+n = signal n), `workspaces {rid,items:[{name,mtime}]}`, `workspaceCreated {rid,name}`,
`pong`, `error {id?,rid?,error}`. Codable types: `Host/HostProtocol.swift`.

**IDs are chosen by the app only** (`RemoteChatProcess.processId`, request ids `rid`). Process ids/rids: `[A-Za-z0-9._-]{1,64}`. The app drops frames for
unknown ids, stdout/stderr/exit before `spawned`, and a second `exit` (`HostClient.droppedFrames`). A duplicate spawn id gets `error{id}` and does not touch the
running process. Max 16 processes (`too many agent processes`). Unknown/malformed frames: `error` event (host) / ignored (app); link stays up.
**Spawn errors** arrive as `spawnFailed`; the app delivers them as `onStderr("<reason>\n")` + `onExit(127)` (existing "claude exited with 127" path).
Only "host not connected" at `start` time throws (`ChatError.spawnFailed`). Host link lost => every remote process gets `onStderr("agent host disconnected")` + `onExit(255)`.

**Workspaces** (`WorkspaceStore`): ONE path component `[A-Za-z0-9][A-Za-z0-9._-]{0,59}` directly below `~/work` of the agent user (from the password database).
`..`, `/`, absolute paths, hidden names and non-ASCII cannot be expressed; additionally lstat (real directory, not a symlink, owned by the host uid),
`realpath == <real root>/<name>`, and the root itself must be a real directory (no symlink). `mkworkspace` creates mode 0700 and refuses existing names.
`workspaces` lists real, owned directories with valid names only (max 500). (Same-uid TOCTOU swaps are out of scope: containment, not a sandbox.)

**Child environment** (`HostEnvironment.build`) is built from scratch, nothing inherited: `HOME USER LOGNAME SHELL PATH LANG TMPDIR` (+ `CLAUDE_CODE_OAUTH_TOKEN`).
Token from `~/.config/agentbar/claude-oauth-token`: regular file, not a symlink, owned by the host uid, no group/world bits, <= 8 KiB, printable ASCII; unsafe
file => the spawn fails (host stays up); missing file => no token (claude falls back to its own credentials). `ANTHROPIC_API_KEY` & co. are never set, so
the token is never combined with an API key. Arguments come from `ChatConfig.launchSpec` (the same whitelist as locally); `permissionMode` has no bypass values.
`TMPDIR` = `~/.agentbar/tmp/` (created 0700).

**Processes**: `PosixChatProcess(spec:newProcessGroup: true)` = `posix_spawn` with `POSIX_SPAWN_SETPGROUP` (child leads its own group), `POSIX_SPAWN_CLOEXEC_DEFAULT`
(no inherited fds), reset signal dispositions/mask; terminate/kill = `killpg`; when the leader exits the rest of the group is SIGKILLed. Default (`false`, used by the app's
local chats) is unchanged Foundation `Process`. `ChatProcess.processIdentifier` added (default 0).
**Dead-man** (`HostService`): the app pings every 5 s, the host answers `pong`. Host side: no bytes for `deadManSeconds` (20 s, clock stops during system sleep) OR EOF/error
=> SIGTERM to all groups, SIGKILL after `killGrace` (2 s), then `run` returns. Deliberate: an EOF kills at once (no re-attach in v1, children would be unobservable and
uncontrollable orphans); the 20 s apply to a link that is silent but not closed. The app side declares the link dead after 20 s without any frame. `HostRunner` reconnects
(backoff 0.5..10 s) and re-reads `token.agent` on every attempt. SIGTERM/SIGINT/SIGHUP of the host terminate all children first.

**`agentbar-host`** (executable target): refuses uid 0; reads only env `AGENTBAR_IPC_DIR` (default `/Users/Shared/AgentBar`; needs `agentbar.sock` + `token.agent`).
**App API** (`TransportServer.hostClient: HostClient`): `state/isConnected/info/onStateChange`, `processFactory` (-> `ChatSession(config: ChatConfig.remote(workspace:workspaceRoot:...),
store:, processFactory:)`), `listWorkspaces`, `createWorkspace`, `terminateAll`, `activeProcessCount`. `ChatConfig.remoteWorkspace` / `ChatLaunchSpec.remote` carry the
structured request; remote `launchSpec` does no local file checks and has an empty environment.

## Phase 7: security hardening of phases 4/5 (2026-11-03) - additive
- **CLI shared-dir fallback** (`Sources/agentbar/SharedEndpointTrust.swift`): the group directory is used only if `lstat` shows: directory (no symlink), group
  `agentbar-ipc`, no group/world write; expected server uid = directory owner (root-owned dir: the socket's owner), and it must NOT be the calling uid
  (the hook runs as the agent user; a dir it owns proves nothing); socket is a real socket with that owner/group and not world-writable (0660 ok);
  `token.agent` is a regular file owned by that uid or root, no group/world write, no world access. Only `token.agent` is read there (never `token`).
  After connect the server uid is verified with `getpeereid` == expected uid, else the connection is dropped (exit 3). `AGENTBAR_DIR` (explicit) and the
  owner's own directory are unchanged. Test-only switch `AGENTBAR_TRUST_TEST=1` (e2e with fake uids): self-owned dir and primary group allowed.
- **Alias reservation** (`ChatSession`): the claude session id from `system/init` (agent output) is reserved only if it matches `[A-Za-z0-9_:.-]{1,maxIdLength}`
  and the store does not already know a session with that id (and it is not already chat-owned). A forged init line therefore cannot lock out a foreign hook session.
- **Host binary check** (`TransportSecurity.hostBinary`, `HostBinaryPolicy`): `op: host` additionally requires that the peer process (pid via `LOCAL_PEERPID`,
  path via `proc_pidpath`, realpath-compared) is `/usr/local/libexec/agentbar/agentbar-host`, and that this file and its directory are root-owned and not
  group/world writable. Otherwise `forbidden`. Secure by default (`TransportSecurity.init` default `.standard`); tests inject `.disabled` or fake pid/path.
  No wire change: an already installed host binary at that path keeps working with a new app (and vice versa).
- **Dead host replacement** (`HostClient.serve`): a second authenticated, path-checked host pings the registered one; if no frame arrives within 2 s
  (`takeoverProbe`) or the link is already gone, the old link is shut down and the newcomer takes over (its processes get the usual `disconnected`). A
  host that answers is never displaced (`host already connected`).
- **Residual risk (documented, not solved):** host and agent run under the SAME macOS uid. Any process of the agent user can read `token.agent`, kill or
  restart the real `agentbar-host` (then connect in the gap), start the real binary with an injected library (`DYLD_INSERT_LIBRARIES`) or attach a debugger.
  The path check stops casual impersonation (scripts, copied binaries) only. Impact: such a process receives the lines the app sends to the "host"
  (user prompts, approvals results) and can feed forged stdout to the app's `ChatSession` (which still renders approvals app-side). A separate token does not
  help (same uid can read it). Future option: run the host under its own user (`agentbar-host`, distinct from the agent user that runs `claude`) with
  a socket only that user can reach, and authenticate it by uid in the role table.

## Phase 6: Personalization as built (2026-11-03)
- **Preferences** (`AgentBarCore/Preferences`): JSON in `~/Library/Application Support/AgentBar/preferences.json` (0600, atomic temp+rename, dir 0700, version 1, corrupt file backed up to `.bak`). Holds `theme` (automatic/pastel/neon/mono), per-agent-kind defaults (name, color), per-session overrides, `bots`, `sessionBots` and `mascot`. Colors are `#RRGGBB`; names/prompt are sanitized (`PreferenceText`); a skill must be entirely `[A-Za-z0-9:_-]` (max 64, blank = none): `createBot`/`updateBot` throw `PreferencesError.invalidSkill` instead of cleaning, and an invalid skill in a hand-edited file is dropped (the bot is kept). Color precedence: session override > bot > agent-kind default > theme palette > legacy djb2 tint. Display names come from app knowledge only, never from agent output.
- **Bot:** id, name, colorHex, blobKindName?, agentKind, startPrompt, skill?, `defaultFolder?` (absolute local path), `defaultWorkspace?` (agentbar workspace name), createdAt. `Bot.initialMessage` = `/<skill> <startPrompt>` (skill already validated; `initialMessage` still filters defensively).
- **Mascot:** `MascotAppearance` (name, bodyKindName, colorHex, eyeStyle round/pill/sleepy/happy, accessory none/hat/glasses/bow/antenna); shown by the bar when there are no sessions.
- **Session retention:** done sessions no longer expire by time; they stay until the user removes them (cap `maxListedSessions` = 20 drops only the oldest ended ones).
- **UI:** "New session" is an inline flow in the notch panel (Run as, Bot, Project, Start; `PanelRouter.shared.page`; only Claude Code bots are offered, and the bot's `defaultFolder`/`defaultWorkspace` preselects the Project step, marked "(from bot)"); no extra windows except Settings, the onboarding window (see Phase 9) and the macOS folder picker. Demo flags: `--demo-new-chat`, `--demo-flow-step bot|project|start`, `--demo-flow-bot`, `--demo-bot-skill`, `--demo-rename`, `--demo-agent-user`, `--demo-settings theme|bots|editor|mascot`, `--prefs-file`.

## Phase 8: host op `tokenstatus` (2026-11-05) - additive
The owner cannot read the agent home, so token health is asked of the host. App -> host `tokenstatus {rid}`; host -> app
`tokenstatus {rid,status:{present,mode?,ownerOK,size?,plausibleLength,mtime?}}` (`HostTokenStatus`). `lstat` only: the file is never opened, the
content never leaves the host. `ownerOK` = regular file (no symlink) owned by the host uid; `plausibleLength` = 40...4096 bytes; `mode` = permission bits
(healthy = no group/world bits, i.e. 0600). Absent file => `{present:false,ownerOK:false,plausibleLength:false}`. Existing frames and ops are unchanged;
an old host answers an unknown op with `error` (link stays up). App API: `HostClient.tokenStatus(completion:)`.

## Phase 9: onboarding window (2026-11-05) - documented exception
The "no extra windows" rule has one more exception, **requested by the user (2026-11-05)**: a normal (non-floating) onboarding window (`OnboardingWindowController`, 520x620, one instance) with Welcome, Sign-in, Setup and Done pages. It is shown at app start when `OnboardingTrigger.shouldShow` says so (never completed, or older version with a required step missing), from the menu entry "Setup…" and from Settings > Setup. State lives in `SetupRunner` (UserDefaults keys `onboarding.completedVersion`, `onboarding.skippedSteps`, `onboarding.useAgentUser`, `onboarding.snoozedUntil`); no secret is persisted. Launch flags: `--demo-onboarding [welcome|login|setup|done|error]` (implies `--demo`; fake runner, no probes, no system or `~/.claude` access, temp prefs file unless `--prefs-file` is given), `--onboarding-force`.

## Additive contract changes: "Continue in panel" (terminal session -> forked chat)
- `AgentSession.workingDirectory: String?` (new optional field, init param with default nil; Codable decodes older data as nil).
- `CoreEvent.sessionDirectory(id:path:)` (new case). The store keeps `path` only if it is absolute, <= 1024 bytes, free of control characters and `..`.
- `AgentAdapter.metadataEvents(payload:)` (new requirement WITH default `[]`; `translate` output is unchanged). `ClaudeCodeAdapter` returns the hook `cwd` (not for SessionEnd); the transport applies it after `translate`.
- `ChatConfig.resume: ChatResume?` -> args `--resume <id> --fork-session` after the stream-json flags. Id strictly `[A-Za-z0-9-]`, 1...64, no leading `-`, passed as one argv element (no shell). `fork == false` and agent-user (remote) chats are rejected. `ChatSession` logs "Forked from <name>".
- `AgentSession.canContinueInPanel` (claudeCode + valid id + absolute cwd) gates the UI button. UNVERIFIED against a real `claude --resume --fork-session` run.

## Hardening: "Continue in panel" only for owner-origin sessions (2026-11-07) - additive
Finding: hook sessions of the agent user could carry a chosen `cwd`/session id, so the owner would start `claude --resume --fork-session` in a directory the agent controls (hostile `.claude/settings.json` hooks): agent -> owner escalation.
- `AgentSession.originRole: PeerRole?` (optional, default nil; `PeerRole` is now `Codable`). Set by the transport on every authorized op (`SessionOrigins.claim` -> `SessionStore.setOrigin`); durable in the store (the side table is pruned). nil = unknown (chat, demo, old data). An agent claim never downgrades an owner origin; an owner takeover clears any directory.
- Transport: `metadataEvents` (the hook `cwd`) are applied for the OWNER role only; the store additionally ignores `.sessionDirectory` for `originRole == .agent`.
- `canContinueInPanel` now requires `originRole == .owner` (UI button). The backend does not trust the UI: `LiveChatBackend.continueInPanel` re-reads the session from the store and runs `ContinueInPanelCheck.validate`: origin owner; cwd `realpath`-resolved, a directory, owned by `geteuid()`, no group/world write bit; not below `/Users/agentbar`, `/Users/Shared/AgentBar` or the agent's home (checked on the given and the resolved path, case-insensitive); transcript `~/.claude/projects/<cwd with non-alphanumerics -> "-">/<id>.jsonl` exists (fallback: `projects/*/<id>.jsonl`, existence only). Failures become an error bubble "Cannot continue: <reason>". Known limit: check-then-spawn is not atomic (TOCTOU on the owner's own directory).
