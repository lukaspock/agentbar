import Foundation

/// Stable card order for the request cards: oldest request first (ties by request id). The session state never
/// influences the order, so a card can not jump under the pointer when another session changes state.
public enum RequestOrdering {
    public static func stable(_ items: [(sessionId: String, request: AgentRequest)]) -> [(sessionId: String, request: AgentRequest)] {
        items.sorted {
            if $0.request.createdAt != $1.request.createdAt { return $0.request.createdAt < $1.request.createdAt }
            return $0.request.requestId < $1.request.requestId
        }
    }
}

/// Click-through protection for approval buttons (clickjacking / "card moved under the pointer").
/// A card's buttons are armed only if the card (a) has been visible at its current position for `settleInterval`,
/// (b) still sits at the position it was rendered for, and (c) the panel layout (height/expansion) has been still
/// for `settleInterval`. Unknown cards are never armed. Pure value type: the UI feeds it `observe`/`layoutChanged`.
public struct ApprovalClickGuard {
    public static let settleInterval: TimeInterval = 0.5

    private var slots: [String: (index: Int, since: Date)] = [:]
    private var layoutSince: Date = .distantPast
    public init() {}

    /// Call whenever the ordered list of card ids may have changed. New cards and cards that changed position restart the window.
    public mutating func observe(order: [String], now: Date) {
        var next: [String: (index: Int, since: Date)] = [:]
        for (i, id) in order.enumerated() {
            if let old = slots[id], old.index == i { next[id] = old } else { next[id] = (i, now) }
        }
        slots = next
    }

    /// The panel height changed, the panel expanded, or anything else moved all cards.
    public mutating func layoutChanged(now: Date) { layoutSince = now }

    /// `currentOrder` is the order at click time (not the one at render time).
    public func isArmed(_ requestId: String, currentOrder: [String], now: Date) -> Bool {
        guard let slot = slots[requestId], currentOrder.firstIndex(of: requestId) == slot.index else { return false }
        return now.timeIntervalSince(slot.since) >= Self.settleInterval
            && now.timeIntervalSince(layoutSince) >= Self.settleInterval
    }
}
