import Foundation
import ServiceManagement
import AgentBarCore

/// Launch-at-login via `SMAppService.mainApp`. No UI; register/unregister run only on explicit call.
struct LoginItemController: SetupLoginItemControlling {
    enum LoginItemError: Error, LocalizedError, Equatable {
        case requiresApproval
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .requiresApproval: return "Approve AgentBar in System Settings > General > Login Items."
            case .failed(let reason): return "Login item change failed: \(reason)"
            }
        }
    }

    static func map(_ status: SMAppService.Status) -> SetupLoginItemState {
        switch status {
        case .enabled: return .enabled
        case .notRegistered: return .notRegistered
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func state() async -> SetupLoginItemState { Self.map(SMAppService.mainApp.status) }

    /// Registers the app as login item. Throws `requiresApproval` when the user still has to enable it in System Settings.
    @discardableResult
    func register() throws -> SetupLoginItemState {
        let service = SMAppService.mainApp
        if service.status != .enabled {
            do { try service.register() } catch {
                // register() can throw while the item merely waits for approval; report that precisely.
                if service.status == .requiresApproval { throw LoginItemError.requiresApproval }
                throw LoginItemError.failed(error.localizedDescription)
            }
        }
        let result = Self.map(service.status)
        if result == .requiresApproval { throw LoginItemError.requiresApproval }
        return result
    }

    @discardableResult
    func unregister() throws -> SetupLoginItemState {
        let service = SMAppService.mainApp
        if service.status != .notRegistered {
            do { try service.unregister() } catch { throw LoginItemError.failed(error.localizedDescription) }
        }
        return Self.map(service.status)
    }

    /// Opens System Settings > Login Items (for the `requiresApproval` case).
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
