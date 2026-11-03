import Foundation

/// App side of the host channel. One instance lives in the app (`TransportServer.hostClient`); the transport hands it the
/// long-lived connection of the agent-role peer that sent `op: "host"`.
///
/// Public API for the UI:
/// - `state` / `isConnected` / `info` / `onStateChange`: is the agent host there, who is it (`Info.user`, `workspaceRoot`)?
/// - `processFactory`: pass to `ChatSession(config: .remote(...), store:, processFactory:)`.
/// - `listWorkspaces` / `createWorkspace`: the owner cannot read the agent's home, so this is the only way to see/create workspaces.
/// - `terminateAll()`: "stop all agent processes".
///
/// Safety: everything the host sends is data. Frames for ids this client did not hand out are dropped (`droppedFrames`);
/// the host cannot create sessions, write history or answer requests, it only feeds the raw lines of processes the app asked for.
public final class HostClient: @unchecked Sendable {
    public struct Info: Sendable, Equatable {
        public var user: String
        public var uid: Int
        public var workspaceRoot: String
        public var agents: [String: String]
        public var protocolVersion: Int
        public init(user: String, uid: Int, workspaceRoot: String, agents: [String: String], protocolVersion: Int = HostProtocol.version) {
            self.user = user; self.uid = uid; self.workspaceRoot = workspaceRoot; self.agents = agents; self.protocolVersion = protocolVersion
        }
    }
    public enum State: Sendable, Equatable { case disconnected; case connected(Info) }

    private struct Link { var writer: HostFrameWriter; var fd: Int32; var reader: HostLineReader }
    private struct Pending { var finish: @Sendable (Result<HostEvent, HostError>) -> Void }

    private let lock = NSLock()
    private var _state: State = .disconnected
    private var handler: (@Sendable (State) -> Void)?
    private var link: Link?
    private var procs: [String: RemoteChatProcess] = [:]
    private var pending: [String: Pending] = [:]
    private var _dropped = 0
    private let pingInterval: TimeInterval
    private let deadAfter: TimeInterval
    private let takeoverProbe: TimeInterval
    public static let requestTimeout: TimeInterval = 10

    /// `takeoverProbe`: when a second (authenticated, binary-checked) host connects while one is registered, the registered one is
    /// pinged and must answer within this time to keep its place; otherwise it is dropped and the newcomer takes over.
    public init(pingInterval: TimeInterval = HostProtocol.pingInterval, deadAfter: TimeInterval = HostProtocol.deadManSeconds,
                takeoverProbe: TimeInterval = 2) {
        self.pingInterval = pingInterval; self.deadAfter = deadAfter; self.takeoverProbe = takeoverProbe
    }

    // MARK: observable state

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    public var isConnected: Bool { if case .connected = state { return true }; return false }
    public var info: Info? { if case .connected(let i) = state { return i }; return nil }
    /// Called on an arbitrary thread whenever the state changes.
    public var onStateChange: (@Sendable (State) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set { lock.lock(); handler = newValue; lock.unlock() }
    }
    public var activeProcessCount: Int { lock.lock(); defer { lock.unlock() }; return procs.count }
    /// Frames dropped because they named an unknown id (diagnostics / tests).
    public var droppedFrames: Int { lock.lock(); defer { lock.unlock() }; return _dropped }

    // MARK: API for the chat layer

    /// The `ChatProcessFactory` for remote chats. Throws synchronously when the host is not connected.
    public var processFactory: ChatProcessFactory {
        { [self] spec in
            guard let r = spec.remote else { throw ChatError.invalidConfig("not a remote launch spec") }
            guard isConnected else { throw ChatError.spawnFailed("Agent host is not connected") }
            return RemoteChatProcess(client: self, launch: r)
        }
    }

    public func listWorkspaces(completion: @escaping @Sendable (Result<[HostWorkspace], HostError>) -> Void) {
        request({ .workspaces(rid: $0) }) { r in
            completion(r.flatMap { ev in
                if case .workspaces(_, let items) = ev { return .success(items) }
                return .failure(.host("unexpected reply"))
            })
        }
    }

    public func createWorkspace(name: String, completion: @escaping @Sendable (Result<String, HostError>) -> Void) {
        guard HostProtocol.isValidWorkspaceName(name) else { return completion(.failure(.host("invalid workspace name"))) }
        request({ .mkworkspace(rid: $0, name: name) }) { r in
            completion(r.flatMap { ev in
                if case .workspaceCreated(_, let n) = ev { return .success(n) }
                return .failure(.host("unexpected reply"))
            })
        }
    }

    /// SIGTERM to every running agent process group (the "stop all" menu item). Does not wait.
    public func terminateAll() {
        lock.lock(); let ps = Array(procs.values); lock.unlock()
        for p in ps { p.terminate() }
    }

    private func request(_ make: (String) -> HostCommand, finish: @escaping @Sendable (Result<HostEvent, HostError>) -> Void) {
        let rid = "r" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        lock.lock()
        guard let l = link else { lock.unlock(); return finish(.failure(.notConnected)) }
        pending[rid] = Pending(finish: finish)
        lock.unlock()
        guard let data = try? HostProtocol.encode(make(rid)), l.writer.send(data) else {
            if takePending(rid) != nil { finish(.failure(.disconnected)) }
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
            if let p = self?.takePending(rid) { p.finish(.failure(.timeout)) }
        }
    }

    private func takePending(_ rid: String) -> Pending? { lock.lock(); defer { lock.unlock() }; return pending.removeValue(forKey: rid) }

    // MARK: RemoteChatProcess plumbing

    func begin(_ p: RemoteChatProcess, request: HostSpawnRequest) throws {
        lock.lock()
        guard let l = link else { lock.unlock(); throw ChatError.spawnFailed("Agent host is not connected") }
        guard procs.count < HostProtocol.maxProcesses else { lock.unlock(); throw ChatError.spawnFailed("too many agent processes") }
        procs[request.id] = p
        lock.unlock()
        guard let data = try? HostProtocol.encode(.spawn(request)), l.writer.send(data) else {
            lock.lock(); procs[request.id] = nil; lock.unlock()
            throw ChatError.spawnFailed("Agent host is not connected")
        }
    }

    func send(_ command: HostCommand) {
        lock.lock(); let l = link; lock.unlock()
        if let l, let d = try? HostProtocol.encode(command) { l.writer.send(d) }
    }

    func forget(_ id: String) { lock.lock(); procs[id] = nil; lock.unlock() }

    // MARK: connection (called by the transport / tests)

    /// Takes over an authenticated, handshaken-by-hello connection and serves it until it ends. Blocks the calling thread.
    /// Returns false (without touching the fd) when a host is already connected. `handshake` writes the `ready` line.
    @discardableResult
    func serve(fd: Int32, info: Info, handshake: (Int32) -> Bool = { _ in true }) -> Bool {
        signal(SIGPIPE, SIG_IGN)
        let reader = HostLineReader(fd: fd)
        let writer = HostFrameWriter(fd: fd, onFailure: { Darwin.shutdown(fd, SHUT_RDWR) })
        lock.lock()
        if let old = link {
            lock.unlock()
            // A living host is never displaced (first-connect-wins against a racing impostor), a dead one (EOF already torn down,
            // or silent: no answer to a ping) is replaced at once instead of after the 20 s dead-man window.
            guard displaceIfDead(old) else { return false }
            lock.lock()
        }
        if link != nil { lock.unlock(); return false }
        link = Link(writer: writer, fd: fd, reader: reader)
        _state = .connected(info)
        let cb = handler
        lock.unlock()
        cb?(.connected(info))

        let done = DispatchSemaphore(value: 0)
        if !handshake(fd) { Darwin.shutdown(fd, SHUT_RDWR) }
        else {
            let t = Thread { [self] in
                while done.wait(timeout: .now() + pingInterval) == .timedOut {
                    if Double(hostMonotonicNow() &- reader.lastReceive) / 1e9 > deadAfter { Darwin.shutdown(fd, SHUT_RDWR); return }
                    if let d = try? HostProtocol.encode(.ping) { writer.send(d) }
                }
            }
            t.name = "agentbar.host.ping"
            t.start()
            loop: while true {
                switch reader.next() {
                case .eof, .tooLong, .timeout: break loop
                case .line(let line):
                    guard let ev = try? HostProtocol.decodeEvent(line) else { continue }   // unknown frame types: ignore (version skew)
                    dispatch(ev)
                }
            }
        }
        done.signal()
        writer.close()
        teardown()
        return true
    }

    /// true = the registered link is gone now (it was dead and has been torn down); false = it is alive.
    private func displaceIfDead(_ old: Link) -> Bool {
        let mark = hostMonotonicNow()
        if let d = try? HostProtocol.encode(.ping) { old.writer.send(d) }
        let end = Date().addingTimeInterval(takeoverProbe)
        while Date() < end {
            if !isLink(old) { return true }
            if old.reader.lastReceive > mark { return false }      // any frame since the probe = alive
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !isLink(old) { return true }
        if old.reader.lastReceive > mark { return false }
        Darwin.shutdown(old.fd, SHUT_RDWR)                          // wakes the old serve loop, which tears itself down
        let tearEnd = Date().addingTimeInterval(3)
        while Date() < tearEnd { if !isLink(old) { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return false
    }

    private func isLink(_ l: Link) -> Bool { lock.lock(); defer { lock.unlock() }; return link?.fd == l.fd && link?.reader === l.reader }

    private func dropped() { lock.lock(); _dropped += 1; lock.unlock() }
    private func process(_ id: String) -> RemoteChatProcess? {
        lock.lock(); defer { lock.unlock() }
        return procs[id]
    }

    private func dispatch(_ ev: HostEvent) {
        switch ev {
        case .pong: break
        case .spawned(let id, let pid):
            guard let p = process(id) else { return dropped() }
            p.hostSpawned(pid: pid)
        case .spawnFailed(let id, let err):
            guard let p = process(id) else { return dropped() }
            forget(id); p.hostSpawnFailed(err)
        case .stdout(let id, let line):
            guard let p = process(id) else { return dropped() }
            if !p.hostStdout(line) { dropped() }
        case .stderr(let id, let data):
            guard let p = process(id) else { return dropped() }
            if !p.hostStderr(data) { dropped() }
        case .exit(let id, let status):
            guard let p = process(id) else { return dropped() }
            if p.hostExit(Int32(truncatingIfNeeded: status)) { forget(id) } else { dropped() }
        case .workspaces(let rid, _), .workspaceCreated(let rid, _):
            if let p = takePending(rid) { p.finish(.success(ev)) } else { dropped() }
        case .error(let id, let rid, let msg):
            if let rid, let p = takePending(rid) { p.finish(.failure(.host(msg))) }
            else if let id, let p = process(id) { if p.hostError(msg) { forget(id) } }
            else if rid != nil || id != nil { dropped() }
        }
    }

    private func teardown() {
        lock.lock()
        let ps = Array(procs.values); procs = [:]
        let pend = Array(pending.values); pending = [:]
        link = nil
        _state = .disconnected
        let cb = handler
        lock.unlock()
        cb?(.disconnected)
        for p in ps { p.hostDisconnected() }
        for q in pend { q.finish(.failure(.disconnected)) }
    }
}
