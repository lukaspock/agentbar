import Foundation

/// Adapter for OpenAI Codex CLI hooks (stdin JSON in, `hookSpecificOutput` JSON out) and the `notify` payload.
///
/// UNVERIFIED against a real Codex: `codex` is not installed locally. The schema follows the public docs
/// (see Docs/research/codex-adapter.md). Therefore the adapter is tolerant: unknown events and fields are ignored,
/// an unclear payload yields no events (empty output = Codex shows its own approval prompt).
///
/// Differences to Claude Code: no `Notification` event, no `permission_suggestions`, and PermissionRequest only
/// supports allow/deny (`updatedInput`, `updatedPermissions`, `interrupt` are unsupported), so there is no "always".
/// Safety: the approval text reuses `ClaudeCodeAdapter.renderApproval`. If the tool input cannot be shown in full,
/// no request is created (no one-click allow) and the hook answer stays empty.
public final class CodexAdapter: AgentAdapter, @unchecked Sendable {
    public var kind: AgentKind { .codex }
    /// Adapter id for `AdapterRegistry` and `agentbar hook --adapter codex`.
    public static let adapterId = "codex"
    public static let maxPayloadBytes = ClaudeCodeAdapter.maxPayloadBytes
    public static let approvalTimeoutSeconds = ClaudeCodeAdapter.approvalTimeoutSeconds

    public init() {}

    public func translate(payload: Data) throws -> [CoreEvent] {
        guard payload.count <= Self.maxPayloadBytes else { throw ClaudeCodeAdapter.AdapterError.malformed("payload too large") }
        guard let root = try? JSONSerialization.jsonObject(with: payload),
              let obj = root as? [String: Any] else { throw ClaudeCodeAdapter.AdapterError.malformed("not a JSON object") }

        // `notify` program payload (argv JSON): {"type":"agent-turn-complete","thread-id":...,"cwd":...}
        if obj["hook_event_name"] == nil, let type = obj["type"] as? String {
            guard type == "agent-turn-complete" else { return [] }
            guard let sid = Self.validId(obj["thread-id"] as? String) else { return [] }
            let name = Self.sessionName(cwd: obj["cwd"] as? String)
            let last = ClaudeCodeAdapter.clean(obj["last-assistant-message"] as? String, max: 200) ?? "Finished"
            return [.sessionUpdate(id: sid, name: name, kind: .codex, state: .done, action: nil, supportsStop: nil),
                    .log(sessionId: sid, entry: HistoryEntry(kind: .status, text: last))]
        }

        guard let event = obj["hook_event_name"] as? String, !event.isEmpty else {
            throw ClaudeCodeAdapter.AdapterError.malformed("missing hook_event_name")
        }
        let known: Set<String> = ["PermissionRequest", "PreToolUse", "Stop", "SubagentStop", "UserPromptSubmit",
                                  "SessionStart", "SessionEnd", "Interrupt"]
        guard known.contains(event) else { return [] }
        guard let sid = Self.validId(obj["session_id"] as? String) else {
            throw ClaudeCodeAdapter.AdapterError.malformed("missing session_id")
        }
        let name = Self.sessionName(cwd: obj["cwd"] as? String)
        func update(_ state: SessionState?, action: String? = nil) -> CoreEvent {
            .sessionUpdate(id: sid, name: name, kind: .codex, state: state, action: action, supportsStop: nil)
        }
        switch event {
        case "SessionStart": return [update(.idle)]
        case "SessionEnd": return [.sessionEnd(id: sid)]
        case "UserPromptSubmit": return [update(.working, action: "Thinking")]
        case "Interrupt": return [update(.idle, action: "Interrupted")]
        case "PreToolUse":
            let tool = ClaudeCodeAdapter.clean(obj["tool_name"] as? String, max: 60) ?? "tool"
            let summary = ClaudeCodeAdapter.summarize(tool: tool, input: obj["tool_input"])
            return [update(.working, action: summary.isEmpty ? tool : "\(tool): \(summary)")]
        case "Stop":
            let last = ClaudeCodeAdapter.clean(obj["last_assistant_message"] as? String, max: 200) ?? "Finished"
            return [update(.done), .log(sessionId: sid, entry: HistoryEntry(kind: .status, text: last))]
        case "SubagentStop":
            let last = ClaudeCodeAdapter.clean(obj["last_assistant_message"] as? String, max: 200) ?? "Subagent finished"
            return [.log(sessionId: sid, entry: HistoryEntry(kind: .status, text: "Subagent: \(last)"))]
        default: // PermissionRequest
            return permissionAsk(obj, sid: sid, name: name)
        }
    }

    private func permissionAsk(_ obj: [String: Any], sid: String, name: String) -> [CoreEvent] {
        let rendered = ClaudeCodeAdapter.renderApproval(tool: obj["tool_name"] as? String, cwd: obj["cwd"] as? String,
                                                        project: name, input: obj["tool_input"])
        guard let text = rendered.text else {
            let tool = ClaudeCodeAdapter.clean(obj["tool_name"] as? String, max: 60) ?? "tool"
            let msg = "\(tool): \(rendered.reason) \(ClaudeCodeAdapter.truncationMarker)"
            return [.sessionUpdate(id: sid, name: name, kind: .codex, state: .needsInput, action: msg, supportsStop: nil),
                    .log(sessionId: sid, entry: HistoryEntry(kind: .status, text: msg))]
        }
        let options = [RequestOption(id: "allow", label: "Allow", style: .primary),
                       RequestOption(id: "deny", label: "Deny", style: .destructive)]
        let req = AgentRequest(requestId: UUID().uuidString, type: .approval, text: text, options: options,
                               timeoutSeconds: Self.approvalTimeoutSeconds, defaultOptionId: nil)
        return [.sessionUpdate(id: sid, name: name, kind: .codex, state: nil, action: nil, supportsStop: nil),
                .ask(sessionId: sid, request: req)]
    }

    public func encode(response: AgentResponse, for request: AgentRequest) -> Data {
        guard response.reason == .answered, let opt = response.optionId else { return Data() }
        let decision: [String: Any]
        switch opt {
        case "allow": decision = ["behavior": "allow"]
        case "deny": decision = ["behavior": "deny",
                                 "message": ClaudeCodeAdapter.clean(response.text, max: 200) ?? "Denied via AgentBar"]
        default: return Data()   // includes "always": unsupported by Codex hooks
        }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
    }

    static func validId(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s.count <= AgentBarLimits.maxIdLength else { return nil }
        return s
    }

    static func sessionName(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Codex" }
        return ClaudeCodeAdapter.clean((cwd as NSString).lastPathComponent, max: AgentBarLimits.maxNameLength) ?? "Codex"
    }
}
