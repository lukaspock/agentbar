import Foundation
import Security

/// Unix-domain-socket server implementing the AgentBar wire protocol (see CONTRACTS.md).
/// One request per connection; the connection is closed after the reply.
final class MainBox<T>: @unchecked Sendable { var value: T? }

public final class TransportServer: @unchecked Sendable {
    public enum ServerError: Error, Equatable {
        case alreadyRunning
        case pathTooLong
        case insecureDirectory
        case notASocket
        case system(String, Int32)
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentBar", isDirectory: true)
    }

    public let directory: URL
    public var socketPath: String { directory.appendingPathComponent("agentbar.sock").path }
    public var tokenPath: String { directory.appendingPathComponent("token").path }

    var tokenForTests: String { lock.lock(); defer { lock.unlock() }; return String(decoding: tokenBytes, as: UTF8.self) }
    private let store: SessionStore
    private let adapters: [String: AgentAdapter]
    private let lock = NSLock()
    private var running = false
    private var tokenBytes: [UInt8] = []
    private var listenFd: Int32 = -1
    private var stopPipe: [Int32] = [-1, -1]
    private var connections = Set<Int32>()
    private var acceptDone: DispatchSemaphore?
    static let maxConnections = 512
    /// The kernel clamps this to kern.ipc.somaxconn; the CLI additionally retries a refused connect (burst load).
    static let listenBacklog: Int32 = 1024
    private static let readDeadline: TimeInterval = 15

    public init(store: SessionStore, adapters: [String: AgentAdapter] = [:],
                directory: URL = TransportServer.defaultDirectory) {
        self.store = store
        self.adapters = adapters
        self.directory = directory
    }

    deinit { stop() }

    // MARK: Lifecycle

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        // A client that dies right after connecting makes SO_NOSIGPIPE fail (EINVAL on a reset socket) and the reply
        // write would then raise SIGPIPE and kill the whole app. Ignore it process-wide.
        signal(SIGPIPE, SIG_IGN)

        // Directory 0700, owned by us.
        let dirPath = directory.path
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(dirPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == geteuid() else {
            throw ServerError.insecureDirectory
        }
        guard chmod(dirPath, 0o700) == 0 else { throw ServerError.system("chmod dir", errno) }

        // Stale socket cleanup. A live listener means another instance owns the directory.
        let sockPath = socketPath
        if lstat(sockPath, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK else { throw ServerError.notASocket }
            if Self.probeLive(sockPath) { throw ServerError.alreadyRunning }
            unlink(sockPath)
        }

        // Fresh token, regenerated at every start.
        var raw = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw) == errSecSuccess else {
            throw ServerError.system("random", 0)
        }
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        try writeTokenFile(hex)
        tokenBytes = Array(hex.utf8)

        // Socket.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.system("socket", errno) }
        SocketIO.setCloexec(fd)
        let oldMask = umask(0o177)
        let bound = SocketIO.withSockaddr(path: sockPath) { bind(fd, $0, $1) }
        umask(oldMask)
        guard let rc = bound else { close(fd); throw ServerError.pathTooLong }
        guard rc == 0 else { let e = errno; close(fd); throw ServerError.system("bind", e) }
        guard chmod(sockPath, 0o600) == 0, listen(fd, Self.listenBacklog) == 0 else {
            let e = errno; close(fd); unlink(sockPath); throw ServerError.system("listen", e)
        }

        var p: [Int32] = [-1, -1]
        pipe(&p)
        SocketIO.setCloexec(p[0]); SocketIO.setCloexec(p[1])
        stopPipe = p
        listenFd = fd
        running = true
        let done = DispatchSemaphore(value: 0)
        acceptDone = done
        let (lfd, sfd) = (fd, p[0])
        let t = Thread { [self] in
            acceptLoop(listenFd: lfd, stopFd: sfd)
            done.signal()
        }
        t.name = "agentbar.accept"
        t.start()
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        var b: UInt8 = 1
        _ = write(stopPipe[1], &b, 1)
        for c in connections { shutdown(c, SHUT_RDWR) }   // wakes handlers; waiting asks get cancelled
        let done = acceptDone
        lock.unlock()

        _ = done?.wait(timeout: .now() + 2)
        lock.lock()
        close(listenFd); close(stopPipe[0]); close(stopPipe[1])
        listenFd = -1; stopPipe = [-1, -1]
        unlink(socketPath); unlink(tokenPath)
        tokenBytes = []
        lock.unlock()
    }

    private func writeTokenFile(_ hex: String) throws {
        unlink(tokenPath)
        let fd = open(tokenPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ServerError.system("token", errno) }
        defer { close(fd) }
        guard SocketIO.writeAll(fd, Data(hex.utf8)) else { throw ServerError.system("token write", errno) }
        fchmod(fd, 0o600)
    }

    private static func probeLive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return SocketIO.withSockaddr(path: path) { connect(fd, $0, $1) } == 0
    }

    // MARK: Accepting

    private func acceptLoop(listenFd: Int32, stopFd: Int32) {
        while true {
            var pfds = [pollfd(fd: listenFd, events: Int16(POLLIN), revents: 0),
                        pollfd(fd: stopFd, events: Int16(POLLIN), revents: 0)]
            let rc = poll(&pfds, 2, -1)
            if rc < 0 { if errno == EINTR { continue }; return }
            if pfds[1].revents != 0 { return }
            guard pfds[0].revents & Int16(POLLIN) != 0 else { continue }
            let c = accept(listenFd, nil, nil)
            if c < 0 { continue }
            // Defense in depth on top of the 0700 directory / 0600 socket: only our own uid may talk to us.
            var peerUid: uid_t = 0, peerGid: gid_t = 0
            guard getpeereid(c, &peerUid, &peerGid) == 0, peerUid == geteuid() else { close(c); continue }
            SocketIO.setCloexec(c)
            SocketIO.setNoSigPipe(c)
            lock.lock()
            let ok = running && connections.count < Self.maxConnections
            if ok { connections.insert(c) }
            lock.unlock()
            if !ok { close(c); continue }
            let t = Thread { [self] in handle(fd: c) }
            t.name = "agentbar.conn"
            t.start()
        }
    }

    // MARK: Connection handling

    private enum ReadResult { case line(Data), tooLong, closed, timeout }

    private func handle(fd: Int32) {
        defer {
            lock.lock(); connections.remove(fd); lock.unlock()
            close(fd)
        }
        switch readLine(fd) {
        case .closed, .timeout: return
        case .tooLong: reply(fd, Self.error("line too long")); drain(fd)
        case .line(let data):
            guard let reply = process(data, fd: fd) else { return }
            self.reply(fd, reply)
            drain(fd)
        }
    }

    private func reply(_ fd: Int32, _ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        d.append(0x0A)
        SocketIO.writeAll(fd, d)
    }

    /// After replying, half-close and swallow remaining input briefly so the peer still sees our reply
    /// (closing with unread data would send RST and could discard it).
    private func drain(_ fd: Int32) {
        shutdown(fd, SHUT_WR)
        var buf = [UInt8](repeating: 0, count: 8192)
        var total = 0
        while total < 4 * 1024 * 1024 {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&p, 1, 200)
            if rc <= 0 { return }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return }
            total += n
        }
    }

    private func readLine(_ fd: Int32) -> ReadResult {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(Self.readDeadline)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .timeout }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&p, 1, Int32(min(remaining, 3600) * 1000))
            if rc < 0 { if errno == EINTR { continue }; return .closed }
            if rc == 0 { return .timeout }
            let n = read(fd, &buf, buf.count)
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return .closed }
            if n == 0 { return .closed }
            let chunkStart = data.count
            data.append(contentsOf: buf[0..<n])
            if let nl = data[chunkStart...].firstIndex(of: 0x0A) {
                let idx = nl - data.startIndex
                return idx > AgentBarLimits.maxLineBytes ? .tooLong : .line(data.prefix(idx))
            }
            if data.count > AgentBarLimits.maxLineBytes { return .tooLong }
        }
    }

    // MARK: Request processing

    static func error(_ msg: String) -> [String: Any] { ["ok": false, "error": msg] }
    private static var ok: [String: Any] { ["ok": true] }

    private func onMain<T: Sendable>(_ body: @escaping @MainActor @Sendable () -> T) -> T {
        let box = MainBox<T>(); let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in box.value = body(); sem.signal() }
        sem.wait()
        return box.value!
    }

    private func str(_ d: [String: Any], _ k: String) -> String? { d[k] as? String }

    /// Returns nil when the connection was dropped while waiting (no reply is sent).
    private func process(_ line: Data, fd: Int32) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: line, options: []),
              let req = obj as? [String: Any] else { return Self.error("malformed json") }
        lock.lock(); let expected = tokenBytes; lock.unlock()
        guard let tok = str(req, "token"), !expected.isEmpty,
              SocketIO.constantTimeEqual(Array(tok.utf8), expected) else { return Self.error("unauthorized") }
        guard let op = str(req, "op") else { return Self.error("missing op") }

        if op == "payload" { return processPayload(req, fd: fd) }
        if op == "watch" { return processWatch(req, fd: fd) }

        guard let session = str(req, "session"), !session.isEmpty, session.count <= AgentBarLimits.maxIdLength else {
            return Self.error("invalid session")
        }
        switch op {
        case "update":
            var kind: AgentKind?, state: SessionState?
            if let k = req["kind"] { guard let s = k as? String, let v = AgentKind(rawValue: s) else { return Self.error("invalid kind") }; kind = v }
            if let k = req["state"] { guard let s = k as? String, let v = SessionState(rawValue: s) else { return Self.error("invalid state") }; state = v }
            if req["name"] != nil && str(req, "name") == nil { return Self.error("invalid name") }
            if req["action"] != nil && str(req, "action") == nil { return Self.error("invalid action") }
            if req["supportsStop"] != nil && !(req["supportsStop"] is Bool) { return Self.error("invalid supportsStop") }
            let ev = CoreEvent.sessionUpdate(id: session, name: str(req, "name"), kind: kind, state: state,
                                             action: str(req, "action"), supportsStop: req["supportsStop"] as? Bool)
            onMain { [store] in store.apply(ev) }
            return Self.ok
        case "log":
            guard let ks = str(req, "kind"), let kind = HistoryEntry.Kind(rawValue: ks) else { return Self.error("invalid kind") }
            guard let text = str(req, "text") else { return Self.error("invalid text") }
            let ev = CoreEvent.log(sessionId: session, entry: HistoryEntry(kind: kind, text: text))
            onMain { [store] in store.apply(ev) }
            return Self.ok
        case "end":
            onMain { [store] in store.apply(.sessionEnd(id: session)) }
            return Self.ok
        case "remove":
            onMain { [store] in store.remove(sessionId: session) }
            return Self.ok
        case "ask":
            return processAsk(req, session: session, fd: fd)
        default:
            return Self.error("unknown op")
        }
    }

    private func processAsk(_ req: [String: Any], session: String, fd: Int32) -> [String: Any]? {
        guard let ts = str(req, "type"), let type = RequestType(rawValue: ts) else { return Self.error("invalid type") }
        guard let text = str(req, "text") else { return Self.error("invalid text") }
        var options: [RequestOption] = []
        if let raw = req["options"] {
            guard let arr = raw as? [Any] else { return Self.error("invalid options") }
            guard arr.count <= AgentBarLimits.maxOptions else { return Self.error("too many options") }
            for o in arr {
                guard let d = o as? [String: Any], let id = str(d, "id"), let label = str(d, "label"),
                      !id.isEmpty, id.count <= AgentBarLimits.maxIdLength else { return Self.error("invalid options") }
                var style = RequestOption.Style.normal
                if let s = d["style"] { guard let ss = s as? String, let v = RequestOption.Style(rawValue: ss) else { return Self.error("invalid options") }; style = v }
                options.append(RequestOption(id: id, label: label, style: style))
            }
        }
        var timeout: Int?
        if let t = req["timeout"] {
            guard let n = (t as? NSNumber)?.intValue, n >= 0, n <= AgentBarLimits.maxTimeoutSeconds else { return Self.error("invalid timeout") }
            timeout = n
        }
        var def: String?
        if let d = req["default"] { guard let s = d as? String else { return Self.error("invalid default") }; def = s }
        var rid = UUID().uuidString
        if let r = req["requestId"] {
            guard let s = r as? String, !s.isEmpty, s.count <= AgentBarLimits.maxIdLength else { return Self.error("invalid requestId") }
            rid = s
        }
        let request = AgentRequest(requestId: rid, type: type, text: text, options: options,
                                   timeoutSeconds: timeout, defaultOptionId: def)
        guard let outcome = submitAndWait(session: session, request: request, fd: fd) else { return nil }
        switch outcome {
        case .failure(let msg): return Self.error(msg)
        case .success(let r):
            var out: [String: Any] = ["ok": true, "requestId": r.requestId, "reason": r.reason.rawValue]
            if let o = r.optionId { out["option"] = o }
            if let t = r.text { out["text"] = t }
            return out
        }
    }

    private enum AskOutcome { case success(AgentResponse), failure(String) }

    /// nil = peer disconnected while waiting (request has been cancelled).
    private func submitAndWait(session: String, request: AgentRequest, fd: Int32) -> AskOutcome? {
        let waiter = ResponseWaiter()
        let result = onMain { [store] in
            store.submit(sessionId: session, request: request, waiter: { waiter.deliver($0) })
        }
        switch result {
        case .accepted: break
        case .tooManyPending: return .failure("too many pending requests")
        case .duplicateRequest: return .failure("duplicate requestId")
        case .sessionLimit: return .failure("too many sessions")
        }
        switch waiter.wait(clientFd: fd) {
        case .response(let r): return .success(r)
        case .disconnected:
            let rid = request.requestId
            onMain { [store] in store.apply(.cancelRequest(sessionId: session, requestId: rid)) }
            return nil
        }
    }

    /// `watch`: long-lived connection of a session's controller (`agentbar run` / `agentbar watch`). The server sends one
    /// JSON line `{"ok":true,"event":"watching"}`, then `{"ok":true,"event":"stop|pause|resume"}` whenever the app
    /// issues that command for the session. `stop` is terminal (connection closed afterwards). Always returns nil.
    private func processWatch(_ req: [String: Any], fd: Int32) -> [String: Any]? {
        guard let session = str(req, "session"), !session.isEmpty, session.count <= AgentBarLimits.maxIdLength else {
            return Self.error("invalid session")
        }
        let queue = CommandQueue()
        let token = onMain { [store] in
            store.addCommandObserver { sid, cmd in if sid == session { queue.push(cmd) } }
        }
        defer { onMain { [store] in store.removeCommandObserver(token) } }
        reply(fd, ["ok": true, "event": "watching"])
        while true {
            switch queue.wait(clientFd: fd) {
            case .disconnected: return nil
            case .command(let c):
                reply(fd, ["ok": true, "event": c.rawValue])
                if c == .stop { return nil }
            }
        }
    }

    private func processPayload(_ req: [String: Any], fd: Int32) -> [String: Any]? {
        guard let name = str(req, "adapter"), let adapter = adapters[name] else { return Self.error("unknown adapter") }
        guard let payload = req["payload"],
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]) else {
            return Self.error("invalid payload")
        }
        guard let events = try? adapter.translate(payload: data) else { return Self.error("invalid payload") }
        var blocking: (String, AgentRequest)?
        for ev in events {
            if case let .ask(sid, r) = ev, blocking == nil { blocking = (sid, r); continue }
            onMain { [store] in store.apply(ev) }
        }
        guard let (sid, request) = blocking else { return ["ok": true, "output": ""] }
        guard let outcome = submitAndWait(session: sid, request: request, fd: fd) else { return nil }
        switch outcome {
        case .failure:
            return ["ok": true, "output": ""]   // cap/duplicate: no decision, agent shows its own dialog
        case .success(let r):
            let out = adapter.encode(response: r, for: request)
            return ["ok": true, "output": String(decoding: out, as: UTF8.self)]
        }
    }
}
