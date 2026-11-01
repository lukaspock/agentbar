import Foundation

/// Hard limits from CONTRACTS.md. Shared by store and transport.
public enum AgentBarLimits {
    public static let maxLineBytes = 64 * 1024
    public static let maxPendingRequests = 100
    public static let maxTextLength = 4000
    public static let maxNameLength = 80
    public static let maxIdLength = 200
    public static let maxOptions = 6
    public static let maxHistory = 50
    public static let maxSessions = 100
    public static let maxTimeoutSeconds = 86_400
}

extension String {
    func capped(_ n: Int) -> String { count > n ? String(prefix(n)) : self }
}
