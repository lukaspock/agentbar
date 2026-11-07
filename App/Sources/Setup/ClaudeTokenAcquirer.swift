import Foundation
import Darwin
import AgentBarCore

/// Phase 1 of the Claude token step: runs `claude setup-token` AS THE OWNER inside a pseudo terminal, extracts the OAuth
/// token from its output, and stages it in a fresh 0600 file under `Application Support/AgentBar/tmp` (directory 0700).
/// The admin block (phase 2) reads `stagedTokenPath` and moves the file into the agent home.
///
/// The token lives in memory only until it is written: it is never logged, never put into progress texts, never into argv
/// or the process name. Output of the child is never shown, only fixed status messages.
public final class ClaudeTokenAcquirer: SetupTokenAcquirer, @unchecked Sendable {
    public enum AcquireError: Error, CustomStringConvertible, Equatable {
        case claudeNotFound
        case ptyFailed(String)
        case spawnFailed(String)
        case timedOut
        case cancelled
        case exitedWithoutToken(Int32)
        case invalidToken
        case stagingFailed(String)

        public var description: String {
            switch self {
            case .claudeNotFound: return "claude CLI not found (looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin). Install Claude Code first."
            case .ptyFailed(let m): return "could not create a terminal for claude: \(m)"
            case .spawnFailed(let m): return "could not start claude setup-token: \(m)"
            case .timedOut: return "timed out waiting for the browser login of claude setup-token"
            case .cancelled: return "token setup cancelled"
            case .exitedWithoutToken(let s): return "claude setup-token ended (status \(s)) without a token; was the login completed?"
            case .invalidToken: return "that does not look like a Claude OAuth token (expected sk-ant-oat01-...)"
            case .stagingFailed(let m): return "could not stage the token: \(m)"
            }
        }
    }

    public static let columns: UInt16 = 1000
    /// Rolling tail of the child's output we keep for parsing.
    static let bufferCap = 16 * 1024
    /// After a token candidate showed up but cannot be confirmed as complete, accept it once the output was idle this long.
    static let idleGrace: TimeInterval = 1.0

    private let home: String
    private let claudeOverride: URL?
    private let timeout: TimeInterval
    private let stagingDirectory: URL

    private let lock = NSLock()
    private var _stagedPath: String?
    private var cancelFlag = false
    private var childPid: pid_t = 0

    /// - Parameters:
    ///   - claude: explicit executable (tests); nil = look in the usual install locations.
    ///   - stagingDirectory: nil = `~/Library/Application Support/AgentBar/tmp`.
    public init(home: String = NSHomeDirectory(), claude: URL? = nil, timeout: TimeInterval = 300, stagingDirectory: URL? = nil) {
        self.home = home; self.claudeOverride = claude; self.timeout = timeout
        self.stagingDirectory = stagingDirectory ?? URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/AgentBar/tmp", isDirectory: true)
    }

    /// Path of the staged 0600 token file for the admin block; nil until `acquire` succeeded (or after `discardStaged`).
    public var stagedTokenPath: String? { lock.lock(); defer { lock.unlock() }; return _stagedPath }

    /// Ends a running `acquire` (kills `claude setup-token`); the staged file, if any, is removed.
    public func cancel() {
        lock.lock(); cancelFlag = true; let pid = childPid; lock.unlock()
        if pid > 0 { killpg(pid, SIGTERM) }
    }

    /// Deletes the staged file (after the admin block consumed it, or on abort).
    public func discardStaged() {
        lock.lock(); let p = _stagedPath; _stagedPath = nil; lock.unlock()
        if let p { unlink(p) }
    }

    // MARK: SetupTokenAcquirer

    public func acquire(progress: @Sendable (String) -> Void) async throws {
        // Idempotent: a token that is already staged (sign-in page, then the setup run) is not fetched again.
        if hasValidStagedToken() { progress("Already signed in"); return }
        guard let exe = claudeOverride ?? ChatConfig.locateClaude(home: home) else { throw AcquireError.claudeNotFound }
        discardStaged()
        resetCancel()
        progress("Starting claude setup-token ...")
        let result: Result<[UInt8], Error> = await withoutActuallyEscaping(progress) { esc in
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Result<[UInt8], Error>, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        cont.resume(returning: self.runPTY(executable: exe, progress: esc))
                    }
                }
            } onCancel: { self.cancel() }
        }
        var bytes: [UInt8]
        switch result {
        case .success(let b): bytes = b
        case .failure(let e): throw e
        }
        defer { Self.wipe(&bytes) }
        progress("Token received, staging it securely ...")
        try stage(bytes)
    }

    /// Fallback: the user pasted a token (never logged). Same staging as `acquire(progress:)`.
    public func acquire(manualToken: String) throws {
        guard let token = ClaudeTokenParser.normalizedManualToken(manualToken) else { throw AcquireError.invalidToken }
        discardStaged()
        var bytes = Array(token.utf8)
        defer { Self.wipe(&bytes) }
        try stage(bytes)
    }

    /// The staged file still exists as a private (0600) regular file of ours with a plausible size. Never reads it.
    func hasValidStagedToken() -> Bool {
        guard let path = stagedTokenPath else { return false }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid(),
              st.st_mode & 0o077 == 0, (20...8192).contains(Int(st.st_size)) else { return false }
        return true
    }

    // MARK: staging

    private func stage(_ token: [UInt8]) throws {
        let dir = stagingDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw AcquireError.stagingFailed("directory: \(error.localizedDescription)") }
        var st = stat()
        guard lstat(dir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == geteuid() else {
            throw AcquireError.stagingFailed("staging directory is not a directory owned by you")
        }
        if st.st_mode & 0o077 != 0 { chmod(dir.path, 0o700) }
        let path = dir.appendingPathComponent("claude-oauth-token." + UUID().uuidString.lowercased()).path
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AcquireError.stagingFailed("create: \(String(cString: strerror(errno)))") }
        var ok = true
        var data = token + [0x0A]
        defer { Self.wipe(&data) }
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; ok = false; break }
                off += n
            }
        }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        guard ok else { unlink(path); throw AcquireError.stagingFailed("write failed") }
        lock.lock(); _stagedPath = path; lock.unlock()
    }

    static func wipe(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { if let b = $0.baseAddress, $0.count > 0 { _ = memset_s(b, $0.count, 0, $0.count) } }
        bytes.removeAll(keepingCapacity: false)
    }

    // MARK: PTY

    private func resetCancel() { lock.lock(); cancelFlag = false; lock.unlock() }
    private func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelFlag }

    /// Minimal environment: no API keys, no inherited variables.
    static func childEnvironment(home: String) -> [String] {
        let user = NSUserName()
        return ["HOME=\(home)", "USER=\(user)", "LOGNAME=\(user)", "TERM=dumb", "LANG=en_US.UTF-8", "NO_COLOR=1",
                "PATH=\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    /// Returns the token bytes, or an error. Blocking; runs on a background queue.
    private func runPTY(executable: URL, progress: @Sendable (String) -> Void) -> Result<[UInt8], Error> {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { return .failure(AcquireError.ptyFailed(String(cString: strerror(errno)))) }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        guard grantpt(master) == 0, unlockpt(master) == 0, let namePtr = ptsname(master) else {
            let m = String(cString: strerror(errno)); close(master); return .failure(AcquireError.ptyFailed(m))
        }
        let slavePath = String(cString: namePtr)
        // The window size is set through a slave fd that stays open until the child has opened the terminal itself:
        // on macOS the size is lost when the last slave fd closes, and setting it on the master alone did not stick.
        var ws = winsize(ws_row: 50, ws_col: Self.columns, ws_xpixel: 0, ws_ypixel: 0)
        let keepSlave = open(slavePath, O_RDWR | O_NOCTTY | O_CLOEXEC)
        if keepSlave >= 0 { _ = ioctl(keepSlave, TIOCSWINSZ, &ws) } else { _ = ioctl(master, TIOCSWINSZ, &ws) }
        defer { if keepSlave >= 0 { close(keepSlave) } }

        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa); defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fa, 0, 1)
        posix_spawn_file_actions_adddup2(&fa, 0, 2)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
        // New session (own process group, PTY slave becomes the controlling terminal); close every other inherited fd.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var none = sigset_t(); sigemptyset(&none); posix_spawnattr_setsigmask(&attr, &none)
        var all = sigset_t(); sigfillset(&all); posix_spawnattr_setsigdefault(&attr, &all)

        let argv = [executable.path, "setup-token"]
        let envp = Self.childEnvironment(home: home)
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &fa, &attr, cArgs, cEnv)
        guard rc == 0 else { close(master); return .failure(AcquireError.spawnFailed(String(cString: strerror(rc)))) }
        lock.lock(); childPid = pid; lock.unlock()
        progress("Waiting for the browser login (approve it in the browser) ...")

        var exited = false
        var exitStatus: Int32 = 0
        func reap(block: Bool) {
            guard !exited else { return }
            var st: Int32 = 0
            let r = waitpid(pid, &st, block ? 0 : WNOHANG)
            if r == pid { exited = true; exitStatus = st }
        }
        /// Discards pending child output. A child with unread output cannot finish exiting (the tty close waits for the
        /// master to drain), so this must run while waiting for it.
        var sink = [UInt8](repeating: 0, count: 4096)
        func drain() {
            var p = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            while poll(&p, 1, 0) > 0, p.revents & Int16(POLLIN) != 0 {
                if sink.withUnsafeMutableBytes({ read(master, $0.baseAddress, $0.count) }) <= 0 { break }
            }
        }
        func finish() {
            if !exited {
                killpg(pid, SIGTERM)
                var end = Date().addingTimeInterval(1.0)
                while Date() < end { drain(); reap(block: false); if exited { break }; usleep(20_000) }
                if !exited {
                    killpg(pid, SIGKILL)
                    end = Date().addingTimeInterval(3.0)
                    while Date() < end { drain(); reap(block: false); if exited { break }; usleep(20_000) }
                }
            }
            close(master)
            if !exited { reap(block: false) }   // never block forever on an unkillable child
            lock.lock(); childPid = 0; lock.unlock()
        }

        var buffer: [UInt8] = []
        defer { Self.wipe(&buffer) }
        let deadline = Date().addingTimeInterval(timeout)
        var candidateSince: Date?
        var chunk = [UInt8](repeating: 0, count: 4096)
        defer { Self.wipe(&chunk) }

        while true {
            if isCancelled() { finish(); return .failure(AcquireError.cancelled) }
            if Date() >= deadline { finish(); return .failure(AcquireError.timedOut) }
            var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 200)
            var gotData = false
            if pr > 0, pfd.revents & Int16(POLLIN) != 0 {
                let n = chunk.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
                if n > 0 {
                    buffer.append(contentsOf: chunk[0..<n]); gotData = true
                    if buffer.count > Self.bufferCap { buffer.removeFirst(buffer.count - Self.bufferCap) }
                }
            }
            if gotData {
                candidateSince = nil
                if let tok = ClaudeTokenParser.extract(from: buffer, wrapWidth: Int(Self.columns)) {
                    var t = Array(tok.utf8)
                    finish()
                    defer { Self.wipe(&t) }
                    return .success(t)
                }
            }
            if !gotData {
                reap(block: false)
                if pr > 0 && pfd.revents & Int16(POLLHUP) != 0 { reap(block: false) }
                // Idle: a candidate that could not be confirmed complete is accepted after a short silence or at child exit.
                if let tok = ClaudeTokenParser.extract(from: buffer, isFinal: exited || idleLong(&candidateSince, buffer)) {
                    var t = Array(tok.utf8)
                    finish()
                    defer { Self.wipe(&t) }
                    return .success(t)
                }
                if exited {
                    // wait status -> exit code (or the signal number for a killed child)
                    let status: Int32 = (exitStatus & 0x7f) == 0 ? (exitStatus >> 8) & 0xff : exitStatus & 0x7f
                    finish()
                    return .failure(AcquireError.exitedWithoutToken(status))
                }
            }
        }
    }

    /// True once output has been silent for `idleGrace` while the buffer contains something that looks like a token start.
    private func idleLong(_ since: inout Date?, _ buffer: [UInt8]) -> Bool {
        let marker = Array(ClaudeTokenParser.prefix.utf8)
        guard buffer.count >= marker.count, buffer.indices.dropLast(marker.count - 1).contains(where: { Array(buffer[$0..<($0 + marker.count)]) == marker }) else { return false }
        if since == nil { since = Date(); return false }
        return Date().timeIntervalSince(since!) >= Self.idleGrace
    }
}
