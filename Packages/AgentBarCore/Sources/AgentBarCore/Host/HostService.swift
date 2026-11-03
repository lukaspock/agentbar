import Foundation

/// Host side of the host channel: runs as the agent user, spawns `claude` on request of the app and forwards bytes.
/// It is a dumb pipe: it parses no claude output, renders nothing, answers no permission prompt.
///
/// Safety properties (all tested over a socketpair):
/// - workspace containment (`WorkspaceStore`), structured spawn requests only (no executable / env / path from the app),
/// - environment built from scratch (`HostEnvironment`), OAuth token read from a 0600 file in the agent's home,
/// - every child leads its own process group; terminate/kill hit the group,
/// - dead-man: link silent for `deadManSeconds`, or closed => all children are terminated (SIGTERM, SIGKILL after `killGrace`).
///   Silence is measured on a clock that stops during system sleep, so waking up does not trip it.
public final class HostService: @unchecked Sendable {
    public struct Config: Sendable {
        public var home: URL
        public var user: String
        public var uid: uid_t
        public var workspaceRoot: URL
        /// nil = look in `<home>/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`.
        public var claudeExecutable: URL?
        public var oauthTokenFile: URL?
        public var deadManSeconds: TimeInterval
        public var killGrace: TimeInterval
        public var maxProcesses: Int
        public var processFactory: ChatProcessFactory

        public init(home: URL, user: String, uid: uid_t = geteuid(), workspaceRoot: URL? = nil, claudeExecutable: URL? = nil,
                    oauthTokenFile: URL? = nil, deadManSeconds: TimeInterval = HostProtocol.deadManSeconds, killGrace: TimeInterval = 2,
                    maxProcesses: Int = HostProtocol.maxProcesses,
                    processFactory: @escaping ChatProcessFactory = { PosixChatProcess(spec: $0, newProcessGroup: true) }) {
            self.home = home; self.user = user; self.uid = uid
            self.workspaceRoot = workspaceRoot ?? home.appendingPathComponent("work", isDirectory: true)
            self.claudeExecutable = claudeExecutable
            self.oauthTokenFile = oauthTokenFile ?? home.appendingPathComponent(HostEnvironment.tokenFileRelativePath)
            self.deadManSeconds = deadManSeconds; self.killGrace = killGrace; self.maxProcesses = maxProcesses
            self.processFactory = processFactory
        }

        /// Config of the user this process runs as (password database, not environment variables).
        public static func current() -> Config? {
            guard let pw = getpwuid(geteuid()), let dir = pw.pointee.pw_dir else { return nil }
            return Config(home: URL(fileURLWithPath: String(cString: dir), isDirectory: true),
                          user: String(cString: pw.pointee.pw_name), uid: geteuid())
        }
    }

    public let config: Config
    public let workspaces: WorkspaceStore

    private final class Child: @unchecked Sendable {
        let id: String
        var process: ChatProcess?
        private let lock = NSLock()
        private var announced = false
        private var queued: [HostEvent] = []
        init(id: String) { self.id = id }

        /// Events from the process callbacks are held until `spawned` went out, so the app never sees stdout before `spawned`.
        func emit(_ ev: HostEvent, via send: (HostEvent) -> Void) {
            lock.lock(); defer { lock.unlock() }
            if announced { send(ev) } else { queued.append(ev) }
        }
        func announce(_ first: HostEvent, via send: (HostEvent) -> Void) {
            lock.lock(); defer { lock.unlock() }
            send(first)
            for e in queued { send(e) }
            queued = []; announced = true
        }
    }

    private let lock = NSLock()
    private var children: [String: Child] = [:]
    private var activeFd: Int32 = -1
    private var shuttingDown = false

    public init(config: Config) {
        self.config = config
        self.workspaces = WorkspaceStore(root: config.workspaceRoot, uid: config.uid)
    }

    public var activeProcessCount: Int { lock.lock(); defer { lock.unlock() }; return children.count }

    /// Agents found on this machine: name -> executable path. Sent in the hello (display only).
    public func discoverAgents() -> [String: String] {
        var out: [String: String] = [:]
        if let c = claudeExecutable() { out["claude"] = c.path }
        return out
    }

    func claudeExecutable() -> URL? {
        if let c = config.claudeExecutable { return FileManager.default.isExecutableFile(atPath: c.path) ? c : nil }
        return ChatConfig.locateClaude(home: config.home.path)
    }

    // MARK: serving one connection

    /// Serves frames on an already handshaken connection until it closes, the link goes silent for `deadManSeconds`, or `shutdown()`
    /// is called. Always terminates all children before returning. `reader` may already hold buffered bytes.
    func run(fd: Int32, reader: HostLineReader? = nil) {
        signal(SIGPIPE, SIG_IGN)
        let reader = reader ?? HostLineReader(fd: fd)
        let writer = HostFrameWriter(fd: fd, onFailure: { Darwin.shutdown(fd, SHUT_RDWR) })
        lock.lock(); activeFd = fd; let stopNow = shuttingDown; lock.unlock()
        if stopNow { Darwin.shutdown(fd, SHUT_RDWR) }

        let done = DispatchSemaphore(value: 0)
        let monitor = Thread { [config] in
            while done.wait(timeout: .now() + 0.25) == .timedOut {
                let silent = Double(hostMonotonicNow() &- reader.lastReceive) / 1e9
                if silent > config.deadManSeconds { Darwin.shutdown(fd, SHUT_RDWR); return }
            }
        }
        monitor.name = "agentbar.host.deadman"
        monitor.start()

        loop: while true {
            switch reader.next() {
            case .eof, .tooLong, .timeout: break loop
            case .line(let line): handle(line, writer: writer)
            }
        }
        done.signal()
        writer.close()
        terminateAllAndWait()
        lock.lock(); activeFd = -1; lock.unlock()
    }

    /// Stops serving (terminates all children). Safe to call from a signal-handling context queue.
    public func shutdown() {
        lock.lock(); shuttingDown = true; let fd = activeFd; lock.unlock()
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }   // wakes the reader; `run` then terminates the children
        terminateAllAndWait()
    }

    private func send(_ ev: HostEvent, via w: HostFrameWriter) {
        guard let d = try? HostProtocol.encode(ev) else { return }
        if !w.send(d), !w.isDead, case .stdout(let id, _) = ev {
            // Frame would exceed the channel limit (JSON escaping of a ~1 MiB line): drop that line, tell the app on stderr.
            if let d2 = try? HostProtocol.encode(HostEvent.stderr(id: id, data: Data("agentbar-host: oversized output line dropped\n".utf8))) { w.send(d2) }
        }
    }

    // MARK: commands

    private func handle(_ line: Data, writer w: HostFrameWriter) {
        let cmd: HostCommand
        do { cmd = try HostProtocol.decodeCommand(line) } catch {
            send(.error(id: nil, rid: nil, message: "malformed or unknown frame"), via: w); return
        }
        switch cmd {
        case .ping: send(.pong, via: w)
        case .stdin(let id, let text):
            if let c = child(id), let p = c.process { p.write(line: Data(text.utf8)) }
        case .terminate(let id): child(id)?.process?.terminate()
        case .kill(let id): child(id)?.process?.kill()
        case .workspaces(let rid):
            guard HostProtocol.isValidId(rid) else { send(.error(id: nil, rid: nil, message: "invalid rid"), via: w); return }
            do { send(.workspaces(rid: rid, items: try workspaces.list()), via: w) }
            catch { send(.error(id: nil, rid: rid, message: Self.describe(error)), via: w) }
        case .mkworkspace(let rid, let name):
            guard HostProtocol.isValidId(rid) else { send(.error(id: nil, rid: nil, message: "invalid rid"), via: w); return }
            do { try workspaces.create(name); send(.workspaceCreated(rid: rid, name: name), via: w) }
            catch { send(.error(id: nil, rid: rid, message: Self.describe(error)), via: w) }
        case .spawn(let req): spawn(req, writer: w)
        }
    }

    private func child(_ id: String) -> Child? { lock.lock(); defer { lock.unlock() }; return children[id] }

    private func spawn(_ req: HostSpawnRequest, writer w: HostFrameWriter) {
        func fail(_ msg: String) { send(.spawnFailed(id: req.id, error: msg), via: w) }
        guard HostProtocol.isValidId(req.id) else { send(.error(id: nil, rid: nil, message: "invalid process id"), via: w); return }
        let child = Child(id: req.id)
        lock.lock()
        if children[req.id] != nil { lock.unlock(); send(.error(id: req.id, rid: nil, message: "duplicate id"), via: w); return }
        if children.count >= config.maxProcesses { lock.unlock(); return fail("too many agent processes") }
        if shuttingDown { lock.unlock(); return fail("host is shutting down") }
        children[req.id] = child   // reserve before the (slow) spawn so ids stay unique
        lock.unlock()
        func release() { lock.lock(); children[req.id] = nil; lock.unlock() }

        guard HostProtocol.supportedAgents.contains(req.agent) else { release(); return fail("unsupported agent") }
        guard let exe = claudeExecutable() else { release(); return fail("claude is not installed for user \(config.user)") }
        let dir: URL
        do { dir = try workspaces.resolve(req.workspace) } catch { release(); return fail("workspace: " + Self.describe(error)) }
        let env: [String: String]
        do {
            try? FileManager.default.createDirectory(at: config.home.appendingPathComponent(".agentbar/tmp"), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            env = try HostEnvironment.build(home: config.home, user: config.user, tokenFile: config.oauthTokenFile, uid: config.uid)
        } catch { release(); return fail("environment: " + Self.describe(error)) }

        // Arguments come from ChatConfig's whitelist builder (model/tools/budget validation), never from raw strings of the app.
        var mode: ChatConfig.PermissionMode?
        if let m = req.permissionMode { guard let pm = ChatConfig.PermissionMode(rawValue: m) else { release(); return fail("invalid permission mode") }; mode = pm }
        let spec: ChatLaunchSpec
        do {
            spec = try ChatConfig(executable: exe, workingDirectory: dir, model: req.model, maxBudgetUSD: req.maxBudgetUSD, tools: req.tools,
                                  permissionMode: mode, passthroughEnvironment: [], extraEnvironment: env).launchSpec(environment: [:])
        } catch { release(); return fail(Self.describe(error)) }

        let proc: ChatProcess
        do { proc = try config.processFactory(spec) } catch { release(); return fail(Self.describe(error)) }
        child.process = proc
        let id = req.id
        do {
            try proc.start(
                onLine: { [weak self, weak child] line in
                    guard let self, let child else { return }
                    child.emit(.stdout(id: id, line: String(decoding: line, as: UTF8.self)), via: { self.send($0, via: w) })
                },
                onStderr: { [weak self, weak child] chunk in
                    guard let self, let child else { return }
                    var off = 0   // keep frames small: stderr can arrive in big chunks
                    while off < chunk.count {
                        let part = chunk[off..<min(off + 64 * 1024, chunk.count)]
                        child.emit(.stderr(id: id, data: Data(part)), via: { self.send($0, via: w) })
                        off += part.count
                    }
                },
                onExit: { [weak self, weak child] status in
                    guard let self, let child else { return }
                    child.emit(.exit(id: id, status: Int(status)), via: { self.send($0, via: w) })
                    self.lock.lock(); self.children[id] = nil; self.lock.unlock()
                })
        } catch { release(); return fail(Self.describe(error)) }
        child.announce(.spawned(id: id, pid: Int(proc.processIdentifier)), via: { send($0, via: w) })
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as WorkspaceError:
            switch e {
            case .invalidName: return "invalid workspace name"
            case .rootInvalid(let r): return r
            case .notFound: return "workspace not found"
            case .notADirectory: return "workspace is not a directory"
            case .symlink: return "workspace is a symlink (refused)"
            case .escapesRoot: return "workspace resolves outside the work root (refused)"
            case .notOwned: return "workspace is not owned by the agent user"
            case .exists: return "workspace already exists"
            case .tooMany: return "too many workspaces"
            case .system(let w, let n): return "\(w): \(String(cString: strerror(n)))"
            }
        case let e as HostEnvironmentError:
            if case .tokenFileUnsafe(let r) = e { return "oauth token file unsafe: " + r }
            return "\(e)"
        case let e as ChatError:
            switch e {
            case .invalidConfig(let m), .spawnFailed(let m): return m
            default: return "\(e)"
            }
        default: return error.localizedDescription
        }
    }

    // MARK: teardown

    /// SIGTERM to every child, SIGKILL after `killGrace`, returns when all have reported their exit (or after a hard cap).
    func terminateAllAndWait() {
        func snapshot() -> [Child] { lock.lock(); defer { lock.unlock() }; return Array(children.values) }
        let first = snapshot()
        if first.isEmpty { return }
        for c in first { c.process?.terminate() }
        let graceEnd = Date().addingTimeInterval(config.killGrace)
        while Date() < graceEnd, !snapshot().isEmpty { Thread.sleep(forTimeInterval: 0.02) }
        for c in snapshot() { c.process?.kill() }
        let hardEnd = Date().addingTimeInterval(3)
        while Date() < hardEnd, !snapshot().isEmpty { Thread.sleep(forTimeInterval: 0.02) }
        lock.lock(); children.removeAll(); lock.unlock()
    }
}
