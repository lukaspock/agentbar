import SwiftUI
import AppKit
import AgentBarCore

/// What the notch panel shows instead of the session list. Everything that used to open its own window
/// (New session dialog, "Agent user…" alert) is a page here. Settings and the macOS folder dialog stay system windows.
@MainActor
final class PanelRouter: ObservableObject {
    static let shared = PanelRouter()

    enum Page: Equatable { case newSession, agentUser }

    @Published private(set) var page: Page?
    @Published private(set) var flow: NewSessionFlowModel?
    /// Set by the shell: select the freshly started session in the panel.
    var onSessionStarted: ((String) -> Void)?
    private var keyMonitor: Any?

    /// Opens the inline New session flow (no-op while it is already open).
    func openNewSession() {
        guard flow == nil, ChatHub.shared.backend != nil else { return }
        let model = NewSessionFlowModel(host: AgentHostHub.shared.client, prefs: PreferencesHub.shared.store)
        model.onClose = { [weak self] in self?.close() }
        model.onStarted = { [weak self] id in self?.onSessionStarted?(id) }
        flow = model
        page = .newSession
        installKeyMonitor()
        model.applyDemoPreset(LaunchOptions.current)
    }

    func openAgentUser() {
        guard flow == nil else { return }    // never replace a half-filled flow
        page = .agentUser
    }

    func close() {
        removeKeyMonitor()
        flow = nil
        page = nil
    }

    // MARK: keyboard (Return = next, Esc = back) while the flow is open

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode, isRepeat = event.isARepeat
            let inBar = event.window is BarPanel
            let typing = event.window?.firstResponder is NSTextView
            let consumed = MainActor.assumeIsolated { self?.handleKey(code: code, isRepeat: isRepeat, inBar: inBar, typing: typing) ?? false }
            return consumed ? nil : event
        }
    }

    private func handleKey(code: UInt16, isRepeat: Bool, inBar: Bool, typing: Bool) -> Bool {
        guard let flow, inBar else { return false }
        // A text field in editing mode handles Return/Esc itself (see InlineTextField).
        if typing { return false }
        switch code {
        case 36, 76:                       // Return, keypad Enter
            if !isRepeat { flow.advance() }   // a held key must never run through several steps
            return true
        case 53:                           // Esc
            if !isRepeat { flow.back() }
            return true
        default: return false
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
