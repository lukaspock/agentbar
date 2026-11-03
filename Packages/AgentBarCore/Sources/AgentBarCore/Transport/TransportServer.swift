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
    public let security: TransportSecurity
    public var socketPath: String { directory.appendingPathComponent("agentbar.sock").path }
    public var tokenPath: String { directory.appendingPathComponent("token").path }
    /// Group socket and agent token (nil without a shared directory configured). Only usable when `sharedStatus == .active`.
    public var sharedSocketPath: String? { security.sharedDirectory?.appendingPathComponent("agentbar.sock").path }
    public var agentTokenPath: String? { security.sharedDirectory?.appendingPathComponent(TransportSecurity.agentTokenFileName).path }
    public var sharedStatus: SharedSocketStatus { lock.lock(); defer { lock.unlock() }; return sharedState }

    var tokenForTests: String { currentToken(.owner) }
    var agentTokenForTests: String { currentToken(.agent) }
    private func currentToken(_ role: PeerRole) -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: tokens[role]?.last?.bytes ?? [], as: UTF8.self)
    }
    /// App side of the host channel (`op: "host"`, agent role only). Pass `hostClient.processFactory` to `ChatSession`.
    public let hostClient = HostClient()
    private let store: SessionStore
    private let adapters: [String: AgentAdapter]
    private let origins = SessionOrigins()
    private let lock = NSLock()
    private var running = false
    private struct TokenEntry { var bytes: [UInt8]; var expires: Date? }
    /// Per role; the last entry is the current token, earlier ones are rotated-out tokens that die at `expires`.
    private var tokens: [PeerRole: [TokenEntry]] = [:]
    private var sharedState: SharedSocketStatus = .disabled
    private var sharedGidResolved: gid_t?
    private struct Listener { var fd: Int32; var allowed: Set<PeerRole>; var done: DispatchSemaphore; var path: String }
    private var listeners: [Listener] = []
    private var stopPipe: [Int32] = [-1, -1]
    private var connections: [Int32: PeerRole] = [:]
    static let maxConnections = 512
    /// The kernel clamps this to kern.ipc.somaxconn; the CLI additionally retries a refused connect (burst load).
    static let listenBacklog: Int32 = 1024
    private static let readDeadline: TimeInterval = 15

    /// Single-user transport (only our own uid), exactly as before the agent user existed.
    public convenience init(store: SessionStore, adapters: [String: AgentAdapter] = [:],
                            directory: URL = TransportServer.defaultDirectory) {
        self.init(store: store, adapters: adapters, directory: directory, security: .singleUser)
    }

    public init(store: SessionStore, adapters: [String: AgentAdapter] = [:],
                directory: URL = TransportServer.defaultDirectory, security: TransportSecurity) {
        self.store = store
        self.adapters = adapters
        self.directory = directory
        self.security = security
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

        // Fresh owner token, regenerated at every start.
        let ownerHex = try Self.randomToken()
        try Self.writeTokenFile(ownerHex, path: tokenPath, mode: 0o600, gid: nil)

        // Owner socket (unchanged: directory 0700, socket 0600).
        let fd: Int32
        do { fd = try Self.bindListener(path: sockPath, umask: 0o177, mode: 0o600, gid: nil) }
        catch { unlink(tokenPath); throw error }

        var p: [Int32] = [-1, -1]
        pipe(&p)
        SocketIO.setCloexec(p[0]); SocketIO.setCloexec(p[1])
        stopPipe = p
        tokens = [.owner: [TokenEntry(bytes: Array(ownerHex.utf8), expires: nil)]]
        sharedState = .disabled
        sharedGidResolved = nil
        listeners = [Listener(fd: fd, allowed: [.owner], done: DispatchSemaphore(value: 0), path: sockPath)]

        // Group socket for the agent user. Failure here never affects the owner socket (fail closed: the listener just stays off).
        if let shared = security.sharedDirectory {
            do {
                let (sfd, agentHex, gid) = try startShared(directory: shared)
                tokens[.agent] = [TokenEntry(bytes: Array(agentHex.utf8), expires: nil)]
                sharedGidResolved = gid
                listeners.append(Listener(fd: sfd, allowed: [.owner, .agent], done: DispatchSemaphore(value: 0),
                                          path: shared.appendingPathComponent("agentbar.sock").path))
                sharedState = .active
            } catch let SharedStartFailure.reason(r) {
                sharedState = .unavailable(r)
            } catch {
                sharedState = .unavailable("\(error)")
            }
        }

        running = true
        for l in listeners {
            let (lfd, sfd, allowed, done) = (l.fd, p[0], l.allowed, l.done)
            let t = Thread { [self] in
                acceptLoop(listenFd: lfd, stopFd: sfd, allowed: allowed)
                done.signal()
            }
            t.name = allowed.contains(.agent) ? "agentbar.accept.shared" : "agentbar.accept"
            t.start()
        }
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        var b: UInt8 = 1
        _ = write(stopPipe[1], &b, 1)
        for c in connections.keys { shutdown(c, SHUT_RDWR) }   // wakes handlers; waiting asks get cancelled
        let ls = listeners
        lock.unlock()

        for l in ls { _ = l.done.wait(timeout: .now() + 2) }
        lock.lock()
        for l in ls { close(l.fd); unlink(l.path) }   // socket before token
        close(stopPipe[0]); close(stopPipe[1])
        listeners = []; stopPipe = [-1, -1]
        unlink(tokenPath)
        if let a = agentTokenPath, sharedState == .active { unlink(a) }
        tokens = [:]
        sharedState = .disabled
        lock.unlock()
    }

    /// Replaces the token of every active role (temp file + rename, so readers never see a partial or missing file).
    /// The previous tokens stay valid for `grace` seconds: the CLI re-reads the file per call, only long-lived connections
    /// authenticate once. Throws before changing anything in memory if a file cannot be written.
    public func rotateTokens(grace: TimeInterval = 60) throws {
        lock.lock(); defer { lock.unlock() }
        guard running else { return }
        let ownerHex = try Self.randomToken()
        try Self.writeTokenFile(ownerHex, path: tokenPath, mode: 0o600, gid: nil)
        var fresh: [PeerRole: String] = [.owner: ownerHex]
        if sharedState == .active, let ap = agentTokenPath {
            let h = try Self.randomToken()
            try Self.writeTokenFile(h, path: ap, mode: 0o640, gid: sharedGidResolved)
            fresh[.agent] = h
        }
        let until = Date().addingTimeInterval(max(0, grace))
        for (role, hex) in fresh {
            var list = (tokens[role] ?? []).map { TokenEntry(bytes: $0.bytes, expires: $0.expires ?? until) }
            list.append(TokenEntry(bytes: Array(hex.utf8), expires: nil))
            tokens[role] = list
        }
    }

    private enum SharedStartFailure: Error { case reason(String) }

    /// Creates the group directory / socket / agent token. Must hold `lock`. Leaves nothing behind on failure.
    private func startShared(directory dir: URL) throws -> (fd: Int32, token: String, gid: gid_t) {
        func fail(_ r: String) -> SharedStartFailure { .reason(r) }
        guard security.agentUid != nil, security.agentUid != security.ownerUid else { throw fail("no agent uid configured") }
        guard security.sharedDirMode & ~mode_t(0o750) == 0, security.sharedDirMode & 0o700 == 0o700 else {
            throw fail("directory mode must be 0750 or stricter (group write would let the agent swap socket and token)")
        }
        guard security.sharedSocketMode & 0o007 == 0 else { throw fail("socket mode grants world access") }
        var gid: gid_t
        if let g = security.sharedGid { gid = g }
        else if let name = security.sharedGroupName, let gr = getgrnam(name) { gid = gr.pointee.gr_gid }
        else { throw fail("group \(security.sharedGroupName ?? "?") not found") }
        guard dir.standardizedFileURL.path != directory.standardizedFileURL.path else { throw fail("shared directory equals owner directory") }

        let dirPath = dir.path
        // Create private first, hand to the group, only then open it up to r-x: no window where the wrong group can enter.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(dirPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == geteuid() else { throw fail("insecure directory") }
        guard chmod(dirPath, 0o700) == 0 else { throw fail("chmod dir failed (\(errno))") }
        guard chown(dirPath, uid_t.max, gid) == 0 else { throw fail("chown to group failed (\(errno)); owner must be a member of the group") }
        guard chmod(dirPath, security.sharedDirMode) == 0 else { throw fail("chmod dir failed (\(errno))") }
        guard lstat(dirPath, &st) == 0, st.st_gid == gid, st.st_mode & 0o007 == 0 else { throw fail("directory not in the expected state") }

        let sockPath = dir.appendingPathComponent("agentbar.sock").path
        if lstat(sockPath, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK else { throw fail("not a socket") }
            if Self.probeLive(sockPath) { throw fail("socket in use") }
            unlink(sockPath)
        }
        let hex: String
        do { hex = try Self.randomToken() } catch { throw fail("random") }
        let tokenFile = dir.appendingPathComponent(TransportSecurity.agentTokenFileName).path
        do { try Self.writeTokenFile(hex, path: tokenFile, mode: 0o640, gid: gid) } catch { throw fail("token: \(error)") }
        let umaskBits = ~security.sharedSocketMode & 0o777
        do {
            let fd = try Self.bindListener(path: sockPath, umask: umaskBits, mode: security.sharedSocketMode, gid: gid)
            return (fd, hex, gid)
        } catch {
            unlink(tokenFile)
            throw fail("socket: \(error)")
        }
    }

    private static func randomToken() throws -> String {
        var raw = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw) == errSecSuccess else { throw ServerError.system("random", 0) }
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    /// bind (restrictive umask during the bind window) + chmod/chown + listen. Cleans up on failure.
    private static func bindListener(path: String, umask mask: mode_t, mode: mode_t, gid: gid_t?) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.system("socket", errno) }
        SocketIO.setCloexec(fd)
        let oldMask = umask(mask)
        let bound = SocketIO.withSockaddr(path: path) { bind(fd, $0, $1) }
        umask(oldMask)
        guard let rc = bound else { close(fd); throw ServerError.pathTooLong }
        guard rc == 0 else { let e = errno; close(fd); throw ServerError.system("bind", e) }
        if let gid, chown(path, uid_t.max, gid) != 0 { let e = errno; close(fd); unlink(path); throw ServerError.system("chown socket", e) }
        guard chmod(path, mode) == 0, listen(fd, listenBacklog) == 0 else {
            let e = errno; close(fd); unlink(path); throw ServerError.system("listen", e)
        }
        return fd
    }

    /// Writes `hex` to `path` atomically: private temp file (O_EXCL, no symlink following), group and mode set before
    /// the content becomes visible, then rename over the target.
    private static func writeTokenFile(_ hex: String, path: String, mode: mode_t, gid: gid_t?) throws {
        let tmp = path + ".tmp.\(getpid())"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ServerError.system("token", errno) }
        var ok = false
        defer { close(fd); if !ok { unlink(tmp) } }
        if let gid, fchown(fd, uid_t.max, gid) != 0 { throw ServerError.system("token chown", errno) }
        guard SocketIO.writeAll(fd, Data(hex.utf8)) else { throw ServerError.system("token write", errno) }
        guard fchmod(fd, mode) == 0 else { throw ServerError.system("token chmod", errno) }
        guard rename(tmp, path) == 0 else { throw ServerError.system("token rename", errno) }
        ok = true
    }

    private static func probeLive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return SocketIO.withSockaddr(path: path) { connect(fd, $0, $1) } == 0
    }

    /// Constant-time check against all currently valid tokens of the peer's role.
    private func tokenValid(_ tok: String, role: PeerRole) -> Bool {
        lock.lock()
        let now = Date()
        let valid = (tokens[role] ?? []).filter { $0.expires.map { $0 > now } ?? true }.map(\.bytes)
        lock.unlock()
        let given = Array(tok.utf8)
        var any = false
        for t in valid where !t.isEmpty { if SocketIO.constantTimeEqual(given, t) { any = true } }
        return any
    }

    // MARK: Accepting

    private func acceptLoop(listenFd: Int32, stopFd: Int32, allowed: Set<PeerRole>) {
        while true {
            var pfds = [pollfd(fd: listenFd, events: Int16(POLLIN), revents: 0),
                        pollfd(fd: stopFd, events: Int16(POLLIN), revents: 0)]
            let rc = poll(&pfds, 2, -1)
            if rc < 0 { if errno == EINTR { continue }; return }
            if pfds[1].revents != 0 { return }
            guard pfds[0].revents & Int16(POLLIN) != 0 else { continue }
            let c = accept(listenFd, nil, nil)
            if c < 0 { continue }
            // Defense in depth on top of directory/socket modes and the token: the kernel-reported uid decides the role,
            // and the listener decides which roles it serves at all. Unknown uid => closed.
            guard let cred = security.peerCredentials(c), let role = security.role(forUid: cred.uid), allowed.contains(role) else {
                close(c); continue
            }
            SocketIO.setCloexec(c)
            SocketIO.setNoSigPipe(c)
            lock.lock()
            let roleCount = connections.values.filter { $0 == role }.count
            let roleCap = role == .agent ? security.agentQuota.maxConnections : Self.maxConnections
            let ok = running && connections.count < Self.maxConnections && roleCount < roleCap
            if ok { connections[c] = role }
            lock.unlock()
            if !ok { close(c); continue }
            let t = Thread { [self] in handle(fd: c, role: role) }
            t.name = "agentbar.conn"
            t.start()
        }
    }

    // MARK: Connection handling

    private enum ReadResult { case line(Data), tooLong, closed, timeout }

    private func handle(fd: Int32, role: PeerRole) {
        defer {
            lock.lock(); connections[fd] = nil; lock.unlock()
            close(fd)
        }
        switch readLine(fd) {
        case .closed, .timeout: return
        case .tooLong: reply(fd, Self.error("line too long")); drain(fd)
        case .line(let data):
            guard let reply = process(data, fd: fd, role: role) else { return }
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

    /// nil = allowed. Runs on the main actor (store access) and records who created the ids.
    private func authorize(role: PeerRole, ids: Set<String>, rejectChatOwned: Bool) -> String? {
        let maxSessions = security.agentQuota.maxSessions
        return onMain { [store, origins] in
            origins.claim(role: role, ids: ids, store: store, agentMaxSessions: maxSessions, rejectChatOwned: rejectChatOwned)
        }
    }

    /// Returns nil when the connection was dropped while waiting (no reply is sent).
    private func process(_ line: Data, fd: Int32, role: PeerRole) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: line, options: []),
              let req = obj as? [String: Any] else { return Self.error("malformed json") }
        // The token must be the one of the peer's own role: the owner token does not open the agent role and vice versa.
        guard let tok = str(req, "token"), tokenValid(tok, role: role) else { return Self.error("unauthorized") }
        guard let op = str(req, "op") else { return Self.error("missing op") }
        if role == .agent && !TransportSecurity.agentOps.contains(op) { return Self.error("forbidden") }

        if op == "payload" { return processPayload(req, fd: fd, role: role) }
        if op == "watch" { return processWatch(req, fd: fd, role: role) }
        if op == "host" {
            // Long-lived duplex channel to the agent-user host. Only the agent role may open it (the owner never needs to).
            guard role == .agent else { return Self.error("forbidden") }
            // Only the installed root-owned agentbar-host binary may register (scripts / copied binaries are refused).
            guard security.hostBinary.allows(fd: fd) else { return Self.error("forbidden") }
            return hostClient.acceptHost(req, fd: fd, peerUid: security.peerCredentials(fd)?.uid)
        }

        guard let session = str(req, "session"), !session.isEmpty, session.count <= AgentBarLimits.maxIdLength else {
            return Self.error("invalid session")
        }
        if ["update", "log", "end", "remove", "ask"].contains(op) {
            // Chat-owned ids are refused for every role; the agent role additionally only reaches ids it created itself.
            if let denied = authorize(role: role, ids: [session], rejectChatOwned: true) { return Self.error(denied) }
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
            // `answer`/`request` entries are written by the store itself (and ChatSession); never by clients.
            if kind == .answer || kind == .request { return Self.error("kind not allowed") }
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
            return processAsk(req, session: session, fd: fd, role: role)
        default:
            return Self.error("unknown op")
        }
    }

    private func processAsk(_ req: [String: Any], session: String, fd: Int32, role: PeerRole) -> [String: Any]? {
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
        guard let outcome = submitAndWait(session: session, request: request, fd: fd, role: role) else { return nil }
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
    private func submitAndWait(session: String, request: AgentRequest, fd: Int32, role: PeerRole) -> AskOutcome? {
        let waiter = ResponseWaiter()
        let agentPendingCap = security.agentQuota.maxPendingRequests
        let result = onMain { [store, origins] () -> SessionStore.AskResult in
            if role == .agent && origins.agentPendingCount(store: store) >= agentPendingCap { return .tooManyPending }
            return store.submit(sessionId: session, request: request, waiter: { waiter.deliver($0) })
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
    private func processWatch(_ req: [String: Any], fd: Int32, role: PeerRole) -> [String: Any]? {
        guard let session = str(req, "session"), !session.isEmpty, session.count <= AgentBarLimits.maxIdLength else {
            return Self.error("invalid session")
        }
        // The owner may watch anything (the app's own chat rows included); the agent only the sessions it created.
        if role == .agent, let denied = authorize(role: role, ids: [session], rejectChatOwned: true) { return Self.error(denied) }
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

    private func processPayload(_ req: [String: Any], fd: Int32, role: PeerRole) -> [String: Any]? {
        guard let name = str(req, "adapter"), let adapter = adapters[name] else { return Self.error("unknown adapter") }
        guard let payload = req["payload"],
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]) else {
            return Self.error("invalid payload")
        }
        guard let events = try? adapter.translate(payload: data) else { return Self.error("invalid payload") }
        let touched = Set(events.compactMap { ev -> String? in
            switch ev {
            case .sessionUpdate(let id, _, _, _, _, _): return id
            case .ask(let sid, _), .cancelRequest(let sid, _), .log(let sid, _): return sid
            case .sessionEnd(let id): return id
            }
        })
        // Hook session ids that belong to an in-app chat (the chat's own id or the claude session id it reported) are refused:
        // the chat already shows its own approvals, a second one from a hook would be a double prompt.
        if let denied = authorize(role: role, ids: touched, rejectChatOwned: true) { return Self.error(denied) }
        var blocking: (String, AgentRequest)?
        for ev in events {
            if case let .ask(sid, r) = ev, blocking == nil { blocking = (sid, r); continue }
            onMain { [store] in store.apply(ev) }
        }
        guard let (sid, request) = blocking else { return ["ok": true, "output": ""] }
        guard let outcome = submitAndWait(session: sid, request: request, fd: fd, role: role) else { return nil }
        switch outcome {
        case .failure:
            return ["ok": true, "output": ""]   // cap/duplicate: no decision, agent shows its own dialog
        case .success(let r):
            let out = adapter.encode(response: r, for: request)
            return ["ok": true, "output": String(decoding: out, as: UTF8.self)]
        }
    }
}
