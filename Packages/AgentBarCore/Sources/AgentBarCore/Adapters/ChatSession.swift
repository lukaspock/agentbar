import Foundation

/// Chat input to an agent: AgentBar starts ONE `claude -p --input-format stream-json --output-format stream-json`
/// process, sends the user's text from the bar to it and translates the output into store events.
///
/// Public API for UI/STOP: `init(config:store:)`, `start()`, `send(text:)`, `stop()`, `phase`, `sessionId`.
/// - Permission prompts arrive as `control_request`/`can_use_tool` on stdout and are answered with `control_response`
///   (no MCP permission tool needed: with `-p` the host answers them). They become store requests with the same safety
///   rule as `ClaudeCodeAdapter.renderApproval`: if the input cannot be shown in full, there is NO one-click allow; the
///   tool call is denied (a headless process has no terminal dialog to fall back to).
/// - `stop()` takes effect immediately: pending prompts are denied, SIGTERM is sent synchronously, SIGKILL follows after
///   `killGrace`. Wire up with `store.stopHandler` (owned by the STOP agent): `{ id in if id == chat.sessionId { chat.stop() } }`.
/// - UNVERIFIED against a real claude run; see Docs/research/chat-input.md.
@MainActor
public final class ChatSession {
    public enum Phase: Sendable, Equatable { case notStarted, running, stopping, exited }

    public let sessionId: String
    public let displayName: String
    public private(set) var phase: Phase = .notStarted

    private struct Pending {
        enum Kind { case approval(suggestion: [Any]?), question(text: String, labels: [String: String], questions: [Any]) }
        var cliRequestId: String
        var toolName: String
        var input: [String: Any]
        var kind: Kind
    }

    private let config: ChatConfig
    private let store: SessionStore
    private let factory: ChatProcessFactory
    private let deliver: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let clock: @MainActor () -> Date
    private let environment: [String: String]
    private var process: ChatProcess?
    private var pending: [String: Pending] = [:]       // by store request id
    private var stopRequested = false
    private var idleKilled = false
    private var turnActive = false
    /// The claude CLI's own session id (from `system/init`), reserved like `sessionId` while the process lives.
    private var cliAliasId: String?
    private var lastActivity = Date()
    private var stderrTail = Data()
    private var malformed = 0
    private var watchdog: Task<Void, Never>?
    /// Last assistant text, logged only when the next event shows it was not the text of an error result.
    private var pendingAssistant: String?

    public static let approvalTimeoutSeconds = 120
    public static let maxUserTextLength = 20_000

    public init(config: ChatConfig, store: SessionStore,
                processFactory: @escaping ChatProcessFactory = PosixChatProcess.factory,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                clock: @escaping @MainActor () -> Date = { Date() },
                deliver: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.config = config; self.store = store; self.factory = processFactory
        self.environment = environment; self.clock = clock; self.deliver = deliver
        self.sessionId = config.sessionId ?? "chat-" + UUID().uuidString.prefix(8).lowercased()
        self.displayName = ClaudeCodeAdapter.clean(config.name ?? config.workingDirectory.lastPathComponent,
                                                   max: AgentBarLimits.maxNameLength) ?? "Claude Chat"
    }

    // MARK: public API

    public func start() throws {
        guard phase == .notStarted else { throw ChatError.alreadyStarted }
        store.markChatOwned(sessionId)   // external transport ops on this id are rejected from now on
        let spec: ChatLaunchSpec
        do { spec = try config.launchSpec(environment: environment) } catch { store.unmarkChatOwned(sessionId); throw error }
        let proc: ChatProcess
        do { proc = try factory(spec) } catch { throw fail(error) }
        process = proc
        phase = .running
        lastActivity = clock()
        store.apply(.sessionUpdate(id: sessionId, name: displayName, kind: .claudeCode, state: .idle,
                                   action: nil, supportsStop: true))
        let d = deliver
        let ref = WeakChat(self)
        do {
            try proc.start(
                onLine: { line in d { MainActor.assumeIsolated { ref.value?.handle(line: line) } } },
                onStderr: { chunk in d { MainActor.assumeIsolated { ref.value?.appendStderr(chunk) } } },
                onExit: { status in d { MainActor.assumeIsolated { ref.value?.handleExit(status: status) } } })
        } catch { process = nil; phase = .exited; throw fail(error) }
        startWatchdog()
        if let r = config.resume {
            let from = ClaudeCodeAdapter.clean(r.sourceName, max: AgentBarLimits.maxNameLength) ?? "terminal session"
            store.apply(.log(sessionId: sessionId, entry: HistoryEntry(kind: .status, text: "Forked from \(from)")))
        }
    }

    /// Sends one user message. The state becomes `working` right away.
    public func send(text: String) throws {
        guard phase == .running, let process else { throw ChatError.notRunning }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw ChatError.emptyText }
        guard t.count <= Self.maxUserTextLength else { throw ChatError.textTooLong }
        process.write(line: ChatWire.userMessage(t))
        turnActive = true
        lastActivity = clock()
        store.apply(.log(sessionId: sessionId, entry: HistoryEntry(kind: .answer,
                         text: "You: " + (ClaudeCodeAdapter.clean(t, max: 500) ?? ""))))
        store.apply(.sessionUpdate(id: sessionId, name: nil, kind: nil, state: .working, action: "Thinking", supportsStop: nil))
    }

    /// Immediate stop: denies pending prompts, SIGTERM now, SIGKILL after `killGrace`. A second call kills at once.
    public func stop() {
        switch phase {
        case .notStarted, .exited: return
        case .stopping: process?.kill(); return
        case .running: break
        }
        flushAssistant()
        phase = .stopping
        stopRequested = true
        denyAllPending(message: "Stopped by the user in AgentBar")
        process?.terminate()
        store.apply(.sessionUpdate(id: sessionId, name: nil, kind: nil, state: nil, action: "Stopping", supportsStop: false))
        scheduleKill()
    }

    // MARK: output handling

    func handle(line: Data) {
        guard phase == .running else { return }   // after stop(): no further store writes (would re-create a removed row)
        lastActivity = clock()
        guard let msg = ChatWire.parse(line: line) else {
            malformed += 1
            if malformed <= 3 { store.apply(.log(sessionId: sessionId, entry: HistoryEntry(kind: .error, text: "unreadable output line ignored"))) }
            return
        }
        switch msg {
        case let .systemInit(cliSessionId, model):
            // Hooks of this very claude process report ITS session id, not our `chat-...` id. Reserve it too, otherwise a hook
            // (e.g. from the agent user's ~/.claude/settings.json) would raise a second approval next to the chat's own one.
            // The id comes from agent output, so it is untrusted: only plausible formats, and never an id the store already knows
            // (e.g. a live hook session of another agent: reserving it would lock that session out with "session reserved").
            if let a = cliSessionId, Self.isPlausibleAlias(a), a != sessionId, cliAliasId == nil,
               !store.isChatOwned(a), !store.sessions.contains(where: { $0.id == a }) {
                store.markChatOwned(a); cliAliasId = a
            }
            if let m = ClaudeCodeAdapter.clean(model, max: 60) {
                store.apply(.log(sessionId: sessionId, entry: HistoryEntry(kind: .status, text: "model \(m)")))
            }
        case let .canUseTool(rid, tool, input, suggestions, _):
            flushAssistant()
            if phase == .running { handlePermission(cliRequestId: rid, tool: tool, input: input, suggestions: suggestions) }
            else { process?.write(line: ChatWire.deny(requestId: rid, message: "Stopped by the user in AgentBar")) }
        case let .controlCancel(rid):
            if let (storeId, _) = pending.first(where: { $0.value.cliRequestId == rid }) {
                pending[storeId] = nil
                store.apply(.cancelRequest(sessionId: sessionId, requestId: storeId))
            }
        case let .result(isError, subtype, text):
            turnActive = false
            let shown = ClaudeCodeAdapter.clean(text, max: 500)
            if isError {
                // The CLI often repeats the error as assistant text: show it once, as the error entry.
                if let p = pendingAssistant, let shown, ClaudeCodeAdapter.clean(p, max: 500) == shown { pendingAssistant = nil }
                flushAssistant()
                let detail = shown ?? ClaudeCodeAdapter.clean(subtype, max: 60) ?? "unknown error"
                store.apply(.log(sessionId: sessionId, entry: HistoryEntry(kind: .error, text: "Error: " + detail)))
                store.apply(.sessionUpdate(id: sessionId, name: nil, kind: nil, state: .error, action: "", supportsStop: nil))
            } else {
                flushAssistant()
                store.apply(.sessionUpdate(id: sessionId, name: nil, kind: nil, state: .idle, action: "", supportsStop: nil))
            }
        case .assistantText, .toolUse, .ignored:
            for part in ChatWire.assistantParts(line: line) { handleAssistant(part) }
        }
    }

    private func flushAssistant() {
        guard let t = pendingAssistant else { return }
        pendingAssistant = nil
        store.apply(.log(sessionId: sessionId, entry: HistoryEntry(kind: .status, text: "Claude: " + t.capped(1500))))
    }

    private func handleAssistant(_ part: ChatWire.Incoming) {
        switch part {
        case let .assistantText(t):
            let shown = ClaudeCodeAdapter.multiLine(t)
            guard !shown.isEmpty else { return }
            flushAssistant()
            pendingAssistant = shown
        case let .toolUse(_, name, input):
            flushAssistant()
            let tool = ClaudeCodeAdapter.clean(name, max: 60) ?? "tool"
            let s = ClaudeCodeAdapter.summarize(tool: tool, input: input)
            store.apply(.sessionUpdate(id: sessionId, name: nil, kind: nil, state: .working,
                                       action: s.isEmpty ? tool : "\(tool): \(s)", supportsStop: nil))
        default: break
        }
    }

    // MARK: permission prompts

    private func handlePermission(cliRequestId: String, tool: String, input: [String: Any], suggestions: [Any]) {
        if tool == "AskUserQuestion" { return handleQuestion(cliRequestId: cliRequestId, input: input) }
        let rendered = ClaudeCodeAdapter.renderApproval(tool: tool, cwd: config.workingDirectory.path,
                                                         project: displayName, input: input)
        guard let text = rendered.text else {
            // Not fully displayable => no one-click allow. Headless: deny, tell the agent and the user.
            let t = ClaudeCodeAdapter.clean(tool, max: 60) ?? "tool"
            let msg = "\(t): \(rendered.reason) \(ClaudeCodeAdapter.truncationMarker)"
            store.apply(.log(sessionId: sessionId, entry: HistoryEntry(kind: .status, text: "denied: " + msg)))
            store.apply(.sessionUpdate(id: sessionId, name: nil, kind: nil, state: nil, action: msg, supportsStop: nil))
            process?.write(line: ChatWire.deny(requestId: cliRequestId, message:
                "AgentBar cannot show this tool call in full to the user, so it was denied. Do not retry it unchanged; tell the user what you need."))
            return
        }
        var options = [RequestOption(id: "allow", label: "Allow", style: .primary),
                       RequestOption(id: "deny", label: "Deny", style: .destructive)]
        let always = Self.safeAlwaysRule(tool: tool, input: input, suggestions: suggestions)
        if let always { options.append(RequestOption(id: "always", label: "Always allow: " + always.label)) }
        let chosen: [Any]? = always.map { [$0.update] }
        submit(cliRequestId: cliRequestId, tool: tool, input: input, kind: .approval(suggestion: chosen),
               type: .approval, text: text, options: options, timeout: Self.approvalTimeoutSeconds)
    }

    /// "Always allow" is offered only for an `addRules`/`allow` suggestion (destination localSettings or session) whose
    /// rules name exactly the displayed tool AND carry rule content equal to the displayed primary input value (no wildcards,
    /// so nothing broader than the card). The update is REBUILT from validated fields (unknown keys dropped); setMode,
    /// directories and every other type are never passed on.
    /// Glob/escape characters (path tools read ruleContent as a glob) plus line breaks: such a rule may match more than shown.
    private static let globMeta = Set("*?[]{}!\\\n\r".unicodeScalars)

    static func safeAlwaysRule(tool: String, input: [String: Any], suggestions: [Any]) -> (update: [String: Any], label: String)? {
        var primary: String?
        for key in ["command", "file_path", "path", "url", "pattern", "notebook_path"] {
            if let v = input[key] as? String { primary = v; break }
        }
        guard let primary, !primary.isEmpty else { return nil }
        var found: [(rank: Int, update: [String: Any], label: String)] = []
        for case let sug as [String: Any] in suggestions {
            guard sug["type"] as? String == "addRules", sug["behavior"] as? String == "allow",
                  let dest = sug["destination"] as? String, dest == "localSettings" || dest == "session",
                  let rules = sug["rules"] as? [[String: Any]], rules.count == 1,
                  rules[0]["toolName"] as? String == tool,
                  let content = rules[0]["ruleContent"] as? String, content == primary,
                  content.unicodeScalars.allSatisfy({ !Self.globMeta.contains($0) }) else { continue }
            let label = ClaudeCodeAdapter.singleLine("\(tool)(\(content))")
            guard label == "\(tool)(\(content))", !ClaudeCodeAdapter.hasCollapsedCluster(label),
                  label.count + 15 <= AgentBarLimits.maxNameLength else { continue }
            found.append((dest == "localSettings" ? 0 : 1,
                          ["type": "addRules", "behavior": "allow", "destination": dest,
                           "rules": [["toolName": tool, "ruleContent": content]]], label))
        }
        guard let best = found.min(by: { $0.rank < $1.rank }) else { return nil }
        return (best.update, best.label)
    }

    private func handleQuestion(cliRequestId: String, input: [String: Any]) {
        func refuse(_ why: String) {
            store.apply(.log(sessionId: sessionId, entry: HistoryEntry(kind: .status, text: "question not shown: " + why)))
            process?.write(line: ChatWire.deny(requestId: cliRequestId, message:
                "AgentBar cannot show this question. Ask the user in plain text instead."))
        }
        guard let questions = input["questions"] as? [Any], questions.count == 1,
              let q = questions[0] as? [String: Any], let qText = q["question"] as? String,
              (q["multiSelect"] as? Bool) != true,
              let opts = q["options"] as? [[String: Any]], !opts.isEmpty, opts.count <= AgentBarLimits.maxOptions else {
            return refuse("unsupported shape")
        }
        let body = ClaudeCodeAdapter.multiLine(qText)
        guard !body.isEmpty, body.count <= AgentBarLimits.maxTextLength - 200, !ClaudeCodeAdapter.hasCollapsedCluster(qText) else {
            return refuse("question not displayable")
        }
        var labels: [String: String] = [:]
        var options: [RequestOption] = []
        for (i, o) in opts.enumerated() {
            guard let label = o["label"] as? String, !ClaudeCodeAdapter.hasCollapsedCluster(label),
                  !label.isEmpty, label.count <= AgentBarLimits.maxNameLength,
                  ClaudeCodeAdapter.singleLine(label) == label else { return refuse("option not displayable") }
            labels["opt\(i)"] = label
            options.append(RequestOption(id: "opt\(i)", label: label))
        }
        submit(cliRequestId: cliRequestId, tool: "AskUserQuestion", input: input,
               kind: .question(text: qText, labels: labels, questions: questions),
               type: .question, text: "Question (\(displayName)): \(body)", options: options, timeout: nil)
    }

    private func submit(cliRequestId: String, tool: String, input: [String: Any], kind: Pending.Kind, type: RequestType,
                        text: String, options: [RequestOption], timeout: Int?) {
        let storeId = "chatreq-" + UUID().uuidString
        let req = AgentRequest(requestId: storeId, type: type, text: text, options: options,
                               timeoutSeconds: timeout, defaultOptionId: nil)
        pending[storeId] = Pending(cliRequestId: cliRequestId, toolName: tool, input: input, kind: kind)
        let result = store.submit(sessionId: sessionId, request: req, waiter: { [weak self] resp in
            MainActor.assumeIsolated { self?.answered(storeId: storeId, response: resp) }
        })
        if result != .accepted {
            pending[storeId] = nil
            process?.write(line: ChatWire.deny(requestId: cliRequestId, message: "AgentBar could not queue this request"))
        }
    }

    private func answered(storeId: String, response: AgentResponse) {
        guard let p = pending.removeValue(forKey: storeId) else { return }
        guard phase == .running, let process else { return }
        lastActivity = clock()
        let rid = p.cliRequestId
        switch (response.reason, p.kind) {
        case (.answered, .approval(let suggestion)):
            switch response.optionId {
            case "allow"?:
                process.write(line: ChatWire.allow(requestId: rid, updatedInput: p.input))
            case "always"? where suggestion != nil:
                process.write(line: ChatWire.allow(requestId: rid, updatedInput: p.input, updatedPermissions: suggestion))
            case nil where !(response.text ?? "").isEmpty:
                // A typed reply instead of a button: deny and hand the text to the agent as guidance.
                let t = (response.text ?? "").capped(1000)
                process.write(line: ChatWire.deny(requestId: rid, message: "The user declined and wrote: " + t))
            default:
                process.write(line: ChatWire.deny(requestId: rid, message: "Denied by the user in AgentBar"))
            }
        case (.answered, .question(let text, let labels, let questions)):
            var answer: String?
            if let o = response.optionId { answer = labels[o] } else if let t = response.text, !t.isEmpty { answer = t.capped(1000) }
            if let answer {
                process.write(line: ChatWire.allow(requestId: rid, updatedInput: ["questions": questions, "answers": [text: answer]]))
            } else {
                process.write(line: ChatWire.deny(requestId: rid, message: "The user did not answer"))
            }
        case (.timeout, _):
            process.write(line: ChatWire.deny(requestId: rid, message: "No answer from the user in AgentBar (timeout); not allowed"))
        case (.cancelled, _):
            process.write(line: ChatWire.deny(requestId: rid, message: "Request cancelled in AgentBar"))
        }
    }

    private func denyAllPending(message: String) {
        let all = pending
        pending = [:]
        for (storeId, p) in all {
            process?.write(line: ChatWire.deny(requestId: p.cliRequestId, message: message))
            store.apply(.cancelRequest(sessionId: sessionId, requestId: storeId))
        }
    }

    // MARK: lifecycle

    private func appendStderr(_ chunk: Data) {
        stderrTail.append(chunk)
        if stderrTail.count > 2048 { stderrTail = stderrTail.suffix(2048) }
    }

    func handleExit(status: Int32) {
        guard phase != .exited else { return }
        phase = .exited
        defer { store.unmarkChatOwned(sessionId); releaseAlias() }   // release the reservation after the final events below
        watchdog?.cancel(); watchdog = nil
        process = nil
        let all = pending
        pending = [:]
        for storeId in all.keys { store.apply(.cancelRequest(sessionId: sessionId, requestId: storeId)) }
        // The row was removed by the user (store.remove): write nothing, a late event would bring it back.
        guard store.sessions.contains(where: { $0.id == sessionId }) else { pendingAssistant = nil; return }
        flushAssistant()
        if idleKilled {
            let d = Int(config.idleTimeout ?? 0)
            store.apply(.log(sessionId: sessionId, entry: HistoryEntry(kind: .error, text: "no output for \(d) s, process killed")))
            store.apply(.sessionUpdate(id: sessionId, name: nil, kind: nil, state: .error, action: "timeout", supportsStop: false))
        } else if stopRequested {
            store.apply(.log(sessionId: sessionId, entry: HistoryEntry(kind: .status, text: "stopped")))
            store.apply(.sessionEnd(id: sessionId))
        } else if status == 0 {
            store.apply(.sessionEnd(id: sessionId))
        } else {
            var text = "claude exited with \(status)"
            if let tail = ClaudeCodeAdapter.clean(String(decoding: stderrTail, as: UTF8.self), max: 300), !tail.isEmpty { text += ": " + tail }
            store.apply(.log(sessionId: sessionId, entry: HistoryEntry(kind: .error, text: text)))
            store.apply(.sessionUpdate(id: sessionId, name: nil, kind: nil, state: .error, action: "exit \(status)", supportsStop: false))
        }
    }

    private func scheduleKill() {
        let grace = config.killGrace
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
            guard let self, self.phase == .stopping || self.idleKilled, self.phase != .exited else { return }
            self.process?.kill()
        }
    }

    private func startWatchdog() {
        guard let limit = config.idleTimeout, limit > 0 else { return }
        let interval = max(0.01, config.idleCheckInterval)
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard self.phase == .running, self.turnActive, self.pending.isEmpty else { continue }
                if self.clock().timeIntervalSince(self.lastActivity) > limit {
                    self.idleKilled = true
                    self.phase = .stopping
                    self.process?.terminate()
                    self.scheduleKill()
                    return
                }
            }
        }
    }

    /// Characters of a real claude session id (UUID-like). Anything else is not reserved.
    static func isPlausibleAlias(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= AgentBarLimits.maxIdLength else { return false }
        return id.unicodeScalars.allSatisfy { u in
            (u.value >= 0x30 && u.value <= 0x39) || (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A)
                || u == "_" || u == "-" || u == ":" || u == "."
        }
    }

    private func releaseAlias() { if let a = cliAliasId { store.unmarkChatOwned(a); cliAliasId = nil } }

    private func fail(_ error: Error) -> ChatError {
        let msg = ClaudeCodeAdapter.clean((error as NSError).localizedDescription, max: 200) ?? "spawn failed"
        phase = .exited
        store.apply(.sessionUpdate(id: sessionId, name: displayName, kind: .claudeCode, state: .error,
                                   action: "failed to start", supportsStop: false))
        store.apply(.log(sessionId: sessionId, entry: HistoryEntry(kind: .error, text: "start failed: " + msg)))
        store.unmarkChatOwned(sessionId)
        return .spawnFailed(msg)
    }
}

private final class WeakChat: @unchecked Sendable {
    weak var value: ChatSession?
    init(_ v: ChatSession) { value = v }
}
