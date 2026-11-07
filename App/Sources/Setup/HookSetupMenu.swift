import AppKit
import AgentBarCore

/// Menu entry "Hooks einrichten…": shows the diff preview and writes only after the user presses "Einrichten".
/// Wire-up (coordinator): `AppHooks.menuItemFactories.append(HookSetupMenu.menuItemFactory)`.
@MainActor
final class HookSetupMenu: NSObject {
    static let shared = HookSetupMenu()
    /// For `AppHooks.menuItemFactories`.
    static let menuItemFactory: () -> NSMenuItem = { HookSetupMenu.makeMenuItem() }

    static func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Set Up Hooks…", action: #selector(HookSetupMenu.run), keyEquivalent: "")
        item.target = shared
        return item
    }

    /// Optional override of the CLI location (UserDefaults key `AgentBarCLIPath`).
    private var cliPath: String? {
        HookSetup.locateCLI(override: UserDefaults.standard.string(forKey: "AgentBarCLIPath"))
    }

    @objc func run() {
        guard let cli = cliPath else {
            info("agentbar CLI not found",
                 "The “agentbar” command-line tool is neither next to the app nor in its Resources. It is required for the hooks.")
            return
        }
        let setup = HookSetup(agentbarPath: cli)
        do {
            let plan = try setup.planInstall()
            if plan.isNoOp {
                // Already installed: offer removal instead.
                let r = present(title: "Hooks are already set up", preview: plan.preview,
                                buttons: ["Close", "Remove…"])
                if r == .alertSecondButtonReturn { uninstall(setup) }
                return
            }
            let r = present(title: "Set up Claude Code hooks?", preview: plan.preview + "\nNew Claude Code sessions must be restarted. A backup is created before writing.",
                            buttons: ["Cancel", "Set Up"])
            guard r == .alertSecondButtonReturn else { return }
            try finish(setup.apply(plan, confirm: { _ in true }))
        } catch { info("Hooks could not be set up", "\(error)") }
    }

    private func uninstall(_ setup: HookSetup) {
        do {
            let plan = try setup.planUninstall()
            let r = present(title: "AgentBar-Remove hooks?", preview: plan.preview, buttons: ["Cancel", "Remove"])
            guard r == .alertSecondButtonReturn else { return }
            try finish(setup.apply(plan, confirm: { _ in true }))
        } catch { info("Hooks could not be removed", "\(error)") }
    }

    private func finish(_ outcome: HookSetup.Outcome) {
        if case let .applied(backup) = outcome {
            info("Done", backup.map { "Backup: \($0.path)" } ?? "New file created.")
        }
    }

    /// First button is the default button (Return). It is always the harmless one.
    private func present(title: String, preview: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Review the change to ~/.claude/settings.json:"
        buttons.forEach { alert.addButton(withTitle: $0) }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false; tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.string = preview
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        alert.accessoryView = scroll
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private func info(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
}
