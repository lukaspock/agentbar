# Chat input to an agent (Phase 3) - AgentBar `ChatSession`

Status 2026-11-02: implemented and tested against a FAKE process only. **Everything about the real wire behaviour is UNVERIFIED**
(local `claude` 2.1.283 login was expired; no real run was made; the opt-in test `testRealClaudeOneTurn` needs `AB_REAL_CLAUDE=1`).

## Sources
- CLI reference (code.claude.com/docs/en/cli-reference): `-p`, `--input-format stream-json`, `--output-format stream-json` (needs `--verbose`),
  `--include-partial-messages`, `--replay-user-messages`, `--permission-prompt-tool` (MCP tool), `--permission-prompts host|none`.
- Agent SDK "Handle approvals and user input": `canUseTool` fires for tool approvals and for `AskUserQuestion`; allow = `{behavior:"allow", updatedInput}`
  (`updatedPermissions` echoes a suggestion), deny = `{behavior:"deny", message}`.
- `claude --help` 2.1.283: `--permission-prompts` "host" = "the SDK host or --permission-prompt-tool".
- Strings of the 2.1.283 binary: `control_request` with `request_id` + `request:{subtype:"can_use_tool", tool_name, input, permission_suggestions?, tool_use_id,...}`,
  `control_response`, `control_cancel_request`; and the message "--permission-prompt-tool (permission prompts reach the host over stdio; an MCP tool cannot answer them here)".
  => With `-p` + stream-json the prompts come over stdio; no MCP permission tool is needed. The exact JSON envelope of the reply is NOT in the public docs.

## Wire format used (UNVERIFIED)
Spawn: `claude -p --input-format stream-json --output-format stream-json --verbose [--model M] [--max-budget-usd N] [--tools a,b] [--permission-mode manual|acceptEdits|plan|dontAsk]`
with cwd = explicit directory and a minimal environment. Not used: `--dangerously-skip-permissions`, `bypassPermissions`, `auto`.

stdin (one JSON per line):
```
{"type":"user","message":{"role":"user","content":"<text>"}}
{"type":"control_response","response":{"subtype":"success","request_id":"<id>","response":{"behavior":"allow","updatedInput":{...},"updatedPermissions":[...]}}}
{"type":"control_response","response":{"subtype":"success","request_id":"<id>","response":{"behavior":"deny","message":"..."}}}
```
stdout (one JSON per line), handled: `system/init`, `assistant` (text + tool_use blocks, sub-agent messages with parent_tool_use_id skipped),
`result` (`is_error`, `subtype`, `result`), `control_request/can_use_tool`, `control_cancel_request`. Everything else is ignored; malformed lines are skipped (first 3 logged).
Open questions: whether an `initialize` control_request is required first; whether the deny/allow envelope above is exactly right; whether a
PermissionRequest hook of the user's settings also fires in this process (then the user sees the request twice: run the chat process with settings that
do not contain AgentBar hooks if that shows up); whether `result` arrives once per queued user message.

## Mapping to the store
| Event | Store |
|---|---|
| start | `sessionUpdate(kind claudeCode, idle, supportsStop true)` |
| `send(text:)` | log `answer` "You: ...", state `working`, action "Thinking" |
| assistant text | log `status` "Claude: ..." (sanitized, max 1500) |
| tool_use | action "Tool: summary" (same summarize as ClaudeCodeAdapter) |
| can_use_tool | `ask` approval (Allow/Deny/Always allow), text from `ClaudeCodeAdapter.renderApproval`, timeout 120 s, default none |
| AskUserQuestion (1 question, single-select, 1-6 plain options) | `ask` question with the options; otherwise denied with a hint to ask in plain text |
| result ok / error | state `idle` (action cleared) / `error` + log `error` |
| exit 0 / stop / other / idle timeout | `sessionEnd` / log "stopped" + `sessionEnd` / state `error` "exit N" / state `error` "timeout" |

Safety: a request that cannot be shown in full (too long, unreadable characters, empty input) gets NO request and no one-click allow; because a headless process has no
terminal dialog to fall back to, the call is DENIED with an explanatory message and the session shows the `[gekuerzt, im Terminal pruefen]` hint. Timeout, cancel, remove,
unknown option => deny (never allow). A typed reply to an approval = deny with the text as guidance. Stop: pending prompts denied, SIGTERM synchronously, SIGKILL after `killGrace` (2 s),
second `stop()` kills at once. Idle watchdog (default 30 min without output during a turn, paused while a prompt is open) kills the process. Environment: only
PATH, HOME, USER, LOGNAME, SHELL, LANG, LC_ALL, TMPDIR, ANTHROPIC_*, CLAUDE_CONFIG_DIR, CLAUDE_CODE_OAUTH_TOKEN, proxy variables are passed on. Limitation: tool subprocesses
share claude's process group; SIGKILL of claude alone can orphan them.

## Public API (Core, `@MainActor`)
```swift
let chat = ChatSession(config: ChatConfig(executable: ChatConfig.locateClaude()!, workingDirectory: dir, model: "haiku"), store: store)
try chat.start()                 // throws ChatError.invalidConfig / spawnFailed / alreadyStarted
try chat.send(text: "...")       // throws .notRunning / .emptyText / .textTooLong
chat.stop()                      // immediate; wire to store.stopHandler: { id in if id == chat.sessionId { chat.stop() } }
chat.sessionId; chat.phase       // .notStarted/.running/.stopping/.exited
```
Tests: `Tests/AgentBarCoreTests/ChatSessionTests.swift` (fake process, /bin/cat plumbing, SIGTERM-ignoring shell for kill). Real run: `AB_REAL_CLAUDE=1 swift test --filter testRealClaudeOneTurn` (after `claude` login).
