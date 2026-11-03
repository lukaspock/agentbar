import Foundation

/// `ChatProcess` whose process runs under the agent user, behind the host channel. Created by `HostClient.processFactory`.
///
/// Behaviour contract (same as `PosixChatProcess`):
/// - `start` returns immediately; a failing spawn arrives as `onStderr(<reason>)` + `onExit(127)` (the existing
///   "claude exited with 127: ..." path of `ChatSession`). Only "host not connected" at start time throws.
/// - lost host connection => `onStderr("agent host disconnected")` + `onExit(255)`; the host kills the children itself.
/// - `onExit` fires exactly once. Callbacks run on the channel's reader thread and must not block (ChatSession hops to main).
public final class RemoteChatProcess: ChatProcess, @unchecked Sendable {
    public static let disconnectedStatus: Int32 = 255
    public static let spawnFailedStatus: Int32 = 127

    private enum Phase { case idle, requested, running, ended }

    public let processId: String
    private let launch: RemoteLaunch
    private weak var client: HostClient?
    private let lock = NSLock()
    private var phase: Phase = .idle
    private var _remotePid = 0
    private var onLine: (@Sendable (Data) -> Void)?
    private var onStderr: (@Sendable (Data) -> Void)?
    private var onExit: (@Sendable (Int32) -> Void)?

    public init(client: HostClient, launch: RemoteLaunch) {
        self.client = client; self.launch = launch
        self.processId = "p" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased()
    }

    /// Process id as seen by the host (informational: the app cannot signal it).
    public var remotePid: Int { lock.lock(); defer { lock.unlock() }; return _remotePid }

    public func start(onLine: @escaping @Sendable (Data) -> Void, onStderr: @escaping @Sendable (Data) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) throws {
        lock.lock()
        guard phase == .idle else { lock.unlock(); return }
        phase = .requested
        self.onLine = onLine; self.onStderr = onStderr; self.onExit = onExit
        lock.unlock()
        guard let client else { clearAfterFailure(); throw ChatError.spawnFailed("Agent host is not available") }
        let req = HostSpawnRequest(id: processId, agent: "claude", workspace: launch.workspace, model: launch.model,
                                   maxBudgetUSD: launch.maxBudgetUSD, tools: launch.tools, permissionMode: launch.permissionMode)
        do { try client.begin(self, request: req) } catch { clearAfterFailure(); throw error }
    }

    private func clearAfterFailure() {
        lock.lock(); phase = .ended; onLine = nil; onStderr = nil; onExit = nil; lock.unlock()
    }

    public func write(line: Data) {
        lock.lock(); let p = phase; lock.unlock()
        guard p == .requested || p == .running, line.count < HostProtocol.maxLineBytes / 2 else { return }
        client?.send(.stdin(id: processId, line: String(decoding: line, as: UTF8.self)))
    }

    public func terminate() { signal(.terminate(id: processId)) }
    public func kill() { signal(.kill(id: processId)) }
    private func signal(_ c: HostCommand) {
        lock.lock(); let p = phase; lock.unlock()
        if p == .requested || p == .running { client?.send(c) }
    }

    // MARK: events from HostClient (reader thread)

    func hostSpawned(pid: Int) {
        lock.lock(); if phase == .requested { phase = .running; _remotePid = pid }; lock.unlock()
    }

    /// Returns false if the frame was not acceptable in the current phase.
    func hostStdout(_ line: String) -> Bool {
        lock.lock(); let ok = phase == .running; let cb = onLine; lock.unlock()
        guard ok else { return false }
        cb?(Data(line.utf8))
        return true
    }

    func hostStderr(_ data: Data) -> Bool {
        lock.lock(); let ok = phase == .running; let cb = onStderr; lock.unlock()
        guard ok else { return false }
        cb?(data)
        return true
    }

    func hostExit(_ status: Int32) -> Bool {
        lock.lock()
        guard phase == .running else { lock.unlock(); return false }
        phase = .ended
        let cb = onExit
        onLine = nil; onStderr = nil; onExit = nil
        lock.unlock()
        cb?(status)
        return true
    }

    func hostSpawnFailed(_ message: String) { fail(message) }

    /// Request-level error for this id; only meaningful before the process runs. Returns true if it ended the process.
    func hostError(_ message: String) -> Bool {
        lock.lock(); let p = phase; lock.unlock()
        guard p == .requested else { return false }
        fail(message)
        return true
    }

    func hostDisconnected() {
        lock.lock(); let p = phase; lock.unlock()
        if p == .requested || p == .running { fail("agent host disconnected", status: Self.disconnectedStatus) }
    }

    private func fail(_ message: String, status: Int32 = RemoteChatProcess.spawnFailedStatus) {
        lock.lock()
        guard phase == .requested || phase == .running else { lock.unlock(); return }
        phase = .ended
        let (se, ex) = (onStderr, onExit)
        onLine = nil; onStderr = nil; onExit = nil
        lock.unlock()
        se?(Data((message + "\n").utf8))
        ex?(status)
    }
}
