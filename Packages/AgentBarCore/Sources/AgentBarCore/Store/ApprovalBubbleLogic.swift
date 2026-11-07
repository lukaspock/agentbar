import Foundation

/// Which open request is shown where: the oldest request of the SELECTED session becomes a bubble at the end of its
/// conversation, every other session keeps its card on top. Pure, so it can be tested without a UI.
public enum RequestPlacement {
    public struct Item {
        public let sessionId: String
        public let request: AgentRequest
        /// true => shown as conversation bubble, false => card on top of the panel.
        public let inBubble: Bool
        /// Further requests of the same session behind this one ("+N more waiting").
        public let extra: Int
        /// Identity for `ApprovalClickGuard`. A request that moves between card and bubble gets a NEW key, so its
        /// buttons are disarmed again for the settle window (it is at a different position on screen).
        public var guardKey: String { (inBubble ? "bubble:" : "card:") + request.requestId }
    }

    /// One entry per session (its oldest pending request) in the stable card order (`RequestOrdering`).
    /// `bubbleSessionId` must be nil when the conversation of that session is not visible (no selection, other page open).
    public static func place(sessions: [AgentSession], bubbleSessionId: String?) -> [Item] {
        let open = RequestOrdering.stable(sessions.compactMap { s in s.pendingRequests.first.map { (s.id, $0) } })
        return open.map { o in
            let extra = (sessions.first { $0.id == o.sessionId }?.pendingRequests.count ?? 1) - 1
            return Item(sessionId: o.sessionId, request: o.request, inBubble: o.sessionId == bubbleSessionId, extra: extra)
        }
    }
}

/// Remaining time of a request before the app stops waiting (`AgentRequest.timeoutSeconds`, counted from `createdAt`).
public enum RequestTimeout {
    public static func remainingSeconds(_ r: AgentRequest, now: Date) -> Int? {
        guard let t = r.timeoutSeconds, t > 0 else { return nil }
        return max(0, Int((r.createdAt.addingTimeInterval(TimeInterval(t)).timeIntervalSince(now)).rounded(.up)))
    }

    /// What really happens at the timeout: with `defaultOptionId == "deny"` the request is declined; with no default
    /// the store resolves it without a decision (Claude Code then shows its own terminal dialog). nil = nothing to show.
    public static func note(_ r: AgentRequest, now: Date) -> String? {
        guard let s = remainingSeconds(r, now: now) else { return nil }
        let clock = String(format: "%d:%02d", s / 60, s % 60)
        switch r.defaultOptionId {
        case "deny"?: return "auto-declines in \(clock)"
        case nil: return "terminal prompt takes over in \(clock)"
        default: return nil   // another default option: unknown consequence, do not claim anything
        }
    }
}

/// Transcript preparation for the approval bubble.
public enum ApprovalTranscript {
    /// Single line, control characters removed, bounded. nil when empty.
    public static func oneLine(_ s: String?, max: Int) -> String? { ClaudeCodeAdapter.clean(s, max: max) }

    /// History for display: the `.request` note whose text is the open bubble request is hidden (the bubble shows it),
    /// and the store's `answered: <label>[: reason]` notes read "Allowed" / "Denied: reason".
    public static func display(history: [HistoryEntry], bubble: AgentRequest?) -> [HistoryEntry] {
        var hide: UUID?
        if let bubble { hide = history.last { $0.kind == .request && $0.text == bubble.text }?.id }
        return history.compactMap { e in
            if e.id == hide { return nil }
            guard e.kind == .answer else { return e }
            var c = e
            c.text = friendlyAnswer(e.text)
            return c
        }
    }

    static func friendlyAnswer(_ t: String) -> String {
        if t == "cancelled" { return "Cancelled" }
        if t == "timeout" { return "Timed out, answer in the terminal" }
        if t.hasPrefix("timeout (") { return "Timed out " + t.dropFirst("timeout ".count) }
        guard t.hasPrefix("answered: ") else { return t }
        let rest = String(t.dropFirst("answered: ".count))
        let (label, reason): (String, String?) = {
            guard let r = rest.range(of: ": ") else { return (rest, nil) }
            return (String(rest[..<r.lowerBound]), String(rest[r.upperBound...]))
        }()
        let word: String
        switch label {
        case "Allow", "Yes": word = "Allowed"
        case "Always allow", "Always": word = "Always allowed"
        case "Deny", "No": word = "Denied"
        default: return t.replacingOccurrences(of: "answered: ", with: "Answered: ", options: .anchored)
        }
        return reason.map { word + ": " + $0 } ?? word
    }
}
