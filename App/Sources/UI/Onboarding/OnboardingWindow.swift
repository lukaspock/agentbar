import SwiftUI
import AppKit
import AgentBarCore

/// Normal (non-floating) window for the first-run onboarding. One instance; calling `show` again fronts it.
/// Deliberate exception to "no new windows": the user asked for a regular onboarding window.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private static var current: OnboardingWindowController?
    private let window: NSWindow
    private let later: @MainActor () -> Void
    private var finished = false

    static var isShown: Bool { current != nil }

    static func show(runner: any SetupRunning, mascot: MascotAppearance = .standard, actions: OnboardingActions = OnboardingActions(),
                     page: OnboardingModel.Page = .welcome) {
        if let c = current {
            c.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)   // LSUIElement app: needs an explicit activation to come forward
            return
        }
        let c = OnboardingWindowController(runner: runner, mascot: mascot, actions: actions, page: page)
        current = c
        c.window.center()
        NSApp.activate(ignoringOtherApps: true)
        c.window.makeKeyAndOrderFront(nil)
    }

    static func close() { current?.window.close() }

    private init(runner: any SetupRunning, mascot: MascotAppearance, actions: OnboardingActions, page: OnboardingModel.Page) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        later = actions.later
        super.init()
        var wired = actions
        wired.later = { [weak self] in self?.finished = true; actions.later(); self?.window.close() }
        wired.finish = { [weak self] in self?.finished = true; actions.finish(); self?.window.close() }
        window.title = "Welcome to AgentBar"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.075, green: 0.075, blue: 0.09, alpha: 1)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(runner: runner, mascot: mascot, actions: wired, page: page))
    }

    func windowWillClose(_ notification: Notification) {
        // Closing with the red button counts as "Later".
        if !finished { finished = true; later() }
        Self.current = nil
    }
}
