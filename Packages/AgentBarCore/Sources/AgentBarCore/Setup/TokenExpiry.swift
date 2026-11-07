import Foundation

/// Age check of the Claude OAuth token from `claude setup-token`.
///
/// The Claude Code docs describe this token as valid for one year. Assumption: the token file's modification time is
/// the issue date, because the file is written once during setup (and rewritten on every new sign-in). The token's
/// content is never read, so this is an estimate, not the server-side expiry.
public enum TokenExpiry: Equatable, Sendable {
    case ok
    /// `days` = full days left until the assumed expiry (35 on the first warning day, at least 1).
    case expiresSoon(days: Int)
    case expired
    /// No modification time available.
    case unknown

    public static let validity: TimeInterval = 365 * 86_400
    /// Warning starts this long after issue (35 days before the assumed expiry).
    public static let warnAfter: TimeInterval = 330 * 86_400

    /// Pure: mtime (seconds since 1970) and the current time -> status. A future mtime (clock skew) counts as fresh.
    public static func status(mtime: Int?, now: Date) -> TokenExpiry {
        guard let mtime else { return .unknown }
        let age = now.timeIntervalSince1970 - TimeInterval(mtime)
        if age >= validity { return .expired }
        if age >= warnAfter { return .expiresSoon(days: max(0, Int(((validity - age) / 86_400).rounded(.up)))) }
        return .ok
    }

    /// Full days until the assumed expiry (0 when expired); nil without mtime.
    public static func daysLeft(mtime: Int?, now: Date) -> Int? {
        guard let mtime else { return nil }
        return max(0, Int(((validity - (now.timeIntervalSince1970 - TimeInterval(mtime))) / 86_400).rounded(.up)))
    }

    /// Row/hint text, nil when nothing needs to be said.
    public var message: String? {
        switch self {
        case .expired: return "Token expired — sign in again"
        case .expiresSoon(let d): return d == 1 ? "Token expires in 1 day — sign in again" : "Token expires in \(d) days — sign in again"
        case .ok, .unknown: return nil
        }
    }
}
