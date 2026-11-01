import Foundation

/// Adapter for Claude Code hooks (stdin JSON in, `hookSpecificOutput` JSON out).
///
/// Design notes
/// - `encode(response:for:)` only receives the response and the `AgentRequest`. The hook event name and the
///   `permission_suggestions` (needed for "always") are not part of those, so they are kept in a small
///   thread-safe side table keyed by `requestId` (set in `translate`, consumed in `encode`). The request's option
///   ids stay the contract ids ("allow"/"deny"/"always"). The table is bounded (oldest entries are evicted), so
///   requests that are cancelled by a client disconnect (never encoded) cannot leak memory.
/// - Received text is data: it is only ever sanitized and displayed, never executed or interpreted.
/// - Safe default: timeout, cancel, unknown request, unknown option => empty output (Claude shows its own dialog).
public final class ClaudeCodeAdapter: AgentAdapter, @unchecked Sendable {
    public var kind: AgentKind { .claudeCode }

    public static let maxPayloadBytes = 256 * 1024
    public static let approvalTimeoutSeconds = 120
    static let maxPendingTable = 256

    public enum AdapterError: Error, Equatable { case malformed(String) }

    private struct Pending { var suggestion: Data? }   // the chosen suggestion entry as JSON, if any
    private let lock = NSLock()
    private var table: [String: Pending] = [:]
    private var order: [String] = []

    public init() {}

    // MARK: translate

    public func translate(payload: Data) throws -> [CoreEvent] {
        guard payload.count <= Self.maxPayloadBytes else { throw AdapterError.malformed("payload too large") }
        guard let root = try? JSONSerialization.jsonObject(with: payload),
              let obj = root as? [String: Any] else { throw AdapterError.malformed("not a JSON object") }
        guard let event = obj["hook_event_name"] as? String, !event.isEmpty else {
            throw AdapterError.malformed("missing hook_event_name")
        }
        let known: Set<String> = ["PermissionRequest", "PreToolUse", "Notification", "Stop", "SubagentStop",
                                  "UserPromptSubmit", "SessionStart", "SessionEnd"]
        guard known.contains(event) else { return [] }
        guard let sid = obj["session_id"] as? String, !sid.isEmpty, sid.count <= AgentBarLimits.maxIdLength else {
            throw AdapterError.malformed("missing session_id")
        }
        let name = Self.sessionName(cwd: obj["cwd"] as? String)

        func update(_ state: SessionState?, action: String? = nil) -> CoreEvent {
            .sessionUpdate(id: sid, name: name, kind: .claudeCode, state: state, action: action, supportsStop: nil)
        }

        switch event {
        case "SessionStart":
            return [update(.idle)]
        case "SessionEnd":
            return [.sessionEnd(id: sid)]
        case "UserPromptSubmit":
            return [update(.working, action: "Thinking")]
        case "PreToolUse":
            let tool = Self.clean(obj["tool_name"] as? String, max: 60) ?? "tool"
            let summary = Self.summarize(tool: tool, input: obj["tool_input"])
            return [update(.working, action: summary.isEmpty ? tool : "\(tool): \(summary)")]
        case "Notification":
            let type = obj["notification_type"] as? String ?? ""
            let msg = Self.clean(obj["message"] as? String, max: 200) ?? "Claude needs your attention"
            let entry = CoreEvent.log(sessionId: sid, entry: HistoryEntry(kind: .status, text: msg))
            if ["permission_prompt", "idle_prompt", "agent_needs_input"].contains(type) || type.hasPrefix("elicitation") {
                return [update(.needsInput, action: msg), entry]
            }
            return [entry]
        case "Stop":
            let last = Self.clean(obj["last_assistant_message"] as? String, max: 200) ?? "Finished"
            return [update(.done), .log(sessionId: sid, entry: HistoryEntry(kind: .status, text: last))]
        case "SubagentStop":
            let last = Self.clean(obj["last_assistant_message"] as? String, max: 200) ?? "Subagent finished"
            return [.log(sessionId: sid, entry: HistoryEntry(kind: .status, text: "Subagent: \(last)"))]
        default: // PermissionRequest
            return [permissionAsk(obj, sid: sid, name: name)]
        }
    }

    private func permissionAsk(_ obj: [String: Any], sid: String, name: String) -> CoreEvent {
        let tool = Self.clean(obj["tool_name"] as? String, max: 60) ?? "a tool"
        let summary = Self.summarize(tool: tool, input: obj["tool_input"])
        let text = summary.isEmpty ? "Allow \(tool)?" : "Allow \(tool)? \(summary)"
        let suggestions = (obj["permission_suggestions"] as? [Any]) ?? []
        var chosen: Data?
        if !suggestions.isEmpty {
            let local = suggestions.first { ($0 as? [String: Any])?["destination"] as? String == "localSettings" }
            let pick = local ?? suggestions[0]
            if JSONSerialization.isValidJSONObject(pick) { chosen = try? JSONSerialization.data(withJSONObject: pick, options: [.sortedKeys]) }
        }
        var options = [RequestOption(id: "allow", label: "Allow", style: .primary),
                       RequestOption(id: "deny", label: "Deny", style: .destructive)]
        if chosen != nil { options.append(RequestOption(id: "always", label: "Always allow")) }
        let rid = UUID().uuidString
        remember(rid, Pending(suggestion: chosen))
        let req = AgentRequest(requestId: rid, type: .approval, text: text, options: options,
                               timeoutSeconds: Self.approvalTimeoutSeconds, defaultOptionId: nil)
        return .ask(sessionId: sid, request: req)
    }

    private func remember(_ id: String, _ p: Pending) {
        lock.lock(); defer { lock.unlock() }
        table[id] = p; order.append(id)
        while order.count > Self.maxPendingTable { table[order.removeFirst()] = nil }
    }

    private func take(_ id: String) -> Pending? {
        lock.lock(); defer { lock.unlock() }
        order.removeAll { $0 == id }
        return table.removeValue(forKey: id)
    }

    // MARK: encode

    public func encode(response: AgentResponse, for request: AgentRequest) -> Data {
        guard let pending = take(request.requestId) else { return Data() }
        guard response.reason == .answered, let opt = response.optionId else { return Data() }
        var decision: [String: Any]
        switch opt {
        case "allow":
            decision = ["behavior": "allow"]
        case "always":
            decision = ["behavior": "allow"]
            if let s = pending.suggestion, let entry = try? JSONSerialization.jsonObject(with: s) {
                decision["updatedPermissions"] = [entry]
            }
        case "deny":
            let msg = Self.clean(response.text, max: 200) ?? "Denied via AgentBar"
            decision = ["behavior": "deny", "message": msg]
        default:
            return Data()
        }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
    }

    // MARK: sanitizing helpers

    static func sessionName(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        let base = (cwd as NSString).lastPathComponent
        return clean(base, max: AgentBarLimits.maxNameLength) ?? "Claude Code"
    }

    /// Replaces control characters with spaces, collapses whitespace, trims and caps. nil when empty.
    static func clean(_ s: String?, max: Int) -> String? {
        guard let s else { return nil }
        var out = ""
        var lastSpace = true
        for u in s.unicodeScalars {
            let isCtl = u.properties.generalCategory == .control || u.properties.generalCategory == .format
                || u.properties.generalCategory == .lineSeparator || u.properties.generalCategory == .paragraphSeparator
            if isCtl || u.properties.isWhitespace {
                if !lastSpace { out.unicodeScalars.append(" "); lastSpace = true }
            } else {
                out.unicodeScalars.append(u); lastSpace = false
            }
            if out.count > max + 1 { break }
        }
        while out.hasSuffix(" ") { out.removeLast() }
        if out.isEmpty { return nil }
        return out.count > max ? String(out.prefix(max - 1)) + "…" : out
    }

    /// Short one-line description of tool input. Never dumps raw input.
    static func summarize(tool: String, input: Any?) -> String {
        guard let dict = input as? [String: Any] else { return "" }
        for key in ["command", "file_path", "path", "url", "pattern", "query", "notebook_path", "description"] {
            if let v = dict[key] as? String, let c = clean(v, max: 200) { return c }
        }
        // Fallback: key names only (no values), capped.
        let keys = dict.keys.sorted().prefix(6).joined(separator: ", ")
        return clean(keys.isEmpty ? nil : "(\(keys))", max: 80) ?? ""
    }
}
