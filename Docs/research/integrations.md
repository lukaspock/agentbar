# AgentBar integrations research (Claude Code + Codex CLI)

Researched 2026-11-01. Local: Claude Code 2.1.283; `codex` not installed locally (all Codex facts from docs only).
Sources: [CC hooks](https://code.claude.com/docs/en/hooks) · [CC headless](https://code.claude.com/docs/en/headless) · [SDK user-input](https://code.claude.com/docs/en/agent-sdk/user-input) · [Codex hooks](https://learn.chatgpt.com/docs/hooks) · [Codex config-advanced](https://learn.chatgpt.com/docs/config-file/config-advanced) · [Codex non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode) · [Codex app-server README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)
(developers.openai.com/codex/* 308-redirects to learn.chatgpt.com/docs/*.)

## 1. Claude Code hooks

### Config
Settings locations ([hooks](https://code.claude.com/docs/en/hooks)): `~/.claude/settings.json` (user), `.claude/settings.json` (project, shared), `.claude/settings.local.json` (project, gitignored), managed policy, plugin `hooks/hooks.json`. All levels merge; identical handlers run once. `disableAllHooks` / `allowManagedHooksOnly` can switch them off.
Schema: event -> matcher groups -> handlers:
```json
{"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","command":"/path/agentbar hook --adapter claudeCode","timeout":600}]}]}}
```
- `matcher`: `*`/empty/omitted = all; letters/digits/`_-,| ` = exact list (`Edit|Write`); otherwise unanchored JS regex. Ignored for UserPromptSubmit, Stop, etc.
- Handler `type`: command | http | mcp_tool | prompt | agent. Command fields: `command`, optional `args` (exec form), `timeout` (seconds), `async`, `shell`, `onFailure` (continue|block, v2.1.295+), `statusMessage`, `if` (permission-rule syntax, tool events only).
- HTTP hooks (POST the same JSON, response body = same output JSON) exist: could replace the CLI shim, but non-2xx/connection failure = non-blocking error. Needs `allowedHttpHookUrls` consideration in managed setups.
- `/hooks` shows configured hooks read-only. Settings are snapshotted at session start in many versions: UNVERIFIED whether new hooks apply to already-running sessions (assume restart / `/hooks` review required).

### Events (33 listed; the ones AgentBar needs)
Common stdin fields on all events: `session_id`, `prompt_id`, `transcript_path`, `cwd`, `permission_mode` (default|plan|acceptEdits|auto|dontAsk|bypassPermissions), `effort.level`, `hook_event_name`, `agent_id`/`agent_type` (inside subagents).

| Event | Extra stdin fields | Decision output | Exit 2 |
|---|---|---|---|
| SessionStart | `source` (startup/resume/clear/compact/fork), `model`(optional) | `hookSpecificOutput.additionalContext`, `sessionTitle`, ... | no block |
| UserPromptSubmit | `prompt` | `decision:"block"`+`reason`; `additionalContext` | blocks prompt |
| PreToolUse | `tool_name`, `tool_input`, `tool_use_id` | `hookSpecificOutput.{hookEventName:"PreToolUse",permissionDecision: allow\|deny\|ask\|defer, permissionDecisionReason, updatedInput}` | blocks tool, stderr to Claude |
| PermissionRequest | `tool_name`, `tool_input`, `permission_suggestions[]`, (`mcp_server`) - no `tool_use_id` | `hookSpecificOutput.{hookEventName:"PermissionRequest",decision:{behavior:allow\|deny, updatedInput?, updatedPermissions?, message?(deny), interrupt?(deny)}}` | does NOT block; stderr discarded |
| PostToolUse | `tool_name`,`tool_input`,`tool_response`,`tool_use_id`,`duration_ms` | `decision:block`, `updatedToolOutput` | no |
| Notification | `message`, `title?`, `notification_type` (permission_prompt, idle_prompt, agent_needs_input, agent_completed, auth_success, elicitation_*, ...) | none (side effects only) | no |
| Stop | `stop_hook_active`, `last_assistant_message` (UNVERIFIED for Stop; documented verbatim for SubagentStop, Codex Stop has it) | `decision:"block"`+`reason` keeps Claude working | blocks stop |
| SubagentStop | `agent_id`,`agent_type`,`agent_transcript_path`,`stop_hook_active`,`last_assistant_message` | same as Stop | blocks |
| SessionEnd | `reason` (UNVERIFIED values) | none; shares 1.5 s budget (raisable to 60 s) | no |
Also exist: Setup, PermissionDenied, PostToolUseFailure, SubagentStart, TaskCreated/Completed, PreCompact, Elicitation, ... (not needed for v1).

### Semantics
- Exit 0: stdout parsed as JSON if a single JSON object; plain text otherwise (ignored for decisions). Exit 2: blocking error for blocking events. Any other code: non-blocking error, action proceeds. ([hooks](https://code.claude.com/docs/en/hooks))
- **Empty output / exit 0 = no decision; the normal permission flow (the terminal dialog) proceeds.** Silence never approves. This is exactly the safe fallback AgentBar needs.
- Timeout: default 600 s for command/http (30 s for UserPromptSubmit, 10 s MessageDisplay). On timeout the hook is cancelled, output discarded; on PreToolUse the call is NOT blocked (falls to normal flow) unless `onFailure:"block"`. So a blocking approval hook can safely wait minutes.
- **PermissionRequest vs PreToolUse**: PermissionRequest fires only when Claude Code is about to show a permission prompt (or would auto-deny a non-promptable call); auto-allowed calls never trigger it. PreToolUse fires on every call. For an approval bar, use PermissionRequest (exactly the "needs the user" moment); use PreToolUse only for activity display ("working: Bash npm test"). Deny/ask rules are still evaluated after an allow.
- Precedence PreToolUse multi-hook: deny > defer > ask > allow. PermissionRequest with several decisions: UNVERIFIED (with a SDK host, first decider wins).
- With `canUseTool` / `--permission-prompt-tool` active, hooks run alongside and whichever decides first applies.
- Always-allow: return `decision.updatedPermissions` (echo an entry from `permission_suggestions`, e.g. `destination:"localSettings"` writes `.claude/settings.local.json`). Hook-driven "Always" is possible but writes a foreign config: needs the user's explicit consent in the UI.
- Notification `permission_prompt` fires only ~6 s after the dialog appears; do not use it for latency-critical approvals.
- `defer` works only in `-p` mode.
- Hooks run in `-p` sessions too, even in untrusted folders unless `--bare`. Project hooks therefore execute without trust prompt in headless: security note.

### Limits / gotchas
- Stdout must be exactly one JSON object (no banner text). The CLI shim must print nothing else.
- Hook runs as a short-lived process per event, so identity of a session = `session_id`; `cwd` for naming.
- Subagent tool calls arrive with `agent_id` set; show them under the parent session.
- The terminal dialog stays open in the TUI while the hook blocks? UNVERIFIED (docs say hook runs "when about to prompt"; assume hook result pre-empts the dialog, and a hook that answers late after the user answered in terminal is harmless/ignored: UNVERIFIED).

## 2. Claude Code SDK / headless (basis for chat-input phase)
- `claude -p --output-format stream-json --verbose [--include-partial-messages]` emits NDJSON: `system/init` (session_id, model, tools, mcp_servers), `assistant`/`user` messages (subagent ones carry `parent_tool_use_id`), `stream_event` deltas, `system/api_retry`, `permission_denied`, final `result` (cost, `permission_denials`). ([headless](https://code.claude.com/docs/en/headless))
- `--input-format stream-json` (local `claude --help` confirms flag, `-p` only) accepts user messages as NDJSON: `{"type":"user","message":{"role":"user","content":"..."}}` ([user-input](https://code.claude.com/docs/en/agent-sdk/user-input) shows this shape for the SDK stream). `--replay-user-messages` re-emits them. Streaming input lets a bar send follow-ups and interrupts (SIGINT or SDK `interrupt()`).
- Approvals in headless: `--permission-prompt-tool <mcp tool>` (local help lists `--permission-prompts <target>` = tool name or `none`), or SDK `canUseTool(toolName,input,{signal,suggestions})` returning `{behavior:"allow",updatedInput}` / `{behavior:"deny",message}`; `updatedPermissions` for always-allow. Callback may stay pending indefinitely. `AskUserQuestion` also comes through `canUseTool` (input `questions[]`; answer by returning `updatedInput:{questions,answers:{<question>:<label>}}`) - a natural fit for AgentBar "question" requests.
- Without a host in `-p` Manual mode, un-approved calls are denied (v2.1.302+ default Manual).
- `--resume <session_id>` / `--continue` to continue; the TS/Python SDK needs a long-lived process. SIGTERM exits 143 and leaves the turn unfinished.
- IMPORTANT limitation: none of this attaches to an already-running interactive `claude` TUI session. A chat reply to a TUI session is NOT possible via hooks (hooks cannot inject prompts, except `Stop` `decision:block`+`reason`, which feeds a continuation instruction, and `UserPromptSubmit` `additionalContext`). Chat input therefore requires AgentBar to own the process (SDK/`-p`) = separate "managed session" feature. Raw control_request/control_response wire format for the stdin protocol: UNVERIFIED (use the SDK instead of hand-rolling).

## 3. Codex CLI
- **notify**: `notify = ["python3","/path/script.py"]` in `~/.codex/config.toml`; program gets ONE JSON argv: `type` (only `agent-turn-complete`), `thread-id`, `turn-id`, `cwd`, `input-messages`, `last-assistant-message`. Fire-and-forget; no approval event; no answer channel. ([config-advanced](https://learn.chatgpt.com/docs/config-file/config-advanced)) Separate `[tui] notifications` (agent-turn-complete, approval-requested; OSC9/BEL) only rings the terminal.
- **Hooks (stable since v0.124, per third-party [post](https://codex.danielvaughan.com/2026/04/15/permissionrequest-hooks-programmatic-policy-engine/); official [hooks page](https://learn.chatgpt.com/docs/hooks))**: Events SessionStart, SessionEnd, PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact, UserPromptSubmit, SubagentStart, SubagentStop, Stop, Interrupt. Config in `~/.codex/hooks.json`, `~/.codex/config.toml` `[hooks]`, `<repo>/.codex/...` (project only if trusted). Stdin common: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `model`, `turn_id`. Deliberately very close to Claude's schema:
  - PermissionRequest stdin: `tool_name`, `tool_input` (+`description`), `permission_mode`. Output: `hookSpecificOutput.decision.behavior` allow|deny (+`message`); any deny wins; no decision = normal prompt. `updatedInput`, `updatedPermissions`, `interrupt` are NOT supported (fail closed). PreToolUse: `ask` unsupported.
  - Exit 2 blocks PreToolUse/PostToolUse/UserPromptSubmit/Stop/SubagentStop; default timeout 600 s (SessionEnd/Interrupt 1-3 s).
  - **Trust gating**: unreviewed or changed hooks are silently skipped until trusted in `/hooks` (hash of command+path); `--dangerously-bypass-hook-trust` per invocation. A write of config by AgentBar is therefore not enough: user must trust it in Codex.
  - Coverage limits: shell, unified exec, apply_patch, MCP, local function tools; NOT hosted tools like WebSearch; "guardrail, not enforcement boundary".
  So the Codex adapter can reuse the ClaudeCode payload translator with small deltas (no Notification event, no `updatedPermissions`).
- **Approval policy / sandbox**: `approval_policy` = `on-request` | `never` | `{granular={sandbox_approval,rules,mcp_elicitations,request_permissions,skill_approval}}` (`untrusted` retired); `approvals_reviewer` user|auto_review; `sandbox_mode` read-only (exec default) | `workspace-write` | `danger-full-access`. `--full-auto` removed.
- **`codex exec --json`**: JSONL events `thread.started{thread_id}`, `turn.started`, `turn.completed{usage}`, `turn.failed`, `item.started|updated|completed{item:{id,type: command_execution|agent_message|reasoning|file_change|mcp_tool_call|web_search|plan_update}}`, `error`. `codex exec resume <id>|--last`. No interactive approval in exec: approvals only via policy/sandbox flags or `--approve-for-me`. ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode))
- **app-server** (`codex app-server`, JSON-RPC, used by IDE extensions): methods `thread/start`, `turn/start`, `turn/interrupt`, notifications `turn/completed` etc.; server-to-client approval requests (`item/commandExecution/requestApproval`, responses accept/decline/cancel). This is the ONLY real two-way approval + chat channel, but the README excerpt fetched did not show framing, schema, or the file-change approval; treat as UNVERIFIED/unstable (many items "experimental"). Generate schema with the CLI itself (UNVERIFIED command name) before depending on it.
- MCP: Codex is both an MCP client (`[mcp_servers.*]` in config.toml) and can run as an MCP server (`codex mcp-server`: UNVERIFIED here). An MCP tool "ask_user" exposed by AgentBar is possible but the model must choose to call it: not a reliable approval gate.

### NOT possible
- Answering a Codex approval prompt shown in an already-running Codex TUI from outside, other than via a PermissionRequest hook (allow/deny only, no "always", no edited input) - and only for tools the hook covers.
- `notify` cannot signal "approval needed" nor accept replies.
- Sending chat text into a running interactive Claude or Codex TUI session (no documented injection API for either). Needs a managed process (Claude SDK / `codex app-server`).
- Hook-based "Always allow" for Codex (`updatedPermissions` unsupported).

## 4. Recommendations for adapter design
1. ClaudeCode adapter: install hooks for `PermissionRequest` (blocking, timeout ~600), `PreToolUse` (non-blocking activity only: print nothing), `Notification`, `Stop`, `SubagentStop`, `UserPromptSubmit`, `SessionStart`, `SessionEnd`. Map: SessionStart -> update(idle), UserPromptSubmit/PreToolUse -> working(action = tool + short input), Notification(`permission_prompt`/`idle_prompt`/`agent_needs_input`) -> needs-user (info), Stop -> idle + log last_assistant_message (truncate), SessionEnd -> end.
2. PermissionRequest -> `ask(type approval)` with options Allow / Deny / Always. Output encoding: allow `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`; deny with `message`; Always = allow + `updatedPermissions` copied from `permission_suggestions[destination=localSettings]` (only if present; else degrade to plain allow); timeout/unreachable/cancel = EMPTY output (user answers in the terminal). Never emit allow on error.
3. The shim must exit 0 with empty stdout whenever the app is unreachable or the payload is unknown; stdout strictly one JSON object; keep stderr quiet (exit 2 unnecessary).
4. Hook processes should use a short connect timeout (e.g. 300 ms) for non-blocking events, but block for PermissionRequest until answered or app-side timeout shorter than the hook `timeout`.
5. Setup: write only the `hooks` key into `~/.claude/settings.json` after diff preview + timestamped backup; merge, never replace; tag our entries by command path so they can be removed; Claude Code may re-read settings live (UNVERIFIED), tell the user to restart sessions.
6. Dedup: if user also has the terminal dialog open, the first answer wins; display "answered in terminal" by observing the next PostToolUse/Stop for that session_id (cancel pending ask).
7. Phase 2 chat: managed sessions through the Agent SDK/`claude -p --input-format stream-json` with `canUseTool` -> same ask pipeline (also AskUserQuestion). Keep behind `supportsStop`/capability flag. Codex later via `codex app-server` or hooks reuse.
8. Codex adapter (later): reuse translator against `~/.codex/hooks.json` (needs user trust step), PermissionRequest allow/deny only.

## 5. Open risks
1. **Hook semantics drift**: 33 events, docs change quickly (new fields, onFailure, defer); adapter must ignore unknown fields/events and be version tolerant.
2. **Blocking-hook edge cases**: unknown behavior if the user answers in the terminal while the hook is pending, or if the hook process is killed; stale pending asks must be cancelled via connection close (client disconnect = cancel).
3. **Config mutation**: writing user `settings.json` is invasive; JSON comments/key order, managed-policy overrides (`allowManagedHooksOnly`, `disableAllHooks`) can silently neutralise hooks; detect via a test event.
4. **Always-allow persists rules** into `.claude/settings.local.json` outside AgentBar control.
5. **No chat input for TUI sessions** (see not-possible), expectation management in UI.
6. **Codex**: hook trust gating, partial tool coverage, app-server experimental; `notify` weak.
7. Local `PermissionRequest` input/output verified from docs only; no live test was run (read-only research). Recommend an integration test with a throwaway `--settings` file (flag exists in `claude --help`? UNVERIFIED) so `~/.claude` is never touched.

## UNVERIFIED summary
Stop/SessionEnd exact stdin fields for Claude; live reload of hook config in running sessions; multi-hook PermissionRequest precedence; terminal-dialog interplay while hook pending; stream-json stdin control_request wire format; Codex app-server framing/approval schema/command names; `codex mcp-server`; all Codex behavior (not installed locally).
