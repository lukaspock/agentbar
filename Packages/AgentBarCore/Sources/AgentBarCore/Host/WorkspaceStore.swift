import Foundation

public enum WorkspaceError: Error, Equatable, Sendable {
    case invalidName
    case rootInvalid(String)
    case notFound
    case notADirectory
    case symlink
    case escapesRoot
    case notOwned
    case exists
    case tooMany
    case system(String, Int32)
}

/// The agent user's workspaces: direct children of ONE root directory (`~/work`), each a real directory owned by us.
/// Names are single components (`HostProtocol.isValidWorkspaceName`), so `..`, `/`, absolute paths and hidden names cannot
/// even be expressed. On top of that every resolve re-checks with lstat/realpath that the target is a directory (not a
/// symlink), owned by this uid, and that its real path is exactly `<real root>/<name>`.
/// (A same-uid process could still swap the directory between check and use; this is containment against the
/// owner's requests and against symlink tricks inside the work root, not a sandbox against a hostile agent.)
public struct WorkspaceStore: Sendable {
    public let root: URL
    private let uid: uid_t

    public init(root: URL, uid: uid_t = geteuid()) { self.root = root; self.uid = uid }

    private func realRoot(create: Bool) throws -> String {
        var st = stat()
        if lstat(root.path, &st) != 0 {
            guard create, errno == ENOENT else { throw WorkspaceError.rootInvalid("work root missing") }
            guard mkdir(root.path, 0o700) == 0 || errno == EEXIST else { throw WorkspaceError.system("mkdir root", errno) }
            guard lstat(root.path, &st) == 0 else { throw WorkspaceError.system("lstat root", errno) }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw WorkspaceError.rootInvalid("work root is not a real directory") }
        guard st.st_uid == uid else { throw WorkspaceError.rootInvalid("work root not owned by the agent user") }
        guard let rp = realpath(root.path, nil) else { throw WorkspaceError.rootInvalid("work root not resolvable") }
        defer { free(rp) }
        return String(cString: rp)
    }

    /// Existing workspace -> its real directory URL. Never creates anything.
    public func resolve(_ name: String) throws -> URL {
        guard HostProtocol.isValidWorkspaceName(name) else { throw WorkspaceError.invalidName }
        let r = try realRoot(create: false)
        let candidate = r + "/" + name
        var st = stat()
        guard lstat(candidate, &st) == 0 else { throw WorkspaceError.notFound }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw WorkspaceError.symlink }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw WorkspaceError.notADirectory }
        guard st.st_uid == uid else { throw WorkspaceError.notOwned }
        guard let rp = realpath(candidate, nil) else { throw WorkspaceError.notFound }
        defer { free(rp) }
        guard String(cString: rp) == candidate else { throw WorkspaceError.escapesRoot }
        return URL(fileURLWithPath: candidate, isDirectory: true)
    }

    /// Creates `name` (mode 0700). Fails with `.exists` if anything with that name is there.
    @discardableResult
    public func create(_ name: String) throws -> URL {
        guard HostProtocol.isValidWorkspaceName(name) else { throw WorkspaceError.invalidName }
        let r = try realRoot(create: true)
        if try list().count >= HostProtocol.maxWorkspaces { throw WorkspaceError.tooMany }
        let path = r + "/" + name
        guard mkdir(path, 0o700) == 0 else {
            if errno == EEXIST { throw WorkspaceError.exists }
            throw WorkspaceError.system("mkdir", errno)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Real, owned directories with valid names only (symlinks, files, hidden and oddly named entries are skipped).
    public func list() throws -> [HostWorkspace] {
        let r = try realRoot(create: false)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: r) else { return [] }
        var out: [HostWorkspace] = []
        for n in names where HostProtocol.isValidWorkspaceName(n) {
            var st = stat()
            guard lstat(r + "/" + n, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == uid else { continue }
            out.append(HostWorkspace(name: n, mtime: Int(st.st_mtimespec.tv_sec)))
        }
        return Array(out.sorted { $0.name < $1.name }.prefix(HostProtocol.maxWorkspaces))
    }
}
