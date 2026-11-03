import SwiftUI
import AgentBarCore

/// How a session looks in the bar: display name, color and blob shape, resolved by the owner-side `PreferencesStore`
/// (session override > bot > agent default > theme > automatic tint). The name comes from app knowledge only (the
/// owner's rename, the bot, the project folder), never from agent text beyond the project name the bar always showed.
struct SessionLook {
    let displayName: String
    let colorHex: String
    let color: Color
    let kind: BlobKind
    /// Name of the bot this session was started with, if any.
    let botName: String?
    /// The owner renamed or recolored this very session.
    let customized: Bool

    /// The project/session name the bar always showed; the display name only adds to it.
    func project(of session: AgentSession) -> String? {
        displayName.caseInsensitiveCompare(session.name) == .orderedSame ? nil : session.name
    }

    static func resolve(_ s: AgentSession, store: PreferencesStore) -> SessionLook {
        let r = store.appearance(forSession: s.id, kind: s.kind, project: s.name)
        let botName = store.botID(forSession: s.id).flatMap { store.bot(id: $0)?.name }
        return SessionLook(displayName: r.displayName.isEmpty ? s.name : r.displayName,
                           colorHex: r.colorHex,
                           color: Color(hex: r.colorHex) ?? BlobKind.tint(forSession: s.id),
                           kind: BlobKind(storageName: r.blobKindName) ?? .forSession(s.id),
                           botName: botName,
                           customized: !store.sessionOverride(for: s.id).isEmpty)
    }

    /// Color of the collapsed circle: the most important agent's color (waiting, then error, then working, then the rest;
    /// newest first). nil when the aggregate is needs-input/error: those keep their warning color.
    static func aggregateTint(sessions: [AgentSession], state: SessionState, store: PreferencesStore) -> Color? {
        guard state != .needsInput, state != .error else { return nil }
        let top = sessions.min { a, b in
            let ra = SessionGrouping.rank(a), rb = SessionGrouping.rank(b)
            return ra != rb ? ra < rb : (a.updatedAt, b.id) > (b.updatedAt, a.id)
        }
        return top.map { resolve($0, store: store).color }
    }
}

/// Colors offered when renaming a session in the panel (the system color panel would be another window).
enum SessionSwatches {
    static let hexes = ["#FF8A7A", "#FFB35C", "#F2E06B", "#7BDE9A", "#5FD6D0", "#6FB3FF", "#A58BFF", "#FF8FC8", "#E6E6E6"]
}

/// Small colored capsule with the bot's name (chat header, approval card).
struct BotChip: View {
    let name: String
    let color: Color
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.22)))
        .help("Started with the bot \(name)")
    }
}
