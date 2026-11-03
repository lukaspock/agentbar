import Foundation

/// Who is on the other end of a connection. Decided by the kernel-reported peer uid (getpeereid), never by anything the peer sends.
public enum PeerRole: String, Sendable, Hashable, CaseIterable {
    /// The user running AgentBar. Full access.
    case owner
    /// The separate macOS user (e.g. `agentbar`) that runs agents. Hook/session ops only, and only on sessions it created itself.
    case agent
}

/// Limits that apply per role, on top of the global limits in `AgentBarLimits`.
public struct RoleQuota: Sendable, Equatable {
    public var maxConnections: Int
    public var maxSessions: Int
    public var maxPendingRequests: Int
    public init(maxConnections: Int, maxSessions: Int, maxPendingRequests: Int) {
        self.maxConnections = maxConnections; self.maxSessions = maxSessions; self.maxPendingRequests = maxPendingRequests
    }
    /// Deliberately well below the global caps (512 connections, 100 sessions, 100 pending): a runaway or hostile agent
    /// user must not be able to starve the owner's own CLI or fill the bar.
    public static let agentDefault = RoleQuota(maxConnections: 128, maxSessions: 40, maxPendingRequests: 40)
}

/// Security configuration of the transport: who may connect (role table), the optional group-shared socket
/// directory for the agent user, per-role quotas, and the (injectable) peer credential check.
///
/// `TransportSecurity()` is the single-user mode of old: only our own uid, no second socket.
public struct TransportSecurity: Sendable {
    public static let defaultSharedDirectory = URL(fileURLWithPath: "/Users/Shared/AgentBar", isDirectory: true)
    public static let defaultGroupName = "agentbar-ipc"
    public static let defaultAgentUserName = "agentbar"
    public static let agentTokenFileName = "token.agent"

    /// Peer credential lookup for an accepted connection. Tests inject fake uids; production uses getpeereid.
    public typealias PeerCredentials = @Sendable (Int32) -> (uid: uid_t, gid: gid_t)?

    public var ownerUid: uid_t
    /// nil = single-user mode (no agent role). An agent uid equal to `ownerUid` is ignored (the owner role wins).
    public var agentUid: uid_t?
    /// Directory of the group socket. nil = no second listener.
    public var sharedDirectory: URL?
    /// Group name resolved at start (getgrnam) when `sharedGid` is nil. If the group does not exist the shared listener stays off.
    public var sharedGroupName: String?
    public var sharedGid: gid_t?
    /// Exactly the directory modes that are acceptable: owner rwx, group r-x, nothing else. Anything else keeps the listener off.
    public var sharedDirMode: mode_t
    public var sharedSocketMode: mode_t
    public var agentQuota: RoleQuota
    public var peerCredentials: PeerCredentials
    /// Which executable may speak `op: host`. Secure by default; tests inject `.disabled` or fake pid/path lookups.
    public var hostBinary: HostBinaryPolicy

    public init(ownerUid: uid_t = geteuid(), agentUid: uid_t? = nil,
                sharedDirectory: URL? = nil, sharedGroupName: String? = nil, sharedGid: gid_t? = nil,
                sharedDirMode: mode_t = 0o750, sharedSocketMode: mode_t = 0o660,
                agentQuota: RoleQuota = .agentDefault,
                peerCredentials: @escaping PeerCredentials = TransportSecurity.systemPeerCredentials,
                hostBinary: HostBinaryPolicy = .standard) {
        self.ownerUid = ownerUid; self.agentUid = agentUid
        self.sharedDirectory = sharedDirectory; self.sharedGroupName = sharedGroupName; self.sharedGid = sharedGid
        self.sharedDirMode = sharedDirMode; self.sharedSocketMode = sharedSocketMode
        self.agentQuota = agentQuota; self.peerCredentials = peerCredentials; self.hostBinary = hostBinary
    }

    /// Single-user mode (the default of `TransportServer`).
    public static var singleUser: TransportSecurity { TransportSecurity() }

    /// Two-user mode if, and only if, both the agent user and the IPC group exist on this Mac (they are created by the admin's
    /// setup script). Otherwise single-user mode: nothing changes for people who did not set the agent user up.
    public static func detected(agentUserName: String = defaultAgentUserName, groupName: String = defaultGroupName,
                                sharedDirectory: URL = defaultSharedDirectory) -> TransportSecurity {
        guard let pw = getpwnam(agentUserName), let gr = getgrnam(groupName), pw.pointee.pw_uid != geteuid() else { return .singleUser }
        return TransportSecurity(agentUid: pw.pointee.pw_uid, sharedDirectory: sharedDirectory,
                                 sharedGroupName: groupName, sharedGid: gr.pointee.gr_gid)
    }

    /// Role for a peer uid, or nil = not allowed at all (connection is closed). Owner wins if both uids are equal.
    public func role(forUid uid: uid_t) -> PeerRole? {
        if uid == ownerUid { return .owner }
        if let a = agentUid, a == uid { return .agent }
        return nil
    }

    public static let systemPeerCredentials: PeerCredentials = { fd in
        var u: uid_t = 0, g: gid_t = 0
        guard getpeereid(fd, &u, &g) == 0 else { return nil }
        return (u, g)
    }

    /// Ops an agent-role peer may use. Everything else (and anything unknown) is "forbidden" for it.
    static let agentOps: Set<String> = ["update", "log", "end", "remove", "ask", "payload", "watch", "host"]
}

/// Where the shared (group) listener stands.
public enum SharedSocketStatus: Sendable, Equatable {
    case disabled
    case active
    /// Configured, but not started (group missing, insecure directory, chown refused, ...). The owner socket is unaffected.
    case unavailable(String)
}

/// Side table session id -> who created it. Contract types are FROZEN, so this lives in the transport.
/// An id that exists in the store without an entry here counts as owner-side (UI, chat, demo): the agent role may not touch it.
final class SessionOrigins: @unchecked Sendable {
    struct Entry { var role: PeerRole; var at: Date }
    private var entries: [String: Entry] = [:]
    static let maxEntries = 2000
    static let staleAfter: TimeInterval = 30

    /// Authorizes `role` for `ids` and records the origin. nil = ok, otherwise the wire error.
    /// - agent: ids must be unknown to the store, or have been created by the agent role; chat-owned ids are always refused.
    /// - owner: may touch anything (and thereby takes the id over: the agent role loses it from then on).
    @MainActor func claim(role: PeerRole, ids: Set<String>, store: SessionStore, agentMaxSessions: Int,
                          rejectChatOwned: Bool, now: Date = Date()) -> String? {
        if rejectChatOwned, ids.contains(where: { store.isChatOwned($0) }) { return "session reserved" }
        let live = Set(store.sessions.map(\.id))
        prune(live: live, now: now)
        if role == .agent {
            var fresh = 0
            for id in ids {
                if let e = entries[id] { if e.role != .agent { return "session reserved" } }
                else if live.contains(id) { return "session reserved" }
                else { fresh += 1 }
            }
            let have = entries.values.reduce(0) { $0 + ($1.role == .agent ? 1 : 0) }
            if fresh > 0 && have + fresh > agentMaxSessions { return "too many sessions" }
            for id in ids where entries[id] == nil { entries[id] = Entry(role: .agent, at: now) }
        } else {
            for id in ids where entries[id] != nil || entries.count < Self.maxEntries { entries[id] = Entry(role: .owner, at: now) }
        }
        return nil
    }

    /// Pending requests currently held by agent-created sessions.
    @MainActor func agentPendingCount(store: SessionStore) -> Int {
        store.sessions.reduce(0) { $0 + (entries[$1.id]?.role == .agent ? $1.pendingRequests.count : 0) }
    }

    @MainActor func role(of id: String) -> PeerRole? { entries[id]?.role }

    private func prune(live: Set<String>, now: Date) {
        entries = entries.filter { live.contains($0.key) || now.timeIntervalSince($0.value.at) <= Self.staleAfter }
    }
}

/// Restricts `op: host` to the installed, root-owned `agentbar-host` binary. The peer's pid comes from the kernel
/// (LOCAL_PEERPID), its executable path from `proc_pidpath`. A shell/Python script or a copied binary has another path and is
/// refused, so a stray process of the agent user that merely read `token.agent` cannot register as the host.
/// Limits (documented in CONTRACTS.md): same uid as the agent, so a process that starts the REAL binary with an injected library
/// or debugs it still passes. This raises the bar; the real boundary would be a separate host user.
public struct HostBinaryPolicy: Sendable {
    public static let defaultPath = "/usr/local/libexec/agentbar/agentbar-host"
    public typealias PeerPid = @Sendable (Int32) -> pid_t?
    public typealias PathOfPid = @Sendable (pid_t) -> String?

    /// nil = no check (tests only).
    public var allowedPaths: [String]?
    /// The binary and its directory must be owned by root and not group/world writable.
    public var requireRootOwned: Bool
    public var peerPid: PeerPid
    public var pathOfPid: PathOfPid

    public init(allowedPaths: [String]?, requireRootOwned: Bool = true,
                peerPid: @escaping PeerPid = HostBinaryPolicy.systemPeerPid, pathOfPid: @escaping PathOfPid = HostBinaryPolicy.systemPathOfPid) {
        self.allowedPaths = allowedPaths; self.requireRootOwned = requireRootOwned; self.peerPid = peerPid; self.pathOfPid = pathOfPid
    }

    public static var standard: HostBinaryPolicy { HostBinaryPolicy(allowedPaths: [defaultPath]) }
    public static var disabled: HostBinaryPolicy { HostBinaryPolicy(allowedPaths: nil, requireRootOwned: false) }

    public static let systemPeerPid: PeerPid = { fd in
        var pid: pid_t = 0; var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, 0 /* SOL_LOCAL */, 0x002 /* LOCAL_PEERPID */, &pid, &len) == 0, pid > 0 else { return nil }
        return pid
    }
    public static let systemPathOfPid: PathOfPid = { pid in
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// true = the peer on `fd` is the allowed host binary.
    public func allows(fd: Int32) -> Bool {
        guard let allowed = allowedPaths else { return true }
        guard let pid = peerPid(fd), let path = pathOfPid(pid), let real = Self.realpath(path) else { return false }
        guard allowed.contains(where: { Self.realpath($0) == real }) else { return false }
        if requireRootOwned {
            guard Self.rootOwnedNotWritable(real), Self.rootOwnedNotWritable((real as NSString).deletingLastPathComponent) else { return false }
        }
        return true
    }

    static func realpath(_ p: String) -> String? {
        guard let r = Darwin.realpath(p, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    static func rootOwnedNotWritable(_ p: String) -> Bool {
        var st = stat()
        guard lstat(p, &st) == 0 else { return false }
        return st.st_uid == 0 && st.st_mode & 0o022 == 0
    }
}
