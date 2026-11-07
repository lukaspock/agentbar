import Foundation

/// Message split of the history convention: "You: ..." (answer) = user message, "Claude: ..." (status) = agent text,
/// errors = error bubble, everything else = small dimmed side note. Used for chat sessions and hook sessions alike.
public enum ChatLine: Equatable, Sendable {
    case user(String)
    case agent(String)
    case error(String)
    case note(String)

    public static func parse(_ e: HistoryEntry) -> ChatLine {
        if e.kind == .answer, e.text.hasPrefix("You: ") { return .user(String(e.text.dropFirst(5))) }
        // Phase 12: a queued message that was delivered to Claude (the UI marks it "delivered").
        if e.kind == .answer, e.text.hasPrefix(MessageQueueLimits.deliveredPrefix) { return .user(String(e.text.dropFirst(MessageQueueLimits.deliveredPrefix.count))) }
        if e.kind == .error { return .error(e.text) }
        if e.kind == .status, e.text.hasPrefix("Claude: ") { return .agent(String(e.text.dropFirst(8))) }
        return .note(e.text)
    }
}
