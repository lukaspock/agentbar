import Foundation
import UserNotifications
import AgentBarCore

/// Notification authorization. Reading the state never prompts; the system prompt appears only via `requestAuthorization()`.
struct NotificationPermission: SetupNotificationAuthorizing {
    static func map(_ status: UNAuthorizationStatus) -> SetupNotificationState {
        switch status {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func authorizationState() async -> SetupNotificationState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.map(settings.authorizationStatus)
    }

    /// Explicit user action only. Shows the system prompt if undetermined; returns the resulting state.
    func requestAuthorization() async throws -> SetupNotificationState {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await authorizationState()
    }
}
