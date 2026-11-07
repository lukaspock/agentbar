import Foundation
import Combine
import AgentBarCore

/// Scripted in-memory store for previews, screenshots and `--demo`. Conforms to both UI-facing protocols.
@MainActor
final class FakeSessionStore: SessionStoreReading, ResponseSink {
    @Published private(set) var sessions: [AgentSession] = []

    var aggregateState: SessionState {
        let states = sessions.map(\.state)
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.error) { return .error }
        if states.contains(.working) { return .working }
        return states.contains(.done) ? .done : .idle
    }

    static let chatSessionIds: Set<String> = ["chat1"]
    static let scenarioOrder = ["idle", "working", "needsInput", "computer", "question", "error"]
    private var timer: Timer?
    private var scriptIndex = 0

    static func make(options: LaunchOptions) -> FakeSessionStore {
        let store = FakeSessionStore()
        if options.demo { store.startDemo(state: options.demoState) }
        return store
    }

    func startDemo(state: String?) {
        if let state {
            load(state)
        } else {
            load(Self.scenarioOrder[0])
            timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scriptIndex = (self.scriptIndex + 1) % Self.scenarioOrder.count
                    self.load(Self.scenarioOrder[self.scriptIndex])
                }
            }
        }
    }

    func load(_ name: String) {
        let now = Date()
        func h(_ ago: TimeInterval, _ kind: HistoryEntry.Kind, _ text: String) -> HistoryEntry {
            HistoryEntry(date: now.addingTimeInterval(-ago), kind: kind, text: text)
        }
        let claudeHistory = [
            h(300, .status, "Session started"), h(240, .action, "Read Package.swift"),
            h(180, .action, "Edited SessionStore.swift"), h(90, .answer, "Allowed: swift build"),
            h(30, .action, "Running tests"),
        ]
        let approval = AgentRequest(requestId: "r1", type: .approval,
            text: "Run command: rm -rf node_modules && npm install",
            options: [RequestOption(id: "allow", label: "Allow", style: .primary),
                      RequestOption(id: "deny", label: "Deny", style: .destructive),
                      RequestOption(id: "always", label: "Always")],
            timeoutSeconds: 120, defaultOptionId: "deny")
        var list: [AgentSession]
        switch name {
        case "working":
            list = [AgentSession(id: "a", name: "notchy-app", kind: .claudeCode, state: .working, history: claudeHistory),
                    AgentSession(id: "b", name: "api-server", kind: .codex, state: .idle)]
        case "needsInput":
            list = [AgentSession(id: "a", name: "notchy-app", kind: .claudeCode, state: .needsInput,
                                 pendingRequests: [approval], history: claudeHistory),
                    AgentSession(id: "b", name: "api-server", kind: .codex, state: .working),
                    AgentSession(id: "c", name: "deploy.sh", kind: .genericCLI, state: .idle)]
        case "question":
            let q = AgentRequest(requestId: "q1", type: .question,
                text: "Which database should the new service use?", timeoutSeconds: nil)
            list = [AgentSession(id: "b", name: "api-server", kind: .codex, state: .needsInput, pendingRequests: [q],
                                 history: [h(120, .status, "Planning schema"), h(20, .request, "Asked about database")]),
                    AgentSession(id: "a", name: "notchy-app", kind: .claudeCode, state: .working)]
        case "many":
            let names: [(String, String, AgentKind, SessionState)] = [
                ("s-alpha", "notchy-app", .claudeCode, .needsInput), ("s-bravo", "api-server", .codex, .working),
                ("s-charlie", "deploy.sh", .genericCLI, .error), ("s-delta", "Browser Agent", .computerUse, .working),
                ("s-echo", "docs-site", .claudeCode, .idle), ("s-foxtrot", "data-sync", .codex, .done)]
            list = names.map { AgentSession(id: $0.0, name: $0.1, kind: $0.2, state: $0.3, supportsStop: $0.2 == .computerUse) }
        case "groups", "arrive", "history":
            var longHistory: [HistoryEntry] = []
            for i in 0..<30 {
                let ago = TimeInterval(1800 - i * 55)
                let kind: HistoryEntry.Kind = i % 7 == 0 ? .request : (i % 11 == 10 ? .error : .action)
                let text: String = i % 5 == 0 ? "Edited Sources/File\(i).swift and ran the whole test suite for this module again" : "Read File\(i).swift"
                longHistory.append(h(ago, kind, text))
            }
            list = [AgentSession(id: "aaaa11-x", name: "notchy-app", kind: .claudeCode, state: .working, history: longHistory),
                    AgentSession(id: "bbbb22-y", name: "notchy-app", kind: .claudeCode, state: name == "arrive" ? .working : .needsInput,
                                 pendingRequests: name == "arrive" ? [] : [approval], history: claudeHistory),
                    AgentSession(id: "cccc33-z", name: "Notchy-App", kind: .codex, state: .idle),
                    AgentSession(id: "d1", name: "api-server", kind: .codex, state: .working),
                    AgentSession(id: "e1", name: "docs-site", kind: .claudeCode, state: .done)]
            if name == "history" { list = Array(list.prefix(1)) }
            if name == "arrive" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let i = self.sessions.firstIndex(where: { $0.id == "d1" }) else { return }
                        self.sessions[i].pendingRequests = [approval]
                        self.sessions[i].state = .needsInput
                    }
                }
            }
        case "empty", "emptyarrive":   // no agents: the mascot shows; "emptyarrive" gets one agent after 5 s, which is closed after 12 s
            list = []
            if name == "emptyarrive" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    MainActor.assumeIsolated { self?.addSession(AgentSession(id: "a", name: "notchy-app", kind: .claudeCode, state: .working)) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                    MainActor.assumeIsolated { self?.remove(sessionId: "a") }
                }
            }
        case "chat", "hook":
            let chat = [h(200, .status, "Chat started in ~/Projects/agentbar"),
                        h(150, .answer, "You: Which targets does the project define?"),
                        h(140, .action, "Read project.yml"),
                        h(120, .status, "Claude: Two targets: the app and the agentbar CLI."),
                        h(60, .answer, "You: Please add a Stop button to the session row."),
                        h(30, .action, "Editing DetailPanel.swift"),
                        h(10, .error, "Tool call denied: rm -rf")]
            list = [AgentSession(id: "chat1", name: "agentbar", kind: .claudeCode, state: .working,
                                 currentAction: "Editing DetailPanel.swift", history: chat, supportsStop: true),
                    AgentSession(id: "hook1", name: "notchy-app", kind: .claudeCode, state: .working, history: [
                        h(400, .status, "Session started"),
                        h(300, .answer, "You: Why does the notch flicker when a second display is attached?"),
                        h(280, .action, "Read NotchWindow.swift"),
                        h(200, .status, "Claude: The panel frame is recomputed on every screen change; I would debounce it."),
                        h(120, .answer, "You: Go ahead and fix it, then run the tests."),
                        h(60, .action, "Edited NotchWindow.swift"),
                        h(20, .status, "Claude needs your attention")], workingDirectory: "/Users/demo/Projects/notchy-app", originRole: .owner),
                    AgentSession(id: "m", name: "Browser Agent", kind: .computerUse, state: .working,
                                 currentAction: "Clicking the \"Submit\" button in Safari", supportsStop: true),
                    AgentSession(id: "b", name: "api-server", kind: .codex, state: .idle)]
            if name == "hook" { list = list.filter { $0.id == "hook1" || $0.id == "b" } }   // short list: panel fits the screenshot
        case "approval", "approval2":
            // Open approval in the (selected) hook session `hook1`, shown as a bubble in its conversation (use --demo-select hook1).
            // "approval2" has a second waiting session: its request stays a card on top.
            let cmd = "cd /Users/demo/Projects/notchy-app && swift test --filter NotchWindowTests 2>&1 | tail -40 && git status --short"
            let text = "Allow Bash?\ncwd: /Users/demo/Projects/notchy-app\ncommand: \(cmd)\ndescription: Run the window tests, then show the changed files"
            let bubbleReq = AgentRequest(requestId: "ab1", type: .approval, text: text,
                options: [RequestOption(id: "allow", label: "Allow", style: .primary),
                          RequestOption(id: "deny", label: "Deny", style: .destructive),
                          RequestOption(id: "always", label: "Always allow", detail: "Bash(swift test:*) · this project, local settings")],
                timeoutSeconds: 120, defaultOptionId: nil)
            var hook = AgentSession(id: "hook1", name: "notchy-app", kind: .claudeCode, state: .needsInput, pendingRequests: [bubbleReq], history: [
                h(400, .status, "Session started"),
                h(300, .answer, "You: Why does the notch flicker when a second display is attached?"),
                h(280, .action, "Read NotchWindow.swift"),
                h(200, .status, "Claude: The panel frame is recomputed on every screen change; I would debounce it."),
                h(120, .answer, "You: Go ahead and fix it, then run the tests."),
                h(60, .action, "Edited NotchWindow.swift"),
                h(20, .request, text)], workingDirectory: "/Users/demo/Projects/notchy-app", originRole: .owner)
            hook.updatedAt = now
            list = [hook, AgentSession(id: "b", name: "api-server", kind: .codex, state: .idle)]
            if name == "approval2" {
                let other = AgentRequest(requestId: "ab2", type: .approval,
                    text: "Allow Edit?\ncwd: /Users/demo/Projects/api-server\nfile_path: /Users/demo/Projects/api-server/Sources/Routes.swift",
                    options: [RequestOption(id: "allow", label: "Allow", style: .primary),
                              RequestOption(id: "deny", label: "Deny", style: .destructive)],
                    timeoutSeconds: 120, defaultOptionId: nil, createdAt: now.addingTimeInterval(-20))
                list[1] = AgentSession(id: "b", name: "api-server", kind: .codex, state: .needsInput, pendingRequests: [other],
                                       history: [h(30, .request, other.text)])
            }
        case "error":
            list = [AgentSession(id: "c", name: "deploy.sh", kind: .genericCLI, state: .error,
                                 history: [h(60, .action, "Uploading build"), h(5, .error, "Exit code 1: connection refused")]),
                    AgentSession(id: "a", name: "notchy-app", kind: .claudeCode, state: .done)]
        case "computer":
            list = [AgentSession(id: "m", name: "Browser Agent", kind: .computerUse, state: .working,
                                 currentAction: "Clicking the \"Submit\" button in Safari",
                                 history: [h(50, .action, "Opened checkout page"), h(25, .action, "Filled shipping form")],
                                 supportsStop: true),
                    AgentSession(id: "a", name: "notchy-app", kind: .claudeCode, state: .idle)]
        default: // idle
            list = [AgentSession(id: "a", name: "notchy-app", kind: .claudeCode, state: .idle),
                    AgentSession(id: "b", name: "api-server", kind: .codex, state: .done)]
        }
        sessions = sorted(list)
    }

    private func sorted(_ list: [AgentSession]) -> [AgentSession] {
        func rank(_ s: SessionState) -> Int { s == .needsInput ? 0 : s == .working ? 1 : 2 }
        return list.sorted { rank($0.state) < rank($1.state) }
    }

    // MARK: ResponseSink

    func respond(_ response: AgentResponse, sessionId: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        var s = sessions[i]
        let answered = s.pendingRequests.first { $0.requestId == response.requestId }
        s.pendingRequests.removeAll { $0.requestId == response.requestId }
        // Same wording as the real store: "answered: <option label>[: reason]" (the transcript turns it into "Allowed"/"Denied: ...").
        let optLabel = response.optionId.flatMap { o in answered?.options.first { $0.id == o }?.label }
        let reason = response.optionId != nil ? ApprovalTranscript.oneLine(response.text, max: 200) : nil
        let label = optLabel ?? response.text ?? response.optionId ?? "dismissed"
        s.history.append(HistoryEntry(kind: .answer, text: "answered: \(label)" + (reason.map { ": " + $0 } ?? "")))
        s.state = s.pendingRequests.isEmpty ? .working : .needsInput
        s.updatedAt = Date()
        sessions[i] = s
        sessions = sorted(sessions)
        NSLog("[demo] respond session=%@ request=%@ option=%@ text=%@", sessionId, response.requestId,
              response.optionId ?? "-", response.text ?? "-")
    }

    func stop(sessionId: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[i].state = .idle
        sessions[i].currentAction = nil
        sessions[i].history.append(HistoryEntry(kind: .status, text: "Stopped by user"))
        sessions = sorted(sessions)
        NSLog("[demo] stop session=%@", sessionId)
    }

    func appendHistory(sessionId: String, _ entry: HistoryEntry, state: SessionState? = nil) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[i].history.append(entry)
        if let state { sessions[i].state = state; sessions[i].currentAction = nil }
        sessions[i].updatedAt = Date()
    }

    func addSession(_ s: AgentSession) { sessions = sorted(sessions + [s]) }

    func remove(sessionId: String) {
        guard sessions.contains(where: { $0.id == sessionId }) else { return }
        sessions.removeAll { $0.id == sessionId }
        NSLog("[demo] remove session=%@", sessionId)
    }
}
