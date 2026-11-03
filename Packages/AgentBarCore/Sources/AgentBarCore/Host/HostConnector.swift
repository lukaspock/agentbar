import Foundation

/// Connects a `HostService` to the app's group socket as role agent and keeps it connected (reconnect with backoff).
/// Used by the `agentbar-host` executable; lives in the library so it can be tested against a real `TransportServer`.
public final class HostRunner: @unchecked Sendable {
    public enum ConnectError: Error, Equatable, Sendable {
        case noSocket(String)
        case noToken(String)
        case refused(String)
        case protocolError(String)
    }

    public static let defaultDirectory = "/Users/Shared/AgentBar"

    public let ipcDirectory: URL
    public let service: HostService
    private let lock = NSLock()
    private var stopped = false
    private var currentFd: Int32 = -1
    public var log: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(("agentbar-host: " + $0 + "\n").utf8)) }

    /// - Parameter ipcDirectory: directory with `agentbar.sock` and `token.agent` (env `AGENTBAR_IPC_DIR`, default `/Users/Shared/AgentBar`).
    public init(service: HostService, ipcDirectory: URL) { self.service = service; self.ipcDirectory = ipcDirectory }

    public func stop() {
        lock.lock(); stopped = true; let fd = currentFd; lock.unlock()
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        service.shutdown()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// Blocks until `stop()`. Each connection is served by `HostService.run`, which kills all children when the link ends.
    public func runForever() {
        var delay: TimeInterval = 0.5
        while !isStopped {
            do {
                let served = try connectOnce()
                if served { delay = 0.5 }
            } catch {
                log("\(error)")
            }
            if isStopped { break }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 2, 10)
        }
    }

    /// One connection attempt: connect, hello, ready, serve until the link ends. Returns true if it reached the serving state.
    @discardableResult
    public func connectOnce() throws -> Bool {
        let sockPath = ipcDirectory.appendingPathComponent("agentbar.sock").path
        let tokenPath = ipcDirectory.appendingPathComponent(TransportSecurity.agentTokenFileName).path
        guard let raw = try? String(contentsOfFile: tokenPath, encoding: .utf8) else { throw ConnectError.noToken(tokenPath) }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ConnectError.noToken(tokenPath) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectError.noSocket("socket: \(errno)") }
        SocketIO.setCloexec(fd); SocketIO.setNoSigPipe(fd)
        defer { close(fd) }
        guard let rc = SocketIO.withSockaddr(path: sockPath, { connect(fd, $0, $1) }), rc == 0 else {
            throw ConnectError.noSocket(sockPath)
        }
        lock.lock(); currentFd = fd; lock.unlock()
        defer { lock.lock(); currentFd = -1; lock.unlock() }

        let hello = HostHello(token: token, user: service.config.user, uid: Int(service.config.uid),
                              workspaceRoot: service.config.workspaceRoot.path, agents: service.discoverAgents())
        guard var line = try? JSONEncoder().encode(hello) else { throw ConnectError.protocolError("encode") }
        line.append(0x0A)
        guard SocketIO.writeAll(fd, line) else { throw ConnectError.refused("write failed") }

        let reader = HostLineReader(fd: fd)
        switch reader.next(timeout: 15) {
        case .line(let l):
            guard let obj = (try? JSONSerialization.jsonObject(with: l)) as? [String: Any] else { throw ConnectError.protocolError("bad reply") }
            guard obj["ok"] as? Bool == true, obj["event"] as? String == "ready" else {
                throw ConnectError.refused((obj["error"] as? String) ?? "not ready")
            }
        default: throw ConnectError.protocolError("no reply")
        }
        if isStopped { return false }
        log("connected to \(sockPath)")
        service.run(fd: fd, reader: reader)
        log("disconnected; all agent processes terminated")
        return true
    }
}
