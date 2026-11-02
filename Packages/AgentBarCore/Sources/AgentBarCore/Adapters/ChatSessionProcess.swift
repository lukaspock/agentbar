import Foundation

/// Everything needed to start the agent process. Built by `ChatConfig.launchSpec()`; the environment is the COMPLETE
/// environment of the child (nothing is inherited implicitly).
public struct ChatLaunchSpec: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]
}

/// Abstraction of the child process so the session logic can be tested with a fake. Callbacks may arrive on any thread.
public protocol ChatProcess: AnyObject, Sendable {
    /// `onLine`: one complete stdout line (without newline, max `ChatWire.maxLineBytes`). `onStderr`: raw chunks.
    /// `onExit`: exactly once, after stdout reached EOF and the process ended; 128+n for death by signal n.
    func start(onLine: @escaping @Sendable (Data) -> Void,
               onStderr: @escaping @Sendable (Data) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws
    /// Appends a newline and writes to stdin. Never blocks the caller; failures surface as process exit.
    func write(line: Data)
    /// SIGTERM, returns immediately.
    func terminate()
    /// SIGKILL, returns immediately.
    func kill()
}

public typealias ChatProcessFactory = @Sendable (ChatLaunchSpec) throws -> ChatProcess

/// Foundation `Process` implementation. Does not start a shell; arguments are passed as argv.
/// Limitation: tool subprocesses started by claude are in the same process group as claude; they normally die with it,
/// a SIGKILL of claude alone can leave them running.
public final class PosixChatProcess: ChatProcess, @unchecked Sendable {
    public static let factory: ChatProcessFactory = { PosixChatProcess(spec: $0) }

    private let spec: ChatLaunchSpec
    private let process = Process()
    private let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "agentbar.chat.stdin")
    private let lock = NSLock()
    private var buffer = Data()
    private var skippingOversize = false
    private var stdoutEOF = false
    private var exitStatus: Int32?
    private var exitFired = false
    private var onLine: (@Sendable (Data) -> Void)?
    private var onExit: (@Sendable (Int32) -> Void)?
    private var started = false

    public init(spec: ChatLaunchSpec) { self.spec = spec }

    public func start(onLine: @escaping @Sendable (Data) -> Void,
                      onStderr: @escaping @Sendable (Data) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        self.onLine = onLine
        self.onExit = onExit
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.currentDirectoryURL = spec.workingDirectory
        process.environment = spec.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; self?.stdoutDone() } else { self?.feed(d) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { onStderr(d) }
        }
        process.terminationHandler = { [weak self] p in
            let st = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
            self?.processEnded(st)
        }
        do { try process.run() } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            self.onLine = nil; self.onExit = nil
            throw error
        }
    }

    public func write(line: Data) {
        let d = line + Data([0x0A])
        let h = stdinPipe.fileHandleForWriting
        writeQueue.async { try? h.write(contentsOf: d) }
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
        let h = stdinPipe.fileHandleForWriting
        writeQueue.async { try? h.close() }
    }

    public func kill() {
        let pid = process.processIdentifier
        if process.isRunning, pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
    }

    // MARK: reading

    private func feed(_ data: Data) {
        var lines: [Data] = []
        lock.lock()
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if skippingOversize { skippingOversize = false } else if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        if buffer.count > ChatWire.maxLineBytes { buffer.removeAll(); skippingOversize = true }
        let cb = onLine
        lock.unlock()
        for l in lines { cb?(l) }
    }

    private func stdoutDone() {
        lock.lock()
        let rest = skippingOversize ? Data() : buffer
        buffer.removeAll()
        stdoutEOF = true
        let cb = onLine
        lock.unlock()
        if !rest.isEmpty { cb?(rest) }
        fireExitIfReady()
    }

    private func processEnded(_ status: Int32) {
        lock.lock(); exitStatus = status; lock.unlock()
        // A grandchild may keep stdout open forever: give EOF a short moment, then report the exit anyway.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.fireExit(force: true) }
        fireExitIfReady()
    }

    private func fireExitIfReady() { fireExit(force: false) }

    private func fireExit(force: Bool) {
        lock.lock()
        guard !exitFired, let st = exitStatus, stdoutEOF || force else { lock.unlock(); return }
        exitFired = true
        let cb = onExit
        onExit = nil; onLine = nil
        lock.unlock()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        cb?(st)
    }
}
