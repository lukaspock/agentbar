import Foundation
import UserNotifications
import AgentBarCore

/// Notification authorization. Reading the state never prompts; the system prompt appears only via `requestAuthorization()`.
struct NotificationPermission: SetupNotificationAuthorizing {
    /// Set once the system refused notifications for this build (UNErrorDomain code 1, typical for ad-hoc signed apps).
    private static let refusal = NSLock()
    private static var refused = false
    static var isRefused: Bool { refusal.lock(); defer { refusal.unlock() }; return refused }
    private static func markRefused() { refusal.lock(); refused = true; refusal.unlock() }

    /// UNErrorDomain code 1 = UNErrorCodeNotificationsNotAllowed.
    static func isNotAllowedError(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == UNErrorDomain && e.code == UNError.Code.notificationsNotAllowed.rawValue
    }

    static func map(_ status: UNAuthorizationStatus) -> SetupNotificationState {
        switch status {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func authorizationState() async -> SetupNotificationState {
        if Self.isRefused { return .unavailable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    /// Explicit user action only. Shows the system prompt if undetermined; returns the resulting state.
    func requestAuthorization() async throws -> SetupNotificationState {
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        catch where Self.isNotAllowedError(error) { Self.markRefused(); return .unavailable }   // optional feature: never an error
        return await authorizationState()
    }
}
