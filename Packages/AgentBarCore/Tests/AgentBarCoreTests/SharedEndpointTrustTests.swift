import XCTest
@testable import agentbar

/// Pure decision logic of the CLI's shared-directory fallback (fake owners/modes; a real second macOS user is not needed).
final class SharedEndpointTrustTests: XCTestCase {
    let ipc: gid_t = 600, me: uid_t = 502, owner: uid_t = 501

    func dir(uid: uid_t? = nil, gid: gid_t? = nil, perm: mode_t = 0o750, kind: mode_t = S_IFDIR) -> SharedFacts {
        SharedFacts(kind: kind, uid: uid ?? owner, gid: gid ?? ipc, perm: perm)
    }
    func sock(uid: uid_t? = nil, gid: gid_t? = nil, perm: mode_t = 0o660, kind: mode_t = S_IFSOCK) -> SharedFacts {
        SharedFacts(kind: kind, uid: uid ?? owner, gid: gid ?? ipc, perm: perm)
    }
    func tok(uid: uid_t? = nil, perm: mode_t = 0o640, kind: mode_t = S_IFREG) -> SharedFacts {
        SharedFacts(kind: kind, uid: uid ?? owner, gid: ipc, perm: perm)
    }
    func eval(_ d: SharedFacts? = nil, _ s: SharedFacts? = nil, _ t: SharedFacts? = nil, ipcGid: gid_t? = 600, allowSelf: Bool = false) -> uid_t? {
        SharedEndpointTrust.expectedServerUid(dir: d ?? dir(), socket: s ?? sock(), token: t ?? tok(), selfUid: me, ipcGid: ipcGid, allowSelfOwned: allowSelf)
    }

    func testSetupScriptLayoutIsTrustedAndYieldsOwnerUid() {
        XCTAssertEqual(eval(), owner)
        XCTAssertEqual(eval(dir(perm: 0o2750)), owner, "setgid dir bit is fine")
        XCTAssertEqual(eval(nil, nil, tok(perm: 0o600)), owner)
    }

    func testRootOwnedDirDefersToSocketOwner() {
        XCTAssertEqual(eval(dir(uid: 0)), owner)
        XCTAssertNil(eval(dir(uid: 0), sock(uid: me)), "socket owned by the agent itself")
    }

    func testDirectoryChecks() {
        XCTAssertNil(eval(dir(gid: 20)), "wrong group")
        XCTAssertNil(eval(dir(perm: 0o770)), "group writable")
        XCTAssertNil(eval(dir(perm: 0o757)), "world writable")
        XCTAssertNil(eval(dir(kind: S_IFLNK)), "symlink")
        XCTAssertNil(eval(ipcGid: nil), "group does not exist")
    }

    func testOwnerMustNotBeTheCallingAgentUser() {
        XCTAssertNil(eval(dir(uid: me), sock(uid: me), tok(uid: me)), "directory owned by the agent user itself proves nothing")
        XCTAssertEqual(eval(dir(uid: me), sock(uid: me), tok(uid: me), allowSelf: true), me, "fake-uid test setups only")
    }

    func testSquatterWithMismatchingSocketOrTokenIsRejected() {
        XCTAssertNil(eval(nil, sock(uid: 777)), "socket from a different uid than the directory owner")
        XCTAssertNil(eval(nil, nil, tok(uid: 777)), "token planted by someone else")
        XCTAssertEqual(eval(nil, nil, tok(uid: 0)), owner, "root-owned token is acceptable")
    }

    func testSocketAndTokenModesAndKinds() {
        XCTAssertNil(eval(nil, sock(gid: 20)))
        XCTAssertNil(eval(nil, sock(perm: 0o666)), "world writable socket")
        XCTAssertNil(eval(nil, sock(kind: S_IFREG)), "not a socket")
        XCTAssertNil(eval(nil, nil, tok(perm: 0o660)), "group writable token")
        XCTAssertNil(eval(nil, nil, tok(perm: 0o644)), "world readable token")
        XCTAssertNil(eval(nil, nil, tok(kind: S_IFLNK)), "symlinked token")
    }

    func testEvaluateOnRealFilesystemRejectsUntrustedDirs() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("abtrust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o750])
        defer { try? FileManager.default.removeItem(at: d) }
        XCTAssertNil(SharedEndpointTrust.evaluate(dir: d.path, ipcGid: getegid()), "missing socket/token")
        FileManager.default.createFile(atPath: d.path + "/token.agent", contents: Data("t".utf8), attributes: [.posixPermissions: 0o640])
        XCTAssertNil(SharedEndpointTrust.evaluate(dir: d.path, ipcGid: getegid()), "still no socket")
        XCTAssertNil(SharedEndpointTrust.evaluate(dir: d.path, ipcGid: getegid()), "self-owned is refused without the test switch")
        XCTAssertNil(SharedEndpointTrust.evaluate(dir: "/nonexistent-\(UUID().uuidString)"))
    }
}
