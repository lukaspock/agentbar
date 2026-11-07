import Foundation

// MARK: - Adapters (all injected; no probe touches the real system on its own)

public struct SetupFileInfo: Equatable, Sendable {
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var isExecutable: Bool
    public var mode: UInt16          // permission bits (0o7777)
    public var owner: String?
    public var group: String?
    public var size: Int64
    public init(isDirectory: Bool = false, isSymlink: Bool = false, isExecutable: Bool = false, mode: UInt16,
                owner: String?, group: String? = nil, size: Int64 = 0) {
        self.isDirectory = isDirectory; self.isSymlink = isSymlink; self.isExecutable = isExecutable
        self.mode = mode; self.owner = owner; self.group = group; self.size = size
    }
}

/// FileManager adapter: metadata only, never file content. nil = does not exist (symlinks are not followed).
public protocol SetupFileSystem: Sendable {
    func info(at path: String) -> SetupFileInfo?
}

public struct POSIXSetupFileSystem: SetupFileSystem {
    public init() {}
    public func info(at path: String) -> SetupFileInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let fmt = st.st_mode & S_IFMT
        var owner: String?, group: String?
        if let pw = getpwuid(st.st_uid) { owner = String(cString: pw.pointee.pw_name) }
        if let gr = getgrgid(st.st_gid) { group = String(cString: gr.pointee.gr_name) }
        return SetupFileInfo(isDirectory: fmt == S_IFDIR, isSymlink: fmt == S_IFLNK,
                             isExecutable: access(path, X_OK) == 0, mode: UInt16(st.st_mode & 0o7777),
                             owner: owner, group: group, size: Int64(st.st_size))
    }
}

public struct SetupProcessResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}

/// Runs short read-only commands (dscl, launchctl print, claude --version). Never throws: launch failure = status 127.
public protocol SetupProcessRunner: Sendable {
    func run(_ executable: String, arguments: [String]) async -> SetupProcessResult
}

public struct FoundationSetupProcessRunner: SetupProcessRunner {
    public init() {}
    public func run(_ executable: String, arguments: [String]) async -> SetupProcessResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: SetupProcessResult(status: 127, stderr: "\(error)")); return }
                let o = out.fileHandleForReading.readDataToEndOfFile()
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: SetupProcessResult(status: p.terminationStatus,
                                                          stdout: String(decoding: o, as: UTF8.self),
                                                          stderr: String(decoding: e, as: UTF8.self)))
            }
        }
    }
}

/// Metadata of the Claude token file. In production this comes from the host (`tokenstatus`: present/mode/size,
/// never the content), because the agent home is unreadable for the owner. The content is never exposed here.
public struct SetupTokenFileInfo: Equatable, Sendable {
    public var mode: UInt16
    public var size: Int64
    public init(mode: UInt16, size: Int64) { self.mode = mode; self.size = size }
}

public protocol SetupTokenInspector: Sendable {
    /// nil = no token file. Throws when the state cannot be determined (host not reachable).
    func tokenInfo() async throws -> SetupTokenFileInfo?
}

/// Inspects a local token file via `lstat` only (tests, local mode). Never opens the file.
public struct FileSetupTokenInspector: SetupTokenInspector {
    public let path: String
    public let fileSystem: SetupFileSystem
    public init(path: String, fileSystem: SetupFileSystem = POSIXSetupFileSystem()) { self.path = path; self.fileSystem = fileSystem }
    public func tokenInfo() async throws -> SetupTokenFileInfo? {
        guard let i = fileSystem.info(at: path) else { return nil }
        if i.isSymlink || i.isDirectory { return SetupTokenFileInfo(mode: 0o777, size: i.size) }   // reported as unsafe
        return SetupTokenFileInfo(mode: i.mode, size: i.size)
    }
}

public enum SetupLoginItemState: Equatable, Sendable { case enabled, notRegistered, requiresApproval, notFound }
public protocol SetupLoginItemControlling: Sendable { func state() async -> SetupLoginItemState }

public enum SetupNotificationState: Equatable, Sendable { case authorized, denied, notDetermined }
public protocol SetupNotificationAuthorizing: Sendable { func authorizationState() async -> SetupNotificationState }

// MARK: - Paths

public struct SetupPaths: Equatable, Sendable {
    public var agentUser = "agentbar"
    public var ipcGroup = "agentbar-ipc"
    public var agentHome = "/Users/agentbar"
    public var ipcDirectory = "/Users/Shared/AgentBar"
    public var daemonPlist = "/Library/LaunchDaemons/com.agentbar.host.plist"
    public var daemonLabel = "com.agentbar.host"
    public var hostBinary = "/usr/local/libexec/agentbar/agentbar-host"
    public var cliBinary = "/usr/local/bin/agentbar"
    public var claudeCandidates: [String]
    public var codexDetectionPaths: [String]
    public init(home: String = NSHomeDirectory()) {
        claudeCandidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        codexDetectionPaths = ["\(home)/.codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
    }
}

// MARK: - Probes

/// Role account `agentbar`: dscl record (UID >= 100, not admin; shell /usr/bin/false, or an adopted account without login), home owner, daemon plist, daemon state
/// (running, no "last exit code = 78"), IPC directory (group agentbar-ipc, 0750). Absent pieces = `missing`,
/// wrong pieces = `failed(reason)`.
public struct AgentUserProbe: SetupProbe {
    public let step = SetupStep.agentUser
    let paths: SetupPaths; let fs: SetupFileSystem; let runner: SetupProcessRunner
    public init(paths: SetupPaths = SetupPaths(), fileSystem: SetupFileSystem, runner: SetupProcessRunner) {
        self.paths = paths; self.fs = fileSystem; self.runner = runner
    }

    static func field(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix(key + ":") {
                let v = l.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    static func hasKey(_ key: String, in text: String) -> Bool {
        text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") }
    }

    public func check() async -> StepStatus {
        let dscl = await runner.run("/usr/bin/dscl", arguments: [".", "-read", "/Users/\(paths.agentUser)", "UniqueID", "UserShell", "NFSHomeDirectory", "Password", "AuthenticationAuthority"])
        guard dscl.status == 0 else { return .missing }
        guard let uidStr = Self.field("UniqueID", in: dscl.stdout), let uid = Int(uidStr) else {
            return .failed("user record has no UniqueID (partial setup)")
        }
        guard uid >= 100 else { return .failed("UniqueID \(uid) belongs to a system account") }
        guard Self.field("NFSHomeDirectory", in: dscl.stdout) != nil else { return .failed("user record has no home directory") }
        // A new role account has shell /usr/bin/false. An adopted account (e.g. uid 502 from sysadminctl) keeps its
        // UID; it counts as set up when it cannot log in (no AuthenticationAuthority, password '*' or empty).
        // Otherwise the setup script hardens it, so this is `missing`, not `failed`.
        let shellIsFalse = Self.field("UserShell", in: dscl.stdout) == "/usr/bin/false"
        if !shellIsFalse {
            let password = Self.field("Password", in: dscl.stdout)
            let noLogin = !Self.hasKey("AuthenticationAuthority", in: dscl.stdout) && (password == nil || password == "*")
            guard noLogin else { return .missing }
        }
        let admin = await runner.run("/usr/sbin/dseditgroup", arguments: ["-o", "checkmember", "-m", paths.agentUser, "admin"])
        guard admin.status != 0 else { return .failed("\(paths.agentUser) is an admin; remove it from the admin group") }

        guard let home = fs.info(at: paths.agentHome), home.isDirectory else { return .failed("home directory \(paths.agentHome) is missing") }
        guard home.owner == paths.agentUser else { return .failed("home is owned by \(home.owner ?? "?"), expected \(paths.agentUser)") }

        guard let plist = fs.info(at: paths.daemonPlist) else { return .missing }
        guard plist.owner == "root", plist.mode & 0o022 == 0 else { return .failed("daemon plist must be root-owned and not group/world-writable") }

        let ipc = fs.info(at: paths.ipcDirectory)
        guard let ipc, ipc.isDirectory else { return .missing }
        guard ipc.group == paths.ipcGroup else { return .failed("\(paths.ipcDirectory) group is \(ipc.group ?? "?"), expected \(paths.ipcGroup)") }
        guard ipc.mode == 0o750 else { return .failed("\(paths.ipcDirectory) mode is \(String(ipc.mode, radix: 8)), expected 750") }

        let lc = await runner.run("/bin/launchctl", arguments: ["print", "system/\(paths.daemonLabel)"])
        guard lc.status == 0 else { return .missing }
        if lc.stdout.contains("last exit code = 78") { return .failed("daemon exited with 78 (EX_CONFIG): check agent home ownership and log path") }
        guard lc.stdout.contains("state = running") else { return .failed("daemon is loaded but not running") }
        return .done
    }
}

/// Root-owned, present, executable and not group/world-writable (used for host binary and CLI).
public struct RootBinaryProbe: SetupProbe {
    public let step: SetupStep
    let path: String; let fs: SetupFileSystem
    public init(step: SetupStep, path: String, fileSystem: SetupFileSystem) { self.step = step; self.path = path; self.fs = fileSystem }
    public func check() async -> StepStatus {
        guard let i = fs.info(at: path) else { return .missing }
        guard !i.isDirectory, !i.isSymlink else { return .failed("\(path) is not a regular file") }
        guard i.owner == "root" else { return .failed("\(path) is owned by \(i.owner ?? "?"), expected root") }
        guard i.mode & 0o022 == 0 else { return .failed("\(path) is group/world-writable") }
        guard i.isExecutable else { return .failed("\(path) is not executable") }
        return .done
    }
}

public struct ClaudeCLIProbe: SetupProbe {
    public let step = SetupStep.claudeCLI
    let candidates: [String]; let fs: SetupFileSystem; let runner: SetupProcessRunner
    public init(candidates: [String], fileSystem: SetupFileSystem, runner: SetupProcessRunner) {
        self.candidates = candidates; self.fs = fileSystem; self.runner = runner
    }
    public func check() async -> StepStatus {
        guard let path = candidates.first(where: { (fs.info(at: $0)?.isExecutable ?? false) && fs.info(at: $0)?.isDirectory == false }) else { return .missing }
        let r = await runner.run(path, arguments: ["--version"])
        return r.status == 0 ? .done : .failed("\(path) --version exited with \(r.status)")
    }
}

/// Token present with mode 0600 and a plausible length. The content is never read.
public struct ClaudeTokenProbe: SetupProbe {
    public let step = SetupStep.claudeToken
    let inspector: SetupTokenInspector
    public static let plausibleSize: ClosedRange<Int64> = 20...8192
    public init(inspector: SetupTokenInspector) { self.inspector = inspector }
    public func check() async -> StepStatus {
        let info: SetupTokenFileInfo?
        do { info = try await inspector.tokenInfo() } catch { return .failed("token state unknown: \(error)") }
        guard let info else { return .missing }
        guard info.mode & 0o077 == 0 else { return .failed("token file permissions must be 0600") }
        guard Self.plausibleSize.contains(info.size) else { return .failed("token file has an implausible length") }
        return .done
    }
}

public struct ClaudeHooksProbe: SetupProbe {
    public let step = SetupStep.claudeHooks
    let setup: HookSetup
    public init(setup: HookSetup) { self.setup = setup }
    public func check() async -> StepStatus {
        do { return try setup.planInstall().isNoOp ? .done : .missing } catch { return .failed("\(error)") }
    }
}

public struct CodexHooksProbe: SetupProbe {
    public let step = SetupStep.codexHooks
    let setup: CodexHookSetup; let detectionPaths: [String]; let fs: SetupFileSystem
    public init(setup: CodexHookSetup, detectionPaths: [String], fileSystem: SetupFileSystem) {
        self.setup = setup; self.detectionPaths = detectionPaths; self.fs = fileSystem
    }
    public func check() async -> StepStatus {
        guard detectionPaths.contains(where: { fs.info(at: $0) != nil }) else { return .notApplicable("Codex is not installed") }
        do { return try setup.planInstall().isNoOp ? .done : .missing } catch { return .failed("\(error)") }
    }
}

public struct AutostartProbe: SetupProbe {
    public let step = SetupStep.autostart
    let control: SetupLoginItemControlling
    public init(control: SetupLoginItemControlling) { self.control = control }
    public func check() async -> StepStatus {
        switch await control.state() {
        case .enabled: return .done
        case .notRegistered: return .missing
        case .requiresApproval: return .failed("approve the login item in System Settings")
        case .notFound: return .failed("login item not found in the app bundle")
        }
    }
}

public struct NotificationsProbe: SetupProbe {
    public let step = SetupStep.notifications
    let auth: SetupNotificationAuthorizing
    public init(auth: SetupNotificationAuthorizing) { self.auth = auth }
    public func check() async -> StepStatus {
        switch await auth.authorizationState() {
        case .authorized: return .done
        case .notDetermined: return .missing
        case .denied: return .failed("notifications are denied in System Settings")
        }
    }
}

// MARK: - Unprivileged hook actions

public struct ClaudeHooksAction: SetupAction {
    public let step = SetupStep.claudeHooks
    let setup: HookSetup
    public init(setup: HookSetup) { self.setup = setup }
    public func run(progress: @Sendable (String) -> Void) async throws {
        let plan = try setup.planInstall()
        progress("Installing Claude Code hooks")
        try setup.apply(plan, confirm: { _ in true })   // the UI confirmed by starting the step
    }
}

public struct CodexHooksAction: SetupAction {
    public let step = SetupStep.codexHooks
    let setup: CodexHookSetup
    public init(setup: CodexHookSetup) { self.setup = setup }
    public func run(progress: @Sendable (String) -> Void) async throws {
        let plan = try setup.planInstall()
        progress("Installing Codex hooks")
        try setup.apply(plan, confirm: { _ in true })
    }
}

/// Generic action for app-provided steps (claude CLI install, autostart registration, notification request).
public struct ClosureSetupAction: SetupAction {
    public let step: SetupStep
    let body: @Sendable (@Sendable (String) -> Void) async throws -> Void
    public init(step: SetupStep, body: @escaping @Sendable (@Sendable (String) -> Void) async throws -> Void) {
        self.step = step; self.body = body
    }
    public func run(progress: @Sendable (String) -> Void) async throws { try await body(progress) }
}
