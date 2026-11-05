import Foundation
import AgentBarCore

/// Launch arguments: --demo-onboarding [page], --onboarding-force, --demo, --demo-state <name>, --demo-expanded, --presentation notch|pill|circle
/// DEBUG only: --auto-answer <optionId> (answers the first pending request 2 s after it appears).
struct LaunchOptions {
    var demo = false
    var demoState: String?
    var demoExpanded = false
    var presentation: PresentationStyle?
    var autoAnswer: String?
    var demoAgentHost: String?    // --demo-agenthost on|off: fake agent host (available or not)
    var demoAgentChat = false     // --demo-agent-chat: demo chat session counts as started via the agent target
    var demoNewChatAgent = false
    var demoNewChat = false       // --demo-new-chat: open the inline New session flow right after launch (screenshots)
    var demoFlowStep: String?     // --demo-flow-step bot|project|start: jump to that step (needs --demo-new-chat)
    var demoFlowFolder: String?   // --demo-flow-folder <path>: preset local folder (the system folder dialog cannot be scripted)
    var demoFlowNewName: String?  // --demo-flow-newname <text>: preset the "New workspace" name (validation screenshots)
    var demoFlowBot: String?      // --demo-flow-bot <bot name>: preselect a bot (its default folder/workspace preselects the project)
    var demoRename: String?       // --demo-rename <sessionId>: open the inline rename/color editor of that row
    var demoAgentUser = false     // --demo-agent-user: show the inline "Agent user" status in the panel
    var demoSelect: String?       // --demo-select <sessionId>: start with this session selected (screenshots)
    var prefsFile: URL?           // --prefs-file <path>: personalization file instead of ~/Library/Application Support/AgentBar
    var demoBotSkill: String?     // --demo-bot-skill <text>: prefill the skill field of the new-bot editor (validation screenshots)
    var demoSettings: String?     // --demo-settings theme|bots|editor: open the Settings window right after launch (screenshots)
    var demoOnboarding: String?   // --demo-onboarding [welcome|login|setup|done|error]: onboarding with a fake runner; touches nothing real
    var onboardingForce = false   // --onboarding-force: show the onboarding at start even if it was completed

    static let current = LaunchOptions(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        var i = 1
        while i < arguments.count {
            let next: String? = i + 1 < arguments.count ? arguments[i + 1] : nil
            switch arguments[i] {
            case "--demo": demo = true
            case "--demo-expanded": demoExpanded = true
            case "--demo-state": demo = true; demoState = next; i += 1
            case "--demo-agenthost": demoAgentHost = next; i += 1
            case "--demo-agent-chat": demoAgentChat = true
            case "--demo-new-chat": demoNewChat = true
            case "--demo-new-chat-agent": demoNewChat = true; demoNewChatAgent = true
            case "--demo-select": demoSelect = next; i += 1
            case "--demo-flow-step": demoFlowStep = next; i += 1
            case "--demo-flow-folder": demoFlowFolder = next; i += 1
            case "--demo-flow-bot": demoFlowBot = next; i += 1
            case "--demo-flow-newname": demoFlowNewName = next; i += 1
            case "--demo-rename": demoRename = next; i += 1
            case "--demo-agent-user": demoAgentUser = true
            case "--prefs-file": prefsFile = next.map { URL(fileURLWithPath: $0) }; i += 1
            case "--demo-bot-skill": demoBotSkill = next; i += 1
            case "--demo-settings": demoSettings = next ?? "theme"; i += 1
            case "--demo-onboarding":
                demo = true
                if let n = next, !n.hasPrefix("--") { demoOnboarding = n; i += 1 } else { demoOnboarding = "welcome" }
            case "--onboarding-force": onboardingForce = true
            case "--presentation": presentation = next.flatMap(PresentationStyle.init(rawValue:)); i += 1
            #if DEBUG
            case "--auto-answer": autoAnswer = next; i += 1
            #endif
            default: break
            }
            i += 1
        }
        // The onboarding demo must never read or write the real preferences (mascot, settings window).
        if demoOnboarding != nil, prefsFile == nil {
            prefsFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentbar-demo-onboarding-prefs.json")
        }
    }
}

/// The store behind the UI: the scripted fake for `--demo`, the real `SessionStore` otherwise.
enum AppBackend {
    case demo(FakeSessionStore)
    case live(SessionStore)
}

@MainActor
final class AppEnvironment {
    let options: LaunchOptions
    let backend: AppBackend
    private(set) var server: TransportServer?
    private var autoAnswerTask: Task<Void, Never>?
    private(set) var attention: AttentionNotifier?
    /// Owner-side personalization store, created once here and shared through `PreferencesHub.shared`.
    let preferences = PreferencesHub.shared.store

    init(options: LaunchOptions = .current) {
        self.options = options
        backend = options.demo ? .demo(FakeSessionStore.make(options: options)) : .live(SessionStore())
        if case .demo(let fake) = backend {
            ChatHub.shared.backend = FakeChatBackend(store: fake, chatIds: FakeSessionStore.chatSessionIds,
                                                    agentIds: options.demoAgentChat ? FakeSessionStore.chatSessionIds : [])
        }
        if let mode = options.demoAgentHost { AgentHostHub.shared.client = FakeAgentHostClient(available: mode != "off") }
        AttentionSettings.registerDefaults()
        switch backend {
        case .demo(let store): attention = AttentionNotifier(store: store)
        case .live(let store): attention = AttentionNotifier(store: store)
        }
    }

    /// Directory of socket + token. `AGENTBAR_DIR` (same variable the CLI honors) overrides the default.
    static var transportDirectory: URL {
        if let d = ProcessInfo.processInfo.environment["AGENTBAR_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return TransportServer.defaultDirectory
    }

    /// Starts the transport for the live backend. Throws `TransportServer.ServerError` on failure
    /// (`.alreadyRunning` means another instance owns the socket). No-op in demo mode.
    func startTransport() throws {
        guard case .live(let store) = backend else { return }
        store.startMaintenance()
        ChatHub.shared.backend = LiveChatBackend(store: store)
        // Two-user mode only if the agent user and the IPC group exist (created by the admin setup script) and no explicit
        // AGENTBAR_DIR override is active; otherwise exactly the single-user transport of old.
        let overridden = !(ProcessInfo.processInfo.environment["AGENTBAR_DIR"] ?? "").isEmpty
        let s = TransportServer(store: store, adapters: AdapterRegistry.make(), directory: Self.transportDirectory,
                                security: overridden ? .singleUser : .detected())
        try s.start()
        server = s
        AgentHostHub.shared.client = LiveAgentHostClient(host: s.hostClient)
        (ChatHub.shared.backend as? LiveChatBackend)?.hostClient = s.hostClient
        #if DEBUG
        if let option = options.autoAnswer { startAutoAnswer(store: store, optionId: option) }
        #endif
    }

    func stopTransport() {
        server?.stop()
        server = nil
        autoAnswerTask?.cancel()
    }

    #if DEBUG
    /// Debug aid for scripted end-to-end runs without UI automation: answers every pending request 2 s after it appeared.
    private func startAutoAnswer(store: SessionStore, optionId: String) {
        autoAnswerTask = Task { @MainActor [weak store] in
            var seen = Set<String>()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let store else { return }
                for s in store.sessions {
                    for r in s.pendingRequests where Date().timeIntervalSince(r.createdAt) >= 2 && !seen.contains(r.requestId) {
                        seen.insert(r.requestId)
                        let option = r.options.contains { $0.id == optionId } || r.options.isEmpty ? optionId : nil
                        store.respond(AgentResponse(requestId: r.requestId, optionId: option, text: r.options.isEmpty ? optionId : nil), sessionId: s.id)
                    }
                }
            }
        }
    }
    #endif
}
