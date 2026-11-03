import Foundation

/// Trust check for the group-shared endpoint (`/Users/Shared/AgentBar`) the CLI falls back to (hooks of the agent user).
/// Pure decision logic on stat facts, so it is unit-tested with fake owners/modes. The checks are defense in depth on top of
/// the setup script's modes (dir 0750 owner:agentbar-ipc): a squatted directory or a swapped socket/token must not be trusted,
/// because a fake server could answer a hook with "allow".
struct SharedFacts: Equatable {
    var kind: mode_t      // st_mode & S_IFMT (from lstat: a symlink is S_IFLNK and never accepted)
    var uid: uid_t
    var gid: gid_t
    var perm: mode_t      // st_mode & 0o7777
    static func lstatFacts(_ path: String) -> SharedFacts? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return SharedFacts(kind: st.st_mode & S_IFMT, uid: st.st_uid, gid: st.st_gid, perm: st.st_mode & 0o7777)
    }
}

enum SharedEndpointTrust {
    /// Returns the uid the server behind the socket must have (checked again with getpeereid after connect), or nil = do not trust.
    /// - Directory: real directory, group = IPC group, no group/world write.
    /// - Expected server uid: owner of the directory; a root-owned directory defers to the socket's owner.
    ///   It must not be our own uid (our uid here is the agent user; a directory we own proves nothing) unless `allowSelfOwned`
    ///   (fake-uid test setups only).
    /// - Socket: real socket, owned by that uid, group = IPC group, not world-accessible-writable.
    /// - Token: real file, owned by that uid or root, no group/world write, no world access.
    static func expectedServerUid(dir: SharedFacts, socket: SharedFacts, token: SharedFacts, selfUid: uid_t,
                                  ipcGid: gid_t?, allowSelfOwned: Bool = false) -> uid_t? {
        guard let ipcGid else { return nil }
        guard dir.kind == S_IFDIR, dir.gid == ipcGid, dir.perm & 0o022 == 0 else { return nil }
        let expected = dir.uid == 0 ? socket.uid : dir.uid
        if expected == selfUid && !allowSelfOwned { return nil }
        guard socket.kind == S_IFSOCK, socket.uid == expected, socket.gid == ipcGid, socket.perm & 0o002 == 0 else { return nil }
        guard token.kind == S_IFREG, token.uid == expected || token.uid == 0, token.perm & 0o022 == 0, token.perm & 0o007 == 0 else { return nil }
        return expected
    }

    static func ipcGroupId(_ name: String = "agentbar-ipc") -> gid_t? {
        guard let g = getgrnam(name) else { return nil }
        return g.pointee.gr_gid
    }

    /// Reads the facts from disk and decides. `tokenName` is always `token.agent` (the owner token never lives in the shared dir).
    static func evaluate(dir: String, selfUid: uid_t = geteuid(), ipcGid: gid_t? = ipcGroupId(), allowSelfOwned: Bool = false) -> uid_t? {
        guard let d = SharedFacts.lstatFacts(dir), let s = SharedFacts.lstatFacts(dir + "/agentbar.sock"),
              let t = SharedFacts.lstatFacts(dir + "/token.agent") else { return nil }
        return expectedServerUid(dir: d, socket: s, token: t, selfUid: selfUid, ipcGid: ipcGid, allowSelfOwned: allowSelfOwned)
    }
}
