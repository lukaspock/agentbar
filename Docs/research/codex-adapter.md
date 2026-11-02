# Codex adapter notes (agent CODEX, 2026-11-02)

STATUS: **UNVERIFIED against a real Codex.** `codex` is not installed locally. Everything below comes from the docs.

## Sources (fetched 2026-11-02)
- Hooks: https://learn.chatgpt.com/docs/hooks (developers.openai.com/codex/* redirects here)
- notify: https://learn.chatgpt.com/docs/config-file/config-advanced
- Earlier research: Docs/research/integrations.md section 3.

## Documented facts used
- Hook files: `~/.codex/hooks.json` or `[hooks]` in `~/.codex/config.toml` (also project `.codex/`, plugins, managed). Matching hooks from all layers run.
- hooks.json: `{"hooks":{"<Event>":[{"matcher":"...","hooks":[{"type":"command","command":"...","timeout":N}]}]}}`. Default timeout 600 s; SessionEnd/Interrupt default 1, max 3.
- Events: SessionStart, SessionEnd, PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact, UserPromptSubmit, SubagentStart, SubagentStop, Stop, Interrupt.
- Stdin common: session_id, transcript_path (string|null), cwd, hook_event_name, model. PermissionRequest adds turn_id, tool_name, tool_input (Bash/apply_patch: `tool_input.command`; description may be null). Stop adds last_assistant_message (string|null), stop_hook_active. No `permission_suggestions`, no Notification event.
- PermissionRequest output: `hookSpecificOutput.decision.behavior` = allow | deny (+message). `updatedInput`, `updatedPermissions`, `interrupt` must not be returned. No decision (empty output) = normal Codex prompt. Any deny wins.
- Trust gating: new/changed hooks are skipped until reviewed in `/hooks` (hash of the hook). Not hosted tools (WebSearch) are not covered.
- notify: `notify = ["prog", ...]`; one JSON argument (argv, not stdin): type `agent-turn-complete`, thread-id, turn-id, cwd, input-messages, last-assistant-message.

## Design decisions
- `CodexAdapter` (kind `.codex`, id `codex`) reuses the Claude renderer/sanitizer: full text or no request. If not fully showable: no ask, session `needsInput` with "[gekürzt, im Terminal prüfen]", empty hook output.
- Options: Allow / Deny only (no "Always": unsupported by Codex hooks). Anything but an answered allow/deny encodes to empty output.
- Tolerant: unknown events (e.g. PostToolUse, compact, new ones) -> no events; unknown fields ignored; non-object/missing id -> throws (transport answers invalid payload, hook output empty).
- The `notify` payload (no `hook_event_name`, has `type`) is also translated (turn complete -> done + log). The CLI `agentbar hook` reads stdin, but notify passes JSON as argv: it would need a small CLI extension (GENERIC). Not set up by the hook installer.
- `CodexHookSetup` (core, Adapters/CodexHookSetup.swift) installs the 7 events into `~/.codex/hooks.json` with diff preview, backup, merge, uninstall; `App/Sources/Setup/CodexHookSetupMenu.swift` is the (unwired) menu item.

## To verify once Codex is installed
Exact stdin of each event, allow/deny output being honoured, behaviour when the TUI prompt is open while the hook waits, whether the CLI resolves a `command` string with escaped spaces, `/hooks` trust flow, hooks.json vs config.toml merge warning, whether `Interrupt` is real.
