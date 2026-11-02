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
Allow <Tool>? Project: <name>
cwd: <cwd>                       (only if present)
<key>: <value>                   one entry per top-level key of tool_input, keys sorted
  <continuation line>            further lines of a value are indented by 2 spaces
```
- Values: strings as is; numbers/bools/null/nested objects as compact JSON (sorted keys, no escaped slashes). Empty value => `(leer)`.
- Sanitizing: CR/LF/U+2028/2029/NEL are line breaks (max 2 in a row); tabs become spaces; control, format (zero-width, bidi, tag), private-use,
  unassigned, surrogate, variation selectors, CGJ, Hangul fillers, braille blank become a visible U+FFFD; other space separators become " ".
  The indentation makes it impossible for a value to forge a `key:` line. Header fields (tool, project, cwd) are single line.
- **Truncation rule: never cut, never summarise.** If the full text would exceed `ClaudeCodeAdapter.maxApprovalText` (= 4000 - 100, measured in
  Characters AND unicode scalars), or a key is empty/longer than 60, the tool name is empty/longer than 60, or `tool_input` is missing/empty/not an
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
