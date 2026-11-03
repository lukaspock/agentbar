# AgentBar

A tiny, always-on status and input bar for AI agents on macOS. Works with Claude Code today; Codex, generic CLI agents and
computer-use agents are planned (see [ROADMAP.md](ROADMAP.md)).

- **Idle:** a small friendly blob at the notch (or a floating pill / draggable circle on Macs without a notch).
- **Working:** the blob breathes. **Needs you:** it turns amber and looks at you.
- **Hover:** the bar softly expands into a panel with open requests from all agents (Allow / Deny / Always), a reply field,
  a short history, and a remove button per agent.
- **Local only:** Unix-domain socket with a random token, no network listener.

<p align="center">
  <img src="Docs/images/approval.png" width="340" alt="AgentBar asking for permission to run a command">
  <img src="Docs/images/chat.png" width="340" alt="AgentBar chat with a running agent and Stop buttons">
</p>

Status: early MVP (Phase 1). Real Claude Code permission flows are not yet verified end to end, see the roadmap.

## Screenshots

<table>
  <tr>
    <td align="center"><img src="Docs/images/agents.png" width="300" alt="Six agents in different states"><br><sub>All agents at a glance</sub></td>
    <td align="center"><img src="Docs/images/question.png" width="300" alt="An agent asking a question"><br><sub>Questions from agents</sub></td>
    <td align="center"><img src="Docs/images/history.png" width="300" alt="Session history"><br><sub>Per-session history</sub></td>
  </tr>
</table>

## Build
Requires macOS 14+, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen).
```bash
cd Packages/AgentBarCore && swift build && swift test && bash Tests/e2e.sh
cd ../../App && xcodegen generate && xcodebuild -project AgentBar.xcodeproj -scheme AgentBar build
```
Try it without any agent: run the app with `--demo`. With the app running, use the bundled CLI
(`AgentBar.app/Contents/Resources/agentbar`), e.g.
`agentbar ask --session t --type approval --text "ok?" --option allow:Yes --option deny:No --timeout 60 --default deny`.

## Claude Code hooks
Menu bar icon → "Hooks einrichten…" shows a diff preview of the changes to `~/.claude/settings.json`, writes a backup, and only
applies after your confirmation. Timeouts and errors never auto-allow: Claude Code falls back to its own dialog.

> **Hinweis:** Die Hooks speichern den absoluten Pfad zur mitgelieferten CLI (`AgentBar.app/Contents/Resources/agentbar`). Wird die App verschoben oder umbenannt (z. B. vom Build-Ordner nach `~/Desktop` oder `/Applications`), muss im Menüleisten-Icon erneut "Hooks einrichten…" ausgeführt werden.

## Docs
[CONTRACTS.md](CONTRACTS.md) (architecture, wire protocol), [Docs/research](Docs/research), [ROADMAP.md](ROADMAP.md).

## License
MIT
