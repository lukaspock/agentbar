import Foundation

/// Wire protocol of the host channel (`op: "host"`), see CONTRACTS.md "Phase 5".
///
/// The host (`agentbar-host`, running as the agent user) is a dumb pipe: it spawns `claude`, forwards stdin, and reports
/// stdout/stderr/exit. All ids (process ids, request ids) are chosen by the APP; the host can neither create a session
/// nor inject events for ids the app did not hand out. Frames are single-line JSON objects (`\n`), at most 1 MiB.
public enum HostProtocol {
    public static let version = 1
    /// Line limit of this channel only (the other ops keep `AgentBarLimits.maxLineBytes`).
    public static let maxLineBytes = 1024 * 1024
    /// App -> host keep-alive interval, and silence after which either side declares the link dead (dead-man).
    public static let pingInterval: TimeInterval = 5
    public static let deadManSeconds: TimeInterval = 20
    public static let maxProcesses = 16
    public static let maxWorkspaces = 500
    public static let supportedAgents: Set<String> = ["claude"]

    /// Process / request ids: `[A-Za-z0-9._-]{1,64}`.
    public static func isValidId(_ s: String) -> Bool { matches(s, max: 64, allowDot: true, firstAlnum: false) }

    /// Workspace names are ONE path component: `[A-Za-z0-9][A-Za-z0-9._-]{0,59}` (no slash, never starts with a dot).
    public static func isValidWorkspaceName(_ s: String) -> Bool { matches(s, max: 60, allowDot: true, firstAlnum: true) }

    private static func matches(_ s: String, max: Int, allowDot: Bool, firstAlnum: Bool) -> Bool {
        guard !s.isEmpty, s.utf8.count <= max else { return false }
        for (i, u) in s.unicodeScalars.enumerated() {
            guard u.isASCII else { return false }
            let c = UInt8(u.value)
            let alnum = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            if i == 0 && firstAlnum { guard alnum else { return false }; continue }
            guard alnum || c == 0x2E || c == 0x5F || c == 0x2D else { return false }
        }
        return true
    }

    // MARK: framing

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// One frame without the trailing newline.
    public static func encode(_ command: HostCommand) throws -> Data { try encoder().encode(command) }
    public static func encode(_ event: HostEvent) throws -> Data { try encoder().encode(event) }
    public static func decodeCommand(_ line: Data) throws -> HostCommand { try JSONDecoder().decode(HostCommand.self, from: line) }
    public static func decodeEvent(_ line: Data) throws -> HostEvent { try JSONDecoder().decode(HostEvent.self, from: line) }
}

// MARK: handshake

/// First line the host sends on the group socket (the generic transport envelope: `token` + `op`).
public struct HostHello: Codable, Sendable, Equatable {
    public var token: String
    public var op: String
    public var protocolVersion: Int
    public var user: String
    public var uid: Int
    public var workspaceRoot: String
    /// agent name -> executable path of the agents that were found (absent = not installed).
    public var agents: [String: String]

    enum CodingKeys: String, CodingKey { case token, op, user, uid, workspaceRoot, agents; case protocolVersion = "protocol" }

    public init(token: String, user: String, uid: Int, workspaceRoot: String, agents: [String: String],
                protocolVersion: Int = HostProtocol.version) {
        self.token = token; self.op = "host"; self.protocolVersion = protocolVersion
        self.user = user; self.uid = uid; self.workspaceRoot = workspaceRoot; self.agents = agents
    }
}

/// Server reply to a successful hello. The host must not send frames before it has read this line.
public struct HostReady: Codable, Sendable, Equatable {
    public var ok: Bool
    public var event: String
    public var protocolVersion: Int
    public var maxLine: Int
    enum CodingKeys: String, CodingKey { case ok, event, maxLine; case protocolVersion = "protocol" }
    public init(protocolVersion: Int = HostProtocol.version, maxLine: Int = HostProtocol.maxLineBytes) {
        ok = true; event = "ready"; self.protocolVersion = protocolVersion; self.maxLine = maxLine
    }
}

// MARK: frames

/// Structured spawn request. Deliberately NO executable, NO environment, NO absolute path: the host owns all of those.
public struct HostSpawnRequest: Codable, Sendable, Equatable {
    public var id: String
    public var agent: String
    /// Name of a workspace below the agent user's work root (one path component).
    public var workspace: String
    public var model: String?
    public var maxBudgetUSD: Double?
    public var tools: [String]?
    /// `manual|acceptEdits|plan|dontAsk` (no bypass modes exist on this wire).
    public var permissionMode: String?

    public init(id: String, agent: String = "claude", workspace: String, model: String? = nil, maxBudgetUSD: Double? = nil,
                tools: [String]? = nil, permissionMode: String? = nil) {
        self.id = id; self.agent = agent; self.workspace = workspace; self.model = model
        self.maxBudgetUSD = maxBudgetUSD; self.tools = tools; self.permissionMode = permissionMode
    }
}

public struct HostWorkspace: Codable, Sendable, Equatable {
    public var name: String
    /// Modification time, seconds since 1970.
    public var mtime: Int
    public init(name: String, mtime: Int) { self.name = name; self.mtime = mtime }
}

/// Metadata about the Claude OAuth token file in the agent's home. Never contains the content.
public struct HostTokenStatus: Codable, Sendable, Equatable {
    public var present: Bool
    /// Permission bits (`st_mode & 0o7777`); nil when absent.
    public var mode: Int?
    /// File is owned by the host's uid, a regular file and not a symlink.
    public var ownerOK: Bool
    public var size: Int?
    /// Size within the plausible range for a token file (`HostTokenStatus.plausibleSize`).
    public var plausibleLength: Bool
    /// Modification time, seconds since 1970.
    public var mtime: Int?

    public static let plausibleSize = 40...4096

    /// Age verdict of the token file (see `TokenExpiry`); nil when there is no token or no mtime.
    public func expiry(now: Date = Date()) -> TokenExpiry? { present ? TokenExpiry.status(mtime: mtime, now: now) : nil }

    public init(present: Bool, mode: Int? = nil, ownerOK: Bool = false, size: Int? = nil, plausibleLength: Bool = false, mtime: Int? = nil) {
        self.present = present; self.mode = mode; self.ownerOK = ownerOK; self.size = size
        self.plausibleLength = plausibleLength; self.mtime = mtime
    }

    /// Present, regular, owned, mode 0600 (no group/world bits) and plausible length.
    public var isHealthy: Bool { present && ownerOK && plausibleLength && (mode ?? 0o777) & 0o177 == 0 }

    /// `lstat` only: the file is never opened or read. Symlinks and non-regular files report `ownerOK == false`.
    public static func inspect(file: URL, uid: uid_t) -> HostTokenStatus {
        var st = stat()
        guard lstat(file.path, &st) == 0 else { return HostTokenStatus(present: false) }
        let regular = (st.st_mode & S_IFMT) == S_IFREG
        let size = Int(st.st_size)
        return HostTokenStatus(present: true, mode: Int(st.st_mode & 0o7777), ownerOK: regular && st.st_uid == uid, size: size,
                               plausibleLength: regular && plausibleSize.contains(size), mtime: Int(st.st_mtimespec.tv_sec))
    }
}

/// App -> host.
public enum HostCommand: Sendable, Equatable {
    case spawn(HostSpawnRequest)
    /// One line for the child's stdin (without newline; the host appends it).
    case stdin(id: String, line: String)
    /// SIGTERM to the child's process group and close stdin.
    case terminate(id: String)
    /// SIGKILL to the child's process group.
    case kill(id: String)
    case workspaces(rid: String)
    case mkworkspace(rid: String, name: String)
    /// Metadata of the OAuth token file (present / mode / owner / size). Never the content.
    case tokenstatus(rid: String)
    case ping
}

/// Host -> app.
public enum HostEvent: Sendable, Equatable {
    case spawned(id: String, pid: Int)
    case spawnFailed(id: String, error: String)
    case stdout(id: String, line: String)
    case stderr(id: String, data: Data)
    /// Exactly once per spawned process, after stdout ended. 128+n = died by signal n.
    case exit(id: String, status: Int)
    case workspaces(rid: String, items: [HostWorkspace])
    case workspaceCreated(rid: String, name: String)
    case tokenstatus(rid: String, status: HostTokenStatus)
    case pong
    /// Request-level error. `id`/`rid` identify what it answers (either may be nil for protocol errors).
    case error(id: String?, rid: String?, message: String)
}

extension HostCommand: Codable {
    private enum K: String, CodingKey { case op, id, agent, workspace, model, maxBudgetUSD, tools, permissionMode, line, rid, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .op) {
        case "spawn":
            self = .spawn(HostSpawnRequest(id: try c.decode(String.self, forKey: .id), agent: try c.decode(String.self, forKey: .agent),
                                           workspace: try c.decode(String.self, forKey: .workspace),
                                           model: try c.decodeIfPresent(String.self, forKey: .model),
                                           maxBudgetUSD: try c.decodeIfPresent(Double.self, forKey: .maxBudgetUSD),
                                           tools: try c.decodeIfPresent([String].self, forKey: .tools),
                                           permissionMode: try c.decodeIfPresent(String.self, forKey: .permissionMode)))
        case "stdin": self = .stdin(id: try c.decode(String.self, forKey: .id), line: try c.decode(String.self, forKey: .line))
        case "terminate": self = .terminate(id: try c.decode(String.self, forKey: .id))
        case "kill": self = .kill(id: try c.decode(String.self, forKey: .id))
        case "workspaces": self = .workspaces(rid: try c.decode(String.self, forKey: .rid))
        case "mkworkspace": self = .mkworkspace(rid: try c.decode(String.self, forKey: .rid), name: try c.decode(String.self, forKey: .name))
        case "tokenstatus": self = .tokenstatus(rid: try c.decode(String.self, forKey: .rid))
        case "ping": self = .ping
        case let other: throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .spawn(let r):
            try c.encode("spawn", forKey: .op); try c.encode(r.id, forKey: .id); try c.encode(r.agent, forKey: .agent)
            try c.encode(r.workspace, forKey: .workspace)
            try c.encodeIfPresent(r.model, forKey: .model); try c.encodeIfPresent(r.maxBudgetUSD, forKey: .maxBudgetUSD)
            try c.encodeIfPresent(r.tools, forKey: .tools); try c.encodeIfPresent(r.permissionMode, forKey: .permissionMode)
        case .stdin(let id, let line): try c.encode("stdin", forKey: .op); try c.encode(id, forKey: .id); try c.encode(line, forKey: .line)
        case .terminate(let id): try c.encode("terminate", forKey: .op); try c.encode(id, forKey: .id)
        case .kill(let id): try c.encode("kill", forKey: .op); try c.encode(id, forKey: .id)
        case .workspaces(let rid): try c.encode("workspaces", forKey: .op); try c.encode(rid, forKey: .rid)
        case .mkworkspace(let rid, let name):
            try c.encode("mkworkspace", forKey: .op); try c.encode(rid, forKey: .rid); try c.encode(name, forKey: .name)
        case .tokenstatus(let rid): try c.encode("tokenstatus", forKey: .op); try c.encode(rid, forKey: .rid)
        case .ping: try c.encode("ping", forKey: .op)
        }
    }
}

extension HostEvent: Codable {
    private enum K: String, CodingKey { case ev, id, pid, error, line, b64, status, rid, items, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .ev) {
        case "spawned": self = .spawned(id: try c.decode(String.self, forKey: .id), pid: try c.decode(Int.self, forKey: .pid))
        case "spawnFailed": self = .spawnFailed(id: try c.decode(String.self, forKey: .id), error: try c.decode(String.self, forKey: .error))
        case "stdout": self = .stdout(id: try c.decode(String.self, forKey: .id), line: try c.decode(String.self, forKey: .line))
        case "stderr":
            guard let d = Data(base64Encoded: try c.decode(String.self, forKey: .b64)) else {
                throw DecodingError.dataCorruptedError(forKey: .b64, in: c, debugDescription: "bad base64")
            }
            self = .stderr(id: try c.decode(String.self, forKey: .id), data: d)
        case "exit": self = .exit(id: try c.decode(String.self, forKey: .id), status: try c.decode(Int.self, forKey: .status))
        case "workspaces": self = .workspaces(rid: try c.decode(String.self, forKey: .rid), items: try c.decode([HostWorkspace].self, forKey: .items))
        case "workspaceCreated": self = .workspaceCreated(rid: try c.decode(String.self, forKey: .rid), name: try c.decode(String.self, forKey: .name))
        case "tokenstatus":
            self = .tokenstatus(rid: try c.decode(String.self, forKey: .rid), status: try c.decode(HostTokenStatus.self, forKey: .status))
        case "pong": self = .pong
        case "error":
            self = .error(id: try c.decodeIfPresent(String.self, forKey: .id), rid: try c.decodeIfPresent(String.self, forKey: .rid),
                          message: try c.decode(String.self, forKey: .error))
        case let other: throw DecodingError.dataCorruptedError(forKey: .ev, in: c, debugDescription: "unknown event \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .spawned(let id, let pid): try c.encode("spawned", forKey: .ev); try c.encode(id, forKey: .id); try c.encode(pid, forKey: .pid)
        case .spawnFailed(let id, let e): try c.encode("spawnFailed", forKey: .ev); try c.encode(id, forKey: .id); try c.encode(e, forKey: .error)
        case .stdout(let id, let l): try c.encode("stdout", forKey: .ev); try c.encode(id, forKey: .id); try c.encode(l, forKey: .line)
        case .stderr(let id, let d): try c.encode("stderr", forKey: .ev); try c.encode(id, forKey: .id); try c.encode(d.base64EncodedString(), forKey: .b64)
        case .exit(let id, let s): try c.encode("exit", forKey: .ev); try c.encode(id, forKey: .id); try c.encode(s, forKey: .status)
        case .workspaces(let rid, let items): try c.encode("workspaces", forKey: .ev); try c.encode(rid, forKey: .rid); try c.encode(items, forKey: .items)
        case .workspaceCreated(let rid, let n): try c.encode("workspaceCreated", forKey: .ev); try c.encode(rid, forKey: .rid); try c.encode(n, forKey: .name)
        case .tokenstatus(let rid, let st): try c.encode("tokenstatus", forKey: .ev); try c.encode(rid, forKey: .rid); try c.encode(st, forKey: .status)
        case .pong: try c.encode("pong", forKey: .ev)
        case .error(let id, let rid, let m):
            try c.encode("error", forKey: .ev); try c.encodeIfPresent(id, forKey: .id); try c.encodeIfPresent(rid, forKey: .rid); try c.encode(m, forKey: .error)
        }
    }
}

/// Errors surfaced by `HostClient` calls.
public enum HostError: Error, Equatable, Sendable {
    case notConnected
    case disconnected
    case timeout
    case host(String)
}
