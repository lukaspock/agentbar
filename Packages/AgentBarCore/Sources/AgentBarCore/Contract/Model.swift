// FROZEN CONTRACT (owner: coordinator). Do not change signatures; request changes via the coordinator.
import Foundation

public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode, codex, genericCLI, computerUse
}

public enum SessionState: String, Codable, Sendable {
    case idle, working, needsInput, error, done
}

public enum RequestType: String, Codable, Sendable {
    case approval, question, info
}

public struct RequestOption: Codable, Sendable, Hashable, Identifiable {
    public enum Style: String, Codable, Sendable { case normal, primary, destructive }
    public var id: String            // approvals use "allow", "deny", "always"
    public var label: String
    public var style: Style
    public init(id: String, label: String, style: Style = .normal) {
        self.id = id; self.label = label; self.style = style
    }
}

public struct AgentRequest: Codable, Sendable, Identifiable, Hashable {
    public var requestId: String
    public var type: RequestType
    public var text: String                  // plain text, length-capped by the core
    public var options: [RequestOption]      // empty for free-text questions
    public var timeoutSeconds: Int?          // nil = no timeout
    public var defaultOptionId: String?      // applied on timeout (safe default, e.g. "deny")
    public var createdAt: Date
    public var id: String { requestId }
    public init(requestId: String, type: RequestType, text: String, options: [RequestOption] = [],
                timeoutSeconds: Int? = nil, defaultOptionId: String? = nil, createdAt: Date = Date()) {
        self.requestId = requestId; self.type = type; self.text = text; self.options = options
        self.timeoutSeconds = timeoutSeconds; self.defaultOptionId = defaultOptionId; self.createdAt = createdAt
    }
}

public struct HistoryEntry: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable { case status, action, request, answer, error }
    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var text: String
    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind, text: String) {
        self.id = id; self.date = date; self.kind = kind; self.text = text
    }
}

public struct AgentSession: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var kind: AgentKind
    public var state: SessionState
    public var currentAction: String?        // plain-text description (computer-use agents)
    public var pendingRequests: [AgentRequest]   // oldest first; the UI shows the first
    public var history: [HistoryEntry]       // capped by the store (max 50)
    public var updatedAt: Date
    public var supportsStop: Bool            // true => panel shows pause/stop button
    public init(id: String, name: String, kind: AgentKind, state: SessionState = .idle,
                currentAction: String? = nil, pendingRequests: [AgentRequest] = [],
                history: [HistoryEntry] = [], updatedAt: Date = Date(), supportsStop: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.state = state
        self.currentAction = currentAction; self.pendingRequests = pendingRequests
        self.history = history; self.updatedAt = updatedAt; self.supportsStop = supportsStop
    }
}

public struct AgentResponse: Codable, Sendable, Hashable {
    public enum Reason: String, Codable, Sendable { case answered, timeout, cancelled }
    public var requestId: String
    public var optionId: String?
    public var text: String?
    public var reason: Reason
    public init(requestId: String, optionId: String? = nil, text: String? = nil, reason: Reason = .answered) {
        self.requestId = requestId; self.optionId = optionId; self.text = text; self.reason = reason
    }
}
