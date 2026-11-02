import Foundation

/// Adapter for computer-use agents (agents that act on the screen). Payload for `agentbar hook --adapter computerUse`
/// (all but `session` optional; unknown keys ignored):
/// `{"session":ID,"name":N,"state":"working|idle|error|done|needsInput","action":TEXT,"supportsStop":BOOL,
///   "log":{"kind":"action|status|error","text":T}}`
/// `action` is the plain-text description of what the agent does right now (`currentAction`); every change lands in the
/// history as an action entry. All text is untrusted data: sanitized exactly like Claude Code text, never interpreted.
/// It never blocks and never creates approval requests (there is deliberately no one-click-allow path for agents
/// that control the screen; use `agentbar ask` for questions); the answer is always empty.
/// Pause/stop: the agent sets `supportsStop` and listens with `agentbar watch --session ID` (see CONTRACTS.md).
public struct ComputerUseAdapter: AgentAdapter {
    public init() {}
    public var kind: AgentKind { .computerUse }

    public func translate(payload: Data) throws -> [CoreEvent] {
        guard let o = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sid = o["session"] as? String, !sid.isEmpty, sid.count <= AgentBarLimits.maxIdLength else {
            throw CocoaError(.coderReadCorrupt)
        }
        let name = ClaudeCodeAdapter.clean(o["name"] as? String, max: AgentBarLimits.maxNameLength)
        // An explicitly empty action clears the current action.
        let action: String? = (o["action"] as? String).map { ClaudeCodeAdapter.clean($0, max: AgentBarLimits.maxActionLength) ?? "" }
        let state = (o["state"] as? String).flatMap(SessionState.init(rawValue:))
        let stop = o["supportsStop"] as? Bool
        var events: [CoreEvent] = [
            .sessionUpdate(id: sid, name: name, kind: .computerUse, state: state == .done ? nil : state,
                           action: action, supportsStop: stop)
        ]
        if let l = o["log"] as? [String: Any], let text = ClaudeCodeAdapter.clean(l["text"] as? String, max: 500) {
            let k = (l["kind"] as? String).flatMap(HistoryEntry.Kind.init(rawValue:)) ?? .action
            if k == .request || k == .answer { throw CocoaError(.coderInvalidValue) }
            events.append(.log(sessionId: sid, entry: HistoryEntry(kind: k, text: text)))
        }
        if state == .done { events.append(.sessionEnd(id: sid)) }
        return events
    }

    public func encode(response: AgentResponse, for request: AgentRequest) -> Data { Data() }
}
