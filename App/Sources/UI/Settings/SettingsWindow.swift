import SwiftUI
import AppKit

/// Which part of the settings to show first (also used by the `--demo-settings` screenshot flag).
enum SettingsPage: String { case theme, bots, editor, mascot }

/// Normal (non-floating) window for the personalization settings. One instance; reopening fronts it.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static var current: SettingsWindowController?
    private let window: NSWindow

    static func show(page: SettingsPage = .theme) {
        if let c = current {
            c.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let c = SettingsWindowController(page: page)
        current = c
        c.window.center()
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
    }

    private init(page: SettingsPage) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "AgentBar Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(hub: PreferencesHub.shared, page: page))
    }

    func windowWillClose(_ notification: Notification) { Self.current = nil }
}
