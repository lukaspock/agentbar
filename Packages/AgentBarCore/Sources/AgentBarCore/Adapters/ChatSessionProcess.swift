import Foundation

/// Everything needed to start the agent process. Built by `ChatConfig.launchSpec()`; the environment is the COMPLETE
/// environment of the child (nothing is inherited implicitly).
public struct ChatLaunchSpec: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]
    /// Set (only) for the agent-user host: structured request instead of local paths. `executable`, `workingDirectory` and
    /// `environment` are then placeholders that nobody may use; the host builds its own from this.
    public var remote: RemoteLaunch? = nil
}

/// What the host needs to start `claude` for a chat: no executable, no environment, no absolute path.
public struct RemoteLaunch: Sendable, Equatable {
    public var workspace: String
    public var model: String?
    public var maxBudgetUSD: Double?
    public var tools: [String]?
    public var permissionMode: String?
    public init(workspace: String, model: String? = nil, maxBudgetUSD: Double? = nil, tools: [String]? = nil, permissionMode: String? = nil) {
        self.workspace = workspace; self.model = model; self.maxBudgetUSD = maxBudgetUSD; self.tools = tools; self.permissionMode = permissionMode
    }
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
    /// OS process id once started (0 = unknown / not local).
    var processIdentifier: Int32 { get }
}

public extension ChatProcess {
    var processIdentifier: Int32 { 0 }
}

public typealias ChatProcessFactory = @Sendable (ChatLaunchSpec) throws -> ChatProcess

/// Process implementation. Does not start a shell; arguments are passed as argv.
///
/// Default (`newProcessGroup: false`): Foundation `Process`. Tool subprocesses started by claude share the app's process
/// group; a SIGKILL of claude alone can leave them running.
///
/// `newProcessGroup: true` (used by the agent-user host): `posix_spawn` with the child as leader of a NEW process group
/// and all other file descriptors closed in the child (`POSIX_SPAWN_CLOEXEC_DEFAULT`), signal dispositions reset.
/// `terminate()`/`kill()` then signal the whole group (`killpg`), and when the leader exits the rest of the group is killed
/// so tool subprocesses cannot outlive their session.
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
    private let grouped: Bool
    private var groupPid: pid_t = 0
    private var reaped = false

    public init(spec: ChatLaunchSpec, newProcessGroup: Bool = false) { self.spec = spec; self.grouped = newProcessGroup }

    public var processIdentifier: Int32 {
        lock.lock(); defer { lock.unlock() }
        return grouped ? groupPid : process.processIdentifier
    }

    public func start(onLine: @escaping @Sendable (Data) -> Void,
                      onStderr: @escaping @Sendable (Data) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        self.onLine = onLine
        self.onExit = onExit
        if grouped { try startGrouped(onStderr: onStderr); return }
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
        if grouped { signalGroup(SIGTERM) } else if process.isRunning { process.terminate() }
        let h = stdinPipe.fileHandleForWriting
        writeQueue.async { try? h.close() }
    }

    public func kill() {
        if grouped { signalGroup(SIGKILL); return }
        let pid = process.processIdentifier
        if process.isRunning, pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
    }

    // MARK: new process group (posix_spawn)

    private func signalGroup(_ sig: Int32) {
        lock.lock(); defer { lock.unlock() }
        if groupPid > 0, !reaped { _ = killpg(groupPid, sig) }
    }

    /// Called with `lock` held (from `start`).
    private func startGrouped(onStderr: @escaping @Sendable (Data) -> Void) throws {
        func fail(_ what: String, _ e: Int32) -> ChatError { .spawnFailed("\(what): \(String(cString: strerror(e)))") }
        var fa: posix_spawn_file_actions_t?
        var attr: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fa) == 0 else { throw fail("spawn actions", errno) }
        defer { posix_spawn_file_actions_destroy(&fa) }
        guard posix_spawnattr_init(&attr) == 0 else { throw fail("spawn attributes", errno) }
        defer { posix_spawnattr_destroy(&attr) }

        let inR = stdinPipe.fileHandleForReading.fileDescriptor
        let outW = stdoutPipe.fileHandleForWriting.fileDescriptor
        let errW = stderrPipe.fileHandleForWriting.fileDescriptor
        posix_spawn_file_actions_adddup2(&fa, inR, 0)
        posix_spawn_file_actions_adddup2(&fa, outW, 1)
        posix_spawn_file_actions_adddup2(&fa, errW, 2)
        let rc = posix_spawn_file_actions_addchdir_np(&fa, spec.workingDirectory.path)
        guard rc == 0 else { throw fail("working directory", rc) }

        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setpgroup(&attr, 0)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attr, Int16(flags))

        let argv = ([spec.executable.path] + spec.arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }

        var pid: pid_t = 0
        let err = posix_spawn(&pid, spec.executable.path, &fa, &attr, argv, envp)
        // The child's ends are no longer needed here (also on failure).
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        guard err == 0 else {
            self.onLine = nil; self.onExit = nil
            throw fail("cannot start \(spec.executable.lastPathComponent)", err)
        }
        groupPid = pid
        let leader = pid
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; self?.stdoutDone() } else { self?.feed(d) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { onStderr(d) }
        }
        let t = Thread { [weak self] in
            var status: Int32 = 0
            while waitpid(leader, &status, 0) < 0 && errno == EINTR {}
            _ = killpg(leader, SIGKILL)   // leader gone: nothing else of this session may keep running
            let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            self?.lock.lock(); self?.reaped = true; self?.lock.unlock()
            self?.processEnded(code)
        }
        t.name = "agentbar.chat.wait"
        t.start()
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
