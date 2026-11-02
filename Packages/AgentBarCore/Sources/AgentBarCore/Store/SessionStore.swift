import Foundation
import Combine

/// Single source of truth for sessions. Main-actor isolated; the transport hops onto the main actor to use it.
public enum AgentCommand: String, Sendable { case stop, pause, resume }

@MainActor
public final class SessionStore: ObservableObject, SessionStoreReading, ResponseSink {
    public enum AskResult: Sendable, Equatable { case accepted, tooManyPending, duplicateRequest, sessionLimit }

    @Published public private(set) var sessions: [AgentSession] = []

    /// Set by adapters / computer-use to actually halt an agent. Called on the main actor.
    public var stopHandler: ((String) -> Void)?

    /// Observers of pause/resume/stop commands (the transport's `watch` connections). Called on the main actor.
    private var commandObservers: [UUID: @Sendable (String, AgentCommand) -> Void] = [:]

    public func addCommandObserver(_ f: @escaping @Sendable (String, AgentCommand) -> Void) -> UUID {
        let t = UUID(); commandObservers[t] = f; return t
    }
    public func removeCommandObserver(_ token: UUID) { commandObservers[token] = nil }

    public var aggregateState: SessionState {
        var result = SessionState.idle
        var anyWorking = false, anyError = false, anyDone = false
        for s in sessions {
            switch s.state {
            case .needsInput: return .needsInput
            case .error: anyError = true
            case .working: anyWorking = true
            case .done: anyDone = true
            case .idle: break
            }
        }
        if anyError { result = .error } else if anyWorking { result = .working } else if anyDone { result = .done }
        return result
    }

    public var pendingRequestCount: Int { sessions.reduce(0) { $0 + $1.pendingRequests.count } }

    private var waiters: [String: @Sendable (AgentResponse) -> Void] = [:]
    private var timers: [String: Task<Void, Never>] = [:]

    /// Ended sessions (state done after `end`) are removed after this long, or earlier when more than
    /// `maxListedSessions` sessions exist (oldest ended first).
    public static let endedRetention: TimeInterval = 600
    public static let maxListedSessions = 20

    private var endedAt: [String: Date] = [:]
    private var maintenance: Task<Void, Never>?
    private let now: @MainActor () -> Date

    public init(now: @escaping @MainActor () -> Date = { Date() }) { self.now = now }

    deinit { maintenance?.cancel() }

    /// Starts the periodic pruning of ended sessions (call once from the app).
    public func startMaintenance(interval: TimeInterval = 30) {
        maintenance?.cancel()
        maintenance = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.pruneEnded()
            }
        }
    }

    /// Removes ended sessions that are older than the retention, then the oldest ended ones beyond the list cap.
    public func pruneEnded() {
        let cutoff = now().addingTimeInterval(-Self.endedRetention)
        let before = sessions.count
        sessions.removeAll { s in
            guard s.state == .done, s.pendingRequests.isEmpty, let t = endedAt[s.id] else { return false }
            return t <= cutoff
        }
        if sessions.count > Self.maxListedSessions {
            let victims = sessions.filter { $0.state == .done && $0.pendingRequests.isEmpty && endedAt[$0.id] != nil }
                .sorted { (endedAt[$0.id] ?? .distantPast) < (endedAt[$1.id] ?? .distantPast) }
            var excess = sessions.count - Self.maxListedSessions
            for v in victims where excess > 0 {
                sessions.removeAll { $0.id == v.id }
                excess -= 1
            }
        }
        if sessions.count != before { endedAt = endedAt.filter { k, _ in sessions.contains { $0.id == k } } }
    }

    // MARK: Events

    public func apply(_ event: CoreEvent) {
        switch event {
        case let .sessionUpdate(id, name, kind, state, action, supportsStop):
            guard let i = ensureSession(id) else { return }
            if let name, !name.isEmpty { sessions[i].name = name.capped(AgentBarLimits.maxNameLength) }
            if let kind { sessions[i].kind = kind }
            if let supportsStop { sessions[i].supportsStop = supportsStop }
            if let action {
                var a = action.capped(AgentBarLimits.maxTextLength)
                // Computer-use action text is data from an agent that acts on the screen: same sanitizing as hook text.
                if sessions[i].kind == .computerUse { a = ClaudeCodeAdapter.clean(a, max: AgentBarLimits.maxActionLength) ?? "" }
                if a.isEmpty { sessions[i].currentAction = nil } else if sessions[i].currentAction != a {
                    sessions[i].currentAction = a
                    append(.init(kind: .action, text: a), at: i)
                }
            }
            if let state, state != .done { endedAt[sessions[i].id] = nil }
            if let state, state != sessions[i].state, sessions[i].pendingRequests.isEmpty {
                sessions[i].state = state
                append(.init(kind: .status, text: state.rawValue), at: i)
            }
            touch(i)
        case let .ask(sessionId, request):
            _ = submit(sessionId: sessionId, request: request, waiter: nil)
        case let .cancelRequest(sessionId, requestId):
            resolve(requestId: requestId, sessionId: sessionId,
                    response: AgentResponse(requestId: requestId, reason: .cancelled))
        case let .log(sessionId, entry):
            guard let i = ensureSession(sessionId) else { return }
            var e = entry; e.text = e.text.capped(AgentBarLimits.maxTextLength)
            append(e, at: i)
            touch(i)
        case let .sessionEnd(id):
            guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
            for r in sessions[i].pendingRequests {
                resolve(requestId: r.requestId, sessionId: id, response: AgentResponse(requestId: r.requestId, reason: .cancelled))
            }
            guard let j = sessions.firstIndex(where: { $0.id == id }) else { return }
            sessions[j].state = .done
            sessions[j].currentAction = nil
            sessions[j].supportsStop = false
            endedAt[id] = now()
            append(.init(kind: .status, text: "ended"), at: j)
            touch(j)
        }
    }

    /// Submit a request. `waiter` (if any) is called exactly once when the request is resolved
    /// (answered, timeout, cancelled), from the main actor.
    public func submit(sessionId: String, request: AgentRequest,
                       waiter: (@Sendable (AgentResponse) -> Void)?) -> AskResult {
        if pendingRequestCount >= AgentBarLimits.maxPendingRequests { return .tooManyPending }
        if waiters[request.requestId] != nil || sessions.contains(where: { $0.pendingRequests.contains { $0.requestId == request.requestId } }) {
            return .duplicateRequest
        }
        guard let i = ensureSession(sessionId) else { return .sessionLimit }
        var r = request
        r.text = r.text.capped(AgentBarLimits.maxTextLength)
        r.options = r.options.prefix(AgentBarLimits.maxOptions).map {
            RequestOption(id: $0.id.capped(AgentBarLimits.maxIdLength), label: $0.label.capped(AgentBarLimits.maxNameLength), style: $0.style)
        }
        if let t = r.timeoutSeconds { r.timeoutSeconds = min(max(t, 0), AgentBarLimits.maxTimeoutSeconds) }
        endedAt[sessions[i].id] = nil
        sessions[i].pendingRequests.append(r)
        sessions[i].state = .needsInput
        append(.init(kind: .request, text: r.text), at: i)
        touch(i)
        if let waiter { waiters[r.requestId] = waiter }
        if let t = r.timeoutSeconds {
            let rid = r.requestId
            timers[rid] = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(t) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.expire(requestId: rid, sessionId: sessionId)
            }
        }
        return .accepted
    }

    // MARK: ResponseSink

    public func respond(_ response: AgentResponse, sessionId: String) {
        guard let s = sessions.first(where: { $0.id == sessionId }),
              let req = s.pendingRequests.first(where: { $0.requestId == response.requestId }) else { return }
        var resp = response
        if let o = resp.optionId, !req.options.isEmpty, !req.options.contains(where: { $0.id == o }) { return }
        resp.text = resp.text?.capped(AgentBarLimits.maxTextLength)
        resolve(requestId: response.requestId, sessionId: sessionId, response: resp)
    }

    public func stop(sessionId: String) { command(.stop, sessionId: sessionId) }

    /// Pause / resume (not part of the frozen `ResponseSink`): delivered to the session's `watch` connections like stop.
    public func pause(sessionId: String) { command(.pause, sessionId: sessionId) }
    public func resume(sessionId: String) { command(.resume, sessionId: sessionId) }

    private func command(_ c: AgentCommand, sessionId: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        append(.init(kind: .status, text: "\(c.rawValue) requested"), at: i)
        touch(i)
        if c == .stop { stopHandler?(sessionId) }
        for o in Array(commandObservers.values) { o(sessionId, c) }
    }

    /// Removes the session. Every pending request is resolved with `.cancelled` first (waiting transport connections
    /// get the cancelled reply, timers are cancelled, the adapter's side table entry is consumed by the transport's
    /// encode call). Unknown id is a no-op, so calling it twice is harmless.
    /// Note: the agent is not told to stop; if it later sends any event for the same id, the session re-appears
    /// as a fresh entry (new name = id, no history).
    public func remove(sessionId: String) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        for r in sessions[i].pendingRequests {
            resolve(requestId: r.requestId, sessionId: sessionId,
                    response: AgentResponse(requestId: r.requestId, reason: .cancelled))
        }
        sessions.removeAll { $0.id == sessionId }
        endedAt[sessionId] = nil
    }

    // MARK: Internals

    private func expire(requestId: String, sessionId: String) {
        guard let s = sessions.first(where: { $0.id == sessionId }),
              let req = s.pendingRequests.first(where: { $0.requestId == requestId }) else { return }
        resolve(requestId: requestId, sessionId: sessionId,
                response: AgentResponse(requestId: requestId, optionId: req.defaultOptionId, reason: .timeout))
    }

    private func resolve(requestId: String, sessionId: String, response: AgentResponse) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionId }),
              let k = sessions[i].pendingRequests.firstIndex(where: { $0.requestId == requestId }) else { return }
        let req = sessions[i].pendingRequests.remove(at: k)
        timers.removeValue(forKey: requestId)?.cancel()
        let summary: String
        switch response.reason {
        case .answered:
            let label = response.optionId.flatMap { o in req.options.first { $0.id == o }?.label } ?? response.text ?? ""
            summary = "answered: \(label)"
        case .timeout: summary = "timeout" + (response.optionId.map { " (\($0))" } ?? "")
        case .cancelled: summary = "cancelled"
        }
        append(.init(kind: .answer, text: summary.capped(AgentBarLimits.maxTextLength)), at: i)
        if sessions[i].pendingRequests.isEmpty && sessions[i].state == .needsInput { sessions[i].state = .working }
        touch(i)
        waiters.removeValue(forKey: requestId)?(response)
    }

    private func ensureSession(_ rawId: String) -> Int? {
        let id = rawId.capped(AgentBarLimits.maxIdLength)
        if let i = sessions.firstIndex(where: { $0.id == id }) { return i }
        if sessions.count >= AgentBarLimits.maxSessions {
            // Evict the oldest finished/idle session without pending requests.
            guard let victim = sessions.filter({ $0.pendingRequests.isEmpty && ($0.state == .done || $0.state == .idle) })
                .min(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
            sessions.removeAll { $0.id == victim.id }
            endedAt[victim.id] = nil
        }
        sessions.append(AgentSession(id: id, name: id.capped(AgentBarLimits.maxNameLength), kind: .genericCLI))
        return sessions.count - 1
    }

    private func append(_ e: HistoryEntry, at i: Int) {
        sessions[i].history.append(e)
        if sessions[i].history.count > AgentBarLimits.maxHistory {
            sessions[i].history.removeFirst(sessions[i].history.count - AgentBarLimits.maxHistory)
        }
    }

    /// Bump updatedAt and re-sort. Resolves the session by id since sorting moves indices.
    private func touch(_ i: Int) {
        sessions[i].updatedAt = now()
        sessions.sort(by: Self.order)
        if sessions.count > Self.maxListedSessions { pruneEnded() }
    }

    private static func rank(_ s: SessionState) -> Int {
        switch s { case .needsInput: return 0; case .working: return 1; default: return 2 }
    }
    private static func order(_ a: AgentSession, _ b: AgentSession) -> Bool {
        let ra = rank(a.state), rb = rank(b.state)
        if ra != rb { return ra < rb }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id < b.id
    }
}
