import AppKit

/// "Agent user…" menu entry: opens the host status as an inline card in the notch panel (no alert window).
/// Shows the host status and where the admin setup lives. Runs nothing.
@MainActor
enum AgentUserMenu {
    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Agent user…", action: #selector(Target.shared.show), keyEquivalent: "")
        item.target = Target.shared
        return item
    }

    @MainActor
    final class Target: NSObject {
        static let shared = Target()
        @objc func show() { PanelRouter.shared.openAgentUser() }
    }
}
