import AppKit
import Combine
import AgentBarCore

extension Notification.Name {
    /// Posted (main thread) when a request appeared that was not known before and auto-expand is enabled.
    static let agentBarAutoExpand = Notification.Name("AgentBarAutoExpand")
}

/// User preferences for how a new request gets attention. Stored in UserDefaults.
enum AttentionSettings {
    static let soundKey = "soundOnNewRequest"
    static let autoExpandKey = "autoExpandOnNewRequest"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [soundKey: true, autoExpandKey: false])
    }
    static var soundEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: soundKey) }
        set { UserDefaults.standard.set(newValue, forKey: soundKey) }
    }
    static var autoExpandEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoExpandKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoExpandKey) }
    }
}

/// Watches the store for newly appeared requests: one quiet system sound (default on) and optionally a short auto-expand (default off).
/// Requests that exist at startup do not trigger anything.
@MainActor
final class AttentionNotifier {
    private var known: Set<String> = []
    private var bag = Set<AnyCancellable>()
    private var sound: NSSound?

    init<S: SessionStoreReading>(store: S) {
        known = Set(store.sessions.flatMap { $0.pendingRequests.map(\.requestId) })
        store.objectWillChange
            .receive(on: DispatchQueue.main)   // delivered after the change has been applied
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                MainActor.assumeIsolated { self.check(store.sessions) }
            }
            .store(in: &bag)
    }

    private func check(_ sessions: [AgentSession]) {
        let ids = Set(sessions.flatMap { $0.pendingRequests.map(\.requestId) })
        let fresh = ids.subtracting(known)
        known = ids
        guard !fresh.isEmpty else { return }
        NSLog("[attention] %d new request(s) sound=%d autoExpand=%d", fresh.count,
              AttentionSettings.soundEnabled ? 1 : 0, AttentionSettings.autoExpandEnabled ? 1 : 0)
        if AttentionSettings.soundEnabled { playSound() }
        if AttentionSettings.autoExpandEnabled { NotificationCenter.default.post(name: .agentBarAutoExpand, object: nil) }
    }

    private func playSound() {
        let s = NSSound(named: "Tink")
        s?.volume = 0.3
        sound = s
        s?.play()
    }
}
