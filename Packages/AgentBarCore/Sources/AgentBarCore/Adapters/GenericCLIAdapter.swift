import Foundation

/// Adapter for arbitrary CLI agents that can pipe one JSON object to `agentbar hook --adapter genericCLI`.
/// Payload (all but `session` optional; unknown keys are ignored):
/// `{"session":ID,"name":N,"state":"working|done|error|idle|needsInput","action":TEXT,
///   "log":{"kind":"status|action|error","text":T}}`
/// It never blocks and never creates approval requests (use `agentbar ask` for that); the answer is always empty.
public struct GenericCLIAdapter: AgentAdapter {
    public init() {}
    public var kind: AgentKind { .genericCLI }

    public func translate(payload: Data) throws -> [CoreEvent] {
        guard let o = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let sid = o["session"] as? String, !sid.isEmpty, sid.count <= AgentBarLimits.maxIdLength else {
            throw CocoaError(.coderReadCorrupt)
        }
        var events: [CoreEvent] = []
        let state = (o["state"] as? String).flatMap(SessionState.init(rawValue:))
        if state == .done {
            events.append(.sessionUpdate(id: sid, name: o["name"] as? String, kind: .genericCLI, state: nil,
                                         action: o["action"] as? String, supportsStop: nil))
            events.append(.sessionEnd(id: sid))
        } else {
            events.append(.sessionUpdate(id: sid, name: o["name"] as? String, kind: .genericCLI, state: state,
                                         action: o["action"] as? String, supportsStop: nil))
        }
        if let l = o["log"] as? [String: Any], let text = l["text"] as? String {
            let k = (l["kind"] as? String).flatMap(HistoryEntry.Kind.init(rawValue:)) ?? .status
            if k != .request && k != .answer { events.append(.log(sessionId: sid, entry: HistoryEntry(kind: k, text: text))) }
        }
        return events
    }

    public func encode(response: AgentResponse, for request: AgentRequest) -> Data { Data() }
}
