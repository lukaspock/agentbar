import Foundation

/// Phase 12: messages the user queues in the panel for a terminal (hook) session. Delivered as the hook output of the
/// session's next `Stop` event (`{"decision":"block","reason":...}`), never into an idle terminal. See CONTRACTS.md.
public enum MessageQueueLimits {
    /// Max characters of one queued message (after sanitizing).
    public static let maxMessageLength = 1000
    /// Max waiting messages per session.
    public static let maxQueuedPerSession = 3
    /// A message that waited longer than this is dropped (with a history note) instead of being delivered: it may no longer
    /// match what Claude is doing.
    public static let maxAge: TimeInterval = 30 * 60
    /// History prefix of a delivered queued message; the transcript shows it as a user bubble marked "delivered".
    public static let deliveredPrefix = "You (queued): "
}

public enum QueueResult: Equatable, Sendable {
    case queued(UUID)
    case empty
    case tooLong
    case queueFull
    /// Unknown session, not a Claude Code hook session, or its origin is unknown (chat, demo, old data).
    case notAvailable
}

/// Write side of the queue for the UI (implemented by `SessionStore` and the demo store).
@MainActor
public protocol MessageQueueSink: AnyObject {
    func queueMessage(_ text: String, sessionId: String) -> QueueResult
    @discardableResult func cancelQueuedMessage(id: UUID, sessionId: String) -> Bool
}

/// A hook event at which the adapter allows delivering a queued message (additive adapter hook, default none).
public struct QueueDeliveryPoint: Equatable, Sendable {
    public let sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
}

public extension AgentSession {
    /// The panel offers "queue a message" only for Claude Code hook sessions whose origin role is known. Delivery additionally
    /// requires that the Stop event comes from that same role (see `SessionStore.deliverQueuedMessage`).
    var canQueueMessage: Bool { kind == .claudeCode && originRole != nil }
}

public extension QueuedMessage {
    /// Sanitized message text: control, format and bidi characters become U+FFFD, tabs spaces, at most two newlines in a row,
    /// trimmed. nil when nothing is left.
    static func sanitize(_ raw: String) -> String? {
        let t = ClaudeCodeAdapter.multiLine(raw)
        return t.isEmpty ? nil : t
    }

    /// Character and scalar count, the larger one (one grapheme can carry thousands of scalars).
    static func size(of s: String) -> Int { max(s.count, s.unicodeScalars.count) }
}
