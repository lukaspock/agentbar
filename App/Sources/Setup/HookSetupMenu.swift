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
        let item = NSMenuItem(title: "Hooks einrichten…", action: #selector(HookSetupMenu.run), keyEquivalent: "")
        item.target = shared
        return item
    }

    /// Optional override of the CLI location (UserDefaults key `AgentBarCLIPath`).
    private var cliPath: String? {
        HookSetup.locateCLI(override: UserDefaults.standard.string(forKey: "AgentBarCLIPath"))
    }

    @objc func run() {
        guard let cli = cliPath else {
            info("agentbar-CLI nicht gefunden",
                 "Das Kommandozeilenprogramm „agentbar“ liegt weder neben der App noch in deren Resources. Es wird für die Hooks benötigt.")
            return
        }
        let setup = HookSetup(agentbarPath: cli)
        do {
            let plan = try setup.planInstall()
            if plan.isNoOp {
                // Already installed: offer removal instead.
                let r = present(title: "Hooks sind bereits eingerichtet", preview: plan.preview,
                                buttons: ["Schließen", "Entfernen…"])
                if r == .alertSecondButtonReturn { uninstall(setup) }
                return
            }
            let r = present(title: "Claude-Code-Hooks einrichten?", preview: plan.preview + "\nNeue Claude-Code-Sitzungen müssen neu gestartet werden. Vor dem Schreiben wird ein Backup angelegt.",
                            buttons: ["Abbrechen", "Einrichten"])
            guard r == .alertSecondButtonReturn else { return }
            try finish(setup.apply(plan, confirm: { _ in true }))
        } catch { info("Hooks konnten nicht eingerichtet werden", "\(error)") }
    }

    private func uninstall(_ setup: HookSetup) {
        do {
            let plan = try setup.planUninstall()
            let r = present(title: "AgentBar-Hooks entfernen?", preview: plan.preview, buttons: ["Abbrechen", "Entfernen"])
            guard r == .alertSecondButtonReturn else { return }
            try finish(setup.apply(plan, confirm: { _ in true }))
        } catch { info("Hooks konnten nicht entfernt werden", "\(error)") }
    }

    private func finish(_ outcome: HookSetup.Outcome) {
        if case let .applied(backup) = outcome {
            info("Fertig", backup.map { "Backup: \($0.path)" } ?? "Neue Datei angelegt.")
        }
    }

    /// First button is the default button (Return). It is always the harmless one.
    private func present(title: String, preview: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Prüfe die Änderung an ~/.claude/settings.json:"
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
