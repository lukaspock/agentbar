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
    /// Optional one-line scope/consequence shown under the button (additive; e.g. where an "always" rule applies).
    public var detail: String?
    public init(id: String, label: String, style: Style = .normal, detail: String? = nil) {
        self.id = id; self.label = label; self.style = style; self.detail = detail
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
    /// Absolute working directory the agent reported (hook `cwd`); additive, nil when unknown. Used only for
    /// "Continue in panel" (the fork starts there); it is validated again when a process is started.
    public var workingDirectory: String?
    /// Which transport role created/last claimed this session (set by the transport only; nil = unknown, e.g. chat, demo or
    /// data from an older version). "Continue in panel" requires `.owner`: a session of the agent user must never make the
    /// owner start a process in a directory the agent chose.
    public var originRole: PeerRole?
    /// Additive (Phase 12): messages the user wrote in the panel that wait for Claude's next hook `Stop` (oldest first). The store owns
    /// the queue; delivered or cancelled messages leave it (a delivery is recorded in `history`). Older data decodes as empty.
    public var queuedMessages: [QueuedMessage]
    public init(id: String, name: String, kind: AgentKind, state: SessionState = .idle,
                currentAction: String? = nil, pendingRequests: [AgentRequest] = [],
                history: [HistoryEntry] = [], updatedAt: Date = Date(), supportsStop: Bool = false,
                workingDirectory: String? = nil, originRole: PeerRole? = nil, queuedMessages: [QueuedMessage] = []) {
        self.workingDirectory = workingDirectory; self.originRole = originRole; self.queuedMessages = queuedMessages
        self.id = id; self.name = name; self.kind = kind; self.state = state
        self.currentAction = currentAction; self.pendingRequests = pendingRequests
        self.history = history; self.updatedAt = updatedAt; self.supportsStop = supportsStop
    }

    // Explicit decoder: `queuedMessages` was added later, data without it must still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(AgentKind.self, forKey: .kind)
        state = try c.decode(SessionState.self, forKey: .state)
        currentAction = try c.decodeIfPresent(String.self, forKey: .currentAction)
        pendingRequests = try c.decode([AgentRequest].self, forKey: .pendingRequests)
        history = try c.decode([HistoryEntry].self, forKey: .history)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        supportsStop = try c.decode(Bool.self, forKey: .supportsStop)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        originRole = try c.decodeIfPresent(PeerRole.self, forKey: .originRole)
        queuedMessages = try c.decodeIfPresent([QueuedMessage].self, forKey: .queuedMessages) ?? []
    }
}

/// A user message waiting in the queue of a hook session (Phase 12). Plain data; the rules live in `SessionStore`.
public struct QueuedMessage: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var text: String
    public var date: Date
    public init(id: UUID = UUID(), text: String, date: Date = Date()) { self.id = id; self.text = text; self.date = date }
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
