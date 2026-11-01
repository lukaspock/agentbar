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
