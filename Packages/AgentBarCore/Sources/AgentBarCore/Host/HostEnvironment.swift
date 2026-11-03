import Foundation

public enum HostEnvironmentError: Error, Equatable, Sendable {
    case tokenFileUnsafe(String)
}

/// Builds the COMPLETE environment of the agent child from scratch. Nothing is inherited from the host's own environment
/// (and certainly nothing from the owner's: the owner's variables never reach the host in the first place, and a host
/// started by hand from the owner's shell would still not pass them on).
public enum HostEnvironment {
    public static let tokenFileRelativePath = ".config/agentbar/claude-oauth-token"

    /// - Parameters:
    ///   - home/user: the agent user's home directory and login name (from the password database, not from env).
    ///   - tokenFile: file holding `claude setup-token` output. Must be a regular file (not a symlink), owned by `uid`,
    ///     with no group/world permission bits. Missing file = no token (claude then falls back to its own credentials).
    /// - Returns: variables for the child. `ANTHROPIC_API_KEY` and friends are never set, so the OAuth token can never be
    ///   combined with an API key (that makes claude warn about conflicting auth).
    public static func build(home: URL, user: String, tokenFile: URL?, uid: uid_t = geteuid()) throws -> [String: String] {
        let h = home.path
        var env: [String: String] = [
            "HOME": h, "USER": user, "LOGNAME": user,
            "SHELL": "/bin/zsh",
            "PATH": "\(h)/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "TMPDIR": h + "/.agentbar/tmp/",
        ]
        if let tokenFile, let token = try readToken(tokenFile, uid: uid) { env["CLAUDE_CODE_OAUTH_TOKEN"] = token }
        return env
    }

    static func readToken(_ url: URL, uid: uid_t) throws -> String? {
        var st = stat()
        if lstat(url.path, &st) != 0 { return nil }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw HostEnvironmentError.tokenFileUnsafe("not a regular file (symlinks are refused)") }
        guard st.st_uid == uid else { throw HostEnvironmentError.tokenFileUnsafe("not owned by the agent user") }
        guard st.st_mode & 0o077 == 0 else { throw HostEnvironmentError.tokenFileUnsafe("permissions must be 0600") }
        guard st.st_size <= 8192 else { throw HostEnvironmentError.tokenFileUnsafe("too large") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw HostEnvironmentError.tokenFileUnsafe("cannot open") }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: Int(st.st_size))
        let n = read(fd, &buf, buf.count)
        guard n >= 0, let s = String(bytes: buf[0..<n], encoding: .utf8) else { throw HostEnvironmentError.tokenFileUnsafe("unreadable") }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        guard t.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F }) else {
            throw HostEnvironmentError.tokenFileUnsafe("token contains unexpected characters")
        }
        return t
    }
}
