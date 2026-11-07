import Foundation

/// Pre-flight checks for "Continue in panel" (`claude --resume <id> --fork-session` as the OWNER in a session's directory).
/// Pure functions of their inputs so they can be tested with temp directories. All checks are fail-closed.
///
/// Why: hook sessions can also come from the agent user's processes. Even though the transport no longer accepts a directory
/// from that role, the backend must never start a process of the owner in a directory it does not fully trust (a directory
/// with a hostile `.claude/settings.json` would run hooks as the owner).
public enum ContinueInPanelCheck {
    public struct Failure: Error, Equatable, Sendable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
        /// Text for the error bubble.
        public var message: String { "Cannot continue: " + reason }
    }

    /// Directories (and everything below) that belong to the agent user. Includes the agent's real home if the user exists.
    public static func defaultForbiddenPrefixes() -> [String] {
        var p = ["/Users/" + TransportSecurity.defaultAgentUserName, TransportSecurity.defaultSharedDirectory.path]
        if let pw = getpwnam(TransportSecurity.defaultAgentUserName), let dir = pw.pointee.pw_dir {
            p.append(String(cString: dir))
        }
        return p
    }

    /// Full gate used by the backend. Returns the resolved (realpath) directory to start in.
    public static func validate(session: AgentSession, ownerUid: uid_t = geteuid(),
                                forbiddenPrefixes: [String] = defaultForbiddenPrefixes(),
                                projectsRoot: URL = defaultProjectsRoot()) -> Result<URL, Failure> {
        guard session.originRole == .owner else {
            return .failure(Failure("this session was not started by your own user"))
        }
        guard session.canContinueInPanel, let cwd = session.workingDirectory else {
            return .failure(Failure("the session has no usable id or working directory"))
        }
        let dir: String
        switch resolveDirectory(cwd, ownerUid: ownerUid, forbiddenPrefixes: forbiddenPrefixes) {
        case .failure(let f): return .failure(f)
        case .success(let d): dir = d
        }
        guard transcriptExists(sessionId: session.id, directory: dir, originalDirectory: cwd, projectsRoot: projectsRoot) else {
            return .failure(Failure("no transcript for this session was found in your ~/.claude"))
        }
        return .success(URL(fileURLWithPath: dir, isDirectory: true))
    }

    public static func defaultProjectsRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// realpath, must be a directory owned by `ownerUid`, not group/world writable, and not below a forbidden prefix
    /// (checked on the given AND the resolved path, so a link into the agent home is caught as well).
    public static func resolveDirectory(_ path: String, ownerUid: uid_t = geteuid(),
                                        forbiddenPrefixes: [String] = defaultForbiddenPrefixes()) -> Result<String, Failure> {
        guard path.hasPrefix("/"), let rp = realpath(path, nil) else { return .failure(Failure("the directory does not exist")) }
        let resolved = String(cString: rp); free(rp)
        for candidate in [path, resolved] where isInside(candidate, anyOf: forbiddenPrefixes) {
            return .failure(Failure("the directory belongs to the agent user"))
        }
        var st = stat()
        guard stat(resolved, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return .failure(Failure("it is not a directory")) }
        guard st.st_uid == ownerUid else { return .failure(Failure("the directory is not owned by you")) }
        guard st.st_mode & 0o022 == 0 else { return .failure(Failure("the directory is writable by group or others")) }
        return .success(resolved)
    }

    /// Component-wise, case-insensitive prefix test (the default macOS volume is case-insensitive).
    public static func isInside(_ path: String, anyOf prefixes: [String]) -> Bool {
        let comps = path.split(separator: "/").map { $0.lowercased() }
        for pre in prefixes {
            let pc = pre.split(separator: "/").map { $0.lowercased() }
            if !pc.isEmpty, comps.count >= pc.count, Array(comps.prefix(pc.count)) == pc { return true }
        }
        return false
    }

    /// Claude's project folder name: every character that is not a letter or digit becomes `-` (so `/` and `.` do).
    public static func encodedProjectName(_ path: String) -> String {
        String(path.unicodeScalars.map { s in
            (s.isASCII && (CharacterSet.alphanumerics.contains(s))) ? Character(s) : "-"
        })
    }

    /// Read-only existence check of `<projectsRoot>/<encoded cwd>/<id>.jsonl`; falls back to `<projectsRoot>/*/<id>.jsonl`
    /// when the encoding differs. The id is already restricted to `[A-Za-z0-9-]` (no path separators).
    public static func transcriptExists(sessionId: String, directory: String, originalDirectory: String? = nil,
                                        projectsRoot: URL) -> Bool {
        guard ChatResume.isValidSessionId(sessionId) else { return false }
        let fm = FileManager.default
        let file = sessionId + ".jsonl"
        for d in [directory, originalDirectory].compactMap({ $0 }) {
            let p = projectsRoot.appendingPathComponent(encodedProjectName(d), isDirectory: true).appendingPathComponent(file).path
            if fm.fileExists(atPath: p) { return true }
        }
        guard let subs = try? fm.contentsOfDirectory(atPath: projectsRoot.path) else { return false }
        return subs.contains { fm.fileExists(atPath: projectsRoot.appendingPathComponent($0, isDirectory: true).appendingPathComponent(file).path) }
    }
}
