import Foundation
import AgentBarCore

/// Sessions of one project (same display name, case-insensitive). The UI shows a header when a group has several sessions.
struct SessionGroup: Identifiable {
    let key: String
    let name: String
    let sessions: [AgentSession]
    var id: String { key }
    var waitingCount: Int { sessions.filter { $0.state == .needsInput || !$0.pendingRequests.isEmpty }.count }
}

/// Pure ordering rules for the session list. Deterministic and independent of `updatedAt`, so rows do not jump around
/// under the pointer while agents are busy: waiting first, then error, then working, then idle/done; ties by name, then id.
enum SessionGrouping {
    static func rank(_ s: AgentSession) -> Int {
        if s.state == .needsInput || !s.pendingRequests.isEmpty { return 0 }
        switch s.state {
        case .error: return 1
        case .working: return 2
        case .needsInput: return 0
        case .idle: return 3
        case .done: return 4
        }
    }

    static func groups(_ sessions: [AgentSession]) -> [SessionGroup] {
        var buckets: [String: [AgentSession]] = [:]
        var names: [String: String] = [:]
        for s in sessions {
            let key = s.name.lowercased()
            buckets[key, default: []].append(s)
            names[key] = names[key] ?? s.name
        }
        func order(_ a: AgentSession, _ b: AgentSession) -> Bool {
            rank(a) != rank(b) ? rank(a) < rank(b) : a.id < b.id
        }
        let groups = buckets.map { key, list in
            SessionGroup(key: key, name: names[key] ?? key, sessions: list.sorted(by: order))
        }
        return groups.sorted { a, b in
            let ra = a.sessions.map(rank).min() ?? 9, rb = b.sessions.map(rank).min() ?? 9
            return ra != rb ? ra < rb : a.key < b.key
        }
    }

    static func flat(_ sessions: [AgentSession]) -> [AgentSession] { groups(sessions).flatMap(\.sessions) }

    /// "now", "5m", "2h", "3d"
    static func shortAge(from date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 10 { return "now" }
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}
