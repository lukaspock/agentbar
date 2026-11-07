import XCTest
@testable import AgentBarCore

/// Switchable fake peer identity (what getpeereid would report for the next connections).
final class FakePeer: @unchecked Sendable {
    private let lock = NSLock()
    private var uid: uid_t
    private var gid: gid_t
    init(uid: uid_t, gid: gid_t = getgid()) { self.uid = uid; self.gid = gid }
    func set(_ u: uid_t) { lock.lock(); uid = u; lock.unlock() }
    var credentials: TransportSecurity.PeerCredentials {
        { [self] _ in lock.lock(); defer { lock.unlock() }; return (uid, gid) }
    }
}

/// Two-user transport with fake uids: nothing here needs a second macOS user. The group is our own primary group
/// (chown to it is always allowed for us), the "owner uid" is fake (geteuid()+1) and the agent uid is our real one,
/// or the other way round through `FakePeer`.
@MainActor
final class MultiUserTransportTests: XCTestCase {
    let ownerUid = geteuid() + 1
    let agentUid = geteuid()
    var base: URL!
    var ownerDir: URL { base.appendingPathComponent("owner") }
    var sharedDir: URL { base.appendingPathComponent("shared") }
    var store: SessionStore!
    var server: TransportServer!
    var peer: FakePeer!

    override func setUp() async throws {
        base = URL(fileURLWithPath: "/tmp/abm-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = SessionStore()
    }
    override func tearDown() async throws { server?.stop(); try? FileManager.default.removeItem(at: base) }

    func startServer(quota: RoleQuota = .agentDefault, mode: mode_t = 0o750, groupName: String? = nil, gid: gid_t? = getgid(),
                     shared: Bool = true) throws {
        peer = FakePeer(uid: agentUid)
        let sec = TransportSecurity(ownerUid: ownerUid, agentUid: agentUid,
                                    sharedDirectory: shared ? sharedDir : nil, sharedGroupName: groupName, sharedGid: gid,
                                    sharedDirMode: mode, agentQuota: quota, peerCredentials: peer.credentials)
        server = TransportServer(store: store, adapters: ["claudeCode": FakeAdapter()], directory: ownerDir, security: sec)
        try server.start()
    }

    func call(_ json: String, path: String? = nil) async -> [String: Any] {
        let p = path ?? server.sharedSocketPath!
        let line: String? = await detached {
            guard let c = RawClient(path: p) else { return nil }
            defer { c.close_() }
            c.send(json + "\n")
            return c.readLine()
        }
        return (line.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
    }
    func agent(_ rest: String) async -> [String: Any] { peer.set(agentUid); return await call("{\"token\":\"\(server.agentTokenForTests)\",\(rest)}") }
    func owner(_ rest: String) async -> [String: Any] { peer.set(ownerUid); return await call("{\"token\":\"\(server.tokenForTests)\",\(rest)}") }
    func err(_ r: [String: Any]) -> String? { r["error"] as? String }
    func ok(_ r: [String: Any]) -> Bool { r["ok"] as? Bool == true }
    func perm(_ p: String) -> Int { var st = stat(); stat(p, &st); return Int(st.st_mode & 0o777) }

    // MARK: modes, files, lifecycle

    func testModesGroupAndTokenFiles() throws {
        try startServer()
        XCTAssertEqual(server.sharedStatus, .active)
        XCTAssertEqual(perm(ownerDir.path), 0o700)
        XCTAssertEqual(perm(server.socketPath), 0o600)
        XCTAssertEqual(perm(server.tokenPath), 0o600)
        XCTAssertEqual(perm(sharedDir.path), 0o750)
        XCTAssertEqual(perm(server.sharedSocketPath!), 0o660)
        XCTAssertEqual(perm(server.agentTokenPath!), 0o640)
        var st = stat()
        for p in [sharedDir.path, server.sharedSocketPath!, server.agentTokenPath!] {
            XCTAssertEqual(stat(p, &st), 0); XCTAssertEqual(st.st_gid, getgid(), p); XCTAssertEqual(st.st_mode & 0o007, 0, p)
        }
        // The owner directory never holds the agent token, the shared directory never the owner token.
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerDir.appendingPathComponent("token.agent").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedDir.appendingPathComponent("token").path))
        XCTAssertNotEqual(server.tokenForTests, server.agentTokenForTests)
        XCTAssertEqual(try String(contentsOfFile: server.agentTokenPath!, encoding: .utf8), server.agentTokenForTests)
        server.stop()
        for p in [server.socketPath, server.tokenPath, server.sharedSocketPath!, server.agentTokenPath!] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: p), p)
        }
    }

    func testSharedListenerOffWhenGroupMissingOwnerSocketUnaffected() async throws {
        try startServer(groupName: "agentbar-no-such-group-xyz", gid: nil)
        if case .unavailable = server.sharedStatus {} else { XCTFail("\(server.sharedStatus)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.sharedSocketPath!))
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.agentTokenPath!))
        peer.set(ownerUid)
        let r = await call("{\"token\":\"\(server.tokenForTests)\",\"op\":\"end\",\"session\":\"s\"}", path: server.socketPath)
        XCTAssertTrue(ok(r))
    }

    func testInsecureDirModesKeepSharedListenerOff() throws {
        for m: mode_t in [0o770, 0o755, 0o751, 0o700 | 0o2000] {
            try startServer(mode: m)
            if case .unavailable = server.sharedStatus {} else { XCTFail("mode \(String(m, radix: 8)): \(server.sharedStatus)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: server.sharedSocketPath!))
            server.stop(); try? FileManager.default.removeItem(at: base.appendingPathComponent("shared"))
        }
    }

    func testSharedDisabledWithoutConfiguration() throws {
        try startServer(shared: false)
        XCTAssertEqual(server.sharedStatus, .disabled)
        XCTAssertNil(server.sharedSocketPath)
    }

    func testStaleSharedSocketIsReplaced() throws {
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = SocketIO.withSockaddr(path: sharedDir.appendingPathComponent("agentbar.sock").path) { Darwin.bind(fd, $0, $1) }
        close(fd)   // leaves a stale socket file behind
        try startServer()
        XCTAssertEqual(server.sharedStatus, .active)
    }

    // MARK: roles

    func testAgentRoleOnlyOnSharedSocketOwnerSocketRejectsIt() async throws {
        try startServer()
        peer.set(agentUid)
        let r = await call("{\"token\":\"\(server.agentTokenForTests)\",\"op\":\"end\",\"session\":\"s\"}", path: server.socketPath)
        XCTAssertTrue(r.isEmpty, "agent uid is closed on the owner listener")
        let r2 = await agent("\"op\":\"end\",\"session\":\"s\"")
        XCTAssertTrue(ok(r2))
    }

    func testUnknownUidAndFailingPeerLookupAreClosed() async throws {
        try startServer()
        peer.set(agentUid + 5)
        let r = await call("{\"token\":\"\(server.agentTokenForTests)\",\"op\":\"end\",\"session\":\"s\"}")
        XCTAssertTrue(r.isEmpty)
        // peer lookup failure
        let sec = TransportSecurity(ownerUid: ownerUid, agentUid: agentUid, sharedDirectory: nil, peerCredentials: { _ in nil })
        let s2 = TransportServer(store: store, adapters: [:], directory: base.appendingPathComponent("o2"), security: sec)
        try s2.start(); defer { s2.stop() }
        let r2 = await call("{\"token\":\"\(s2.tokenForTests)\",\"op\":\"end\",\"session\":\"s\"}", path: s2.socketPath)
        XCTAssertTrue(r2.isEmpty)
    }

    func testSingleUserDefaultKeepsUidCheck() async throws {
        let s1 = TransportServer(store: store, adapters: [:], directory: base.appendingPathComponent("o3"))
        try s1.start(); defer { s1.stop() }
        XCTAssertEqual(s1.sharedStatus, .disabled)
        let r = await call("{\"token\":\"\(s1.tokenForTests)\",\"op\":\"end\",\"session\":\"s\"}", path: s1.socketPath)
        XCTAssertTrue(ok(r))
        // Same server class, but now the peer is "somebody else": closed.
        let sec = TransportSecurity(ownerUid: geteuid() + 1)
        let s2 = TransportServer(store: store, adapters: [:], directory: base.appendingPathComponent("o4"), security: sec)
        try s2.start(); defer { s2.stop() }
        let r2 = await call("{\"token\":\"\(s2.tokenForTests)\",\"op\":\"end\",\"session\":\"s\"}", path: s2.socketPath)
        XCTAssertTrue(r2.isEmpty)
    }

    func testTokenPerRole() async throws {
        try startServer()
        // owner token as agent, agent token as owner, garbage, missing
        peer.set(agentUid)
        let r1 = await call("{\"token\":\"\(server.tokenForTests)\",\"op\":\"end\",\"session\":\"a\"}")
        XCTAssertEqual(err(r1), "unauthorized")
        peer.set(ownerUid)
        let r2 = await call("{\"token\":\"\(server.agentTokenForTests)\",\"op\":\"end\",\"session\":\"a\"}")
        XCTAssertEqual(err(r2), "unauthorized")
        let r3 = await call("{\"token\":\"nope\",\"op\":\"end\",\"session\":\"a\"}")
        XCTAssertEqual(err(r3), "unauthorized")
        let r4 = await call("{\"op\":\"end\",\"session\":\"a\"}")
        XCTAssertEqual(err(r4), "unauthorized")
        XCTAssertTrue(store.sessions.isEmpty, "no state change on unauthorized")
        // owner may use the shared socket with its own token
        let r5 = await owner("\"op\":\"end\",\"session\":\"a\"")
        XCTAssertTrue(ok(r5))
    }

    func testAgentOpsAllowlist() async throws {
        try startServer()
        for op in ["shutdown", "rotate", "respond", "", "UPDATE"] {   // "host" is allowed for the agent role since stage 2
            let r6 = await agent("\"op\":\"\(op)\",\"session\":\"a\"")
            XCTAssertEqual(err(r6), "forbidden", op)
        }
        let r7 = await agent("\"op\":\"update\",\"session\":\"a\",\"state\":\"working\"")
        XCTAssertTrue(ok(r7))
        let r8 = await agent("\"op\":\"log\",\"session\":\"a\",\"kind\":\"status\",\"text\":\"x\"")
        XCTAssertTrue(ok(r8))
        let r9 = await agent("\"op\":\"log\",\"session\":\"a\",\"kind\":\"answer\",\"text\":\"x\"")
        XCTAssertEqual(err(r9), "kind not allowed")
        let r10 = await agent("\"op\":\"end\",\"session\":\"a\"")
        XCTAssertTrue(ok(r10))
        let r11 = await agent("\"op\":\"remove\",\"session\":\"a\"")
        XCTAssertTrue(ok(r11))
        // the owner keeps the unknown-op answer; the host channel is agent-only
        let r12 = await owner("\"op\":\"shutdown\",\"session\":\"a\"")
        XCTAssertEqual(err(r12), "unknown op")
        let r12b = await owner("\"op\":\"host\",\"protocol\":1,\"user\":\"u\",\"workspaceRoot\":\"/r\"")
        XCTAssertEqual(err(r12b), "forbidden")
    }

    func testAgentCannotTouchOwnerOrChatOwnedSessions() async throws {
        try startServer()
        let r13 = await owner("\"op\":\"update\",\"session\":\"own1\",\"name\":\"Mine\"")
        XCTAssertTrue(ok(r13))          // via owner socket op
        store.apply(.sessionUpdate(id: "ui1", name: "UI", kind: nil, state: .working, action: nil, supportsStop: nil)) // no origin entry at all
        store.markChatOwned("chat-1")
        for sid in ["own1", "ui1", "chat-1"] {
            for op in ["update", "log", "end", "remove"] {
                let extra = op == "log" ? ",\"kind\":\"status\",\"text\":\"x\"" : ""
                let r14 = await agent("\"op\":\"\(op)\",\"session\":\"\(sid)\"\(extra)")
                XCTAssertEqual(err(r14), "session reserved", "\(op) \(sid)")
            }
            let r15 = await agent("\"op\":\"ask\",\"session\":\"\(sid)\",\"type\":\"info\",\"text\":\"t\",\"timeout\":1")
            XCTAssertEqual(err(r15), "session reserved")
            let r16 = await agent("\"op\":\"watch\",\"session\":\"\(sid)\"")
            XCTAssertEqual(err(r16), "session reserved")
            let r17 = await agent("\"op\":\"payload\",\"adapter\":\"claudeCode\",\"payload\":{\"s\":\"\(sid)\"}")
            XCTAssertEqual(err(r17), "session reserved")
        }
        XCTAssertEqual(store.sessions.first { $0.id == "own1" }?.name, "Mine")
        XCTAssertEqual(store.sessions.first { $0.id == "ui1" }?.name, "UI")
        XCTAssertNotNil(store.sessions.first { $0.id == "ui1" })
        XCTAssertNotNil(store.sessions.first { $0.id == "own1" })
    }

    func testAgentOwnsItsSessionsAndOwnerCanTakeThemOver() async throws {
        try startServer()
        let r18 = await agent("\"op\":\"update\",\"session\":\"x\",\"name\":\"A\"")
        XCTAssertTrue(ok(r18))
        let r19 = await agent("\"op\":\"update\",\"session\":\"x\",\"name\":\"B\"")
        XCTAssertTrue(ok(r19))
        XCTAssertEqual(store.sessions.first { $0.id == "x" }?.name, "B")
        let r20 = await owner("\"op\":\"update\",\"session\":\"x\",\"name\":\"Owner\"")
        XCTAssertTrue(ok(r20))
        let r21 = await agent("\"op\":\"update\",\"session\":\"x\",\"name\":\"C\"")
        XCTAssertEqual(err(r21), "session reserved")
        XCTAssertEqual(store.sessions.first { $0.id == "x" }?.name, "Owner")
    }

    func testHookDoubleApprovalGuardOnClaudeSessionIdAlias() async throws {
        try startServer()
        // The in-app chat reported claude's own session id; hooks of that claude (agent home) must not raise a second approval.
        store.markChatOwned("claude-uuid-1")
        let r22 = await agent("\"op\":\"payload\",\"adapter\":\"claudeCode\",\"payload\":{\"s\":\"claude-uuid-1\"}")
        XCTAssertEqual(err(r22), "session reserved")
        XCTAssertTrue(store.sessions.isEmpty)
        // An unrelated terminal session of the agent user passes (noask = update only, no blocking approval).
        let r = await agent("\"op\":\"payload\",\"adapter\":\"claudeCode\",\"payload\":{\"s\":\"term-1\",\"noask\":1}")
        XCTAssertTrue(ok(r)); XCTAssertEqual(r["output"] as? String, "")
        XCTAssertNotNil(store.sessions.first { $0.id == "term-1" })
    }

    func testAgentHookApprovalRoundTripOverGroupSocket() async throws {
        try startServer()
        peer.set(agentUid)
        let path = server.sharedSocketPath!, tok = server.agentTokenForTests
        async let reply: [String: Any] = {
            let line: String? = await detached {
                guard let c = RawClient(path: path) else { return nil }
                defer { c.close_() }
                c.send("{\"token\":\"\(tok)\",\"op\":\"payload\",\"adapter\":\"claudeCode\",\"payload\":{\"s\":\"t1\"}}\n")
                return c.readLine()
            }
            return (line.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
        }()
        for _ in 0..<100 where store.pendingRequestCount == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(store.pendingRequestCount, 1)
        store.respond(AgentResponse(requestId: "p-t1", optionId: "allow"), sessionId: "t1")
        let r = await reply
        XCTAssertEqual(r["output"] as? String, "ANS:allow")
    }

    // MARK: quotas

    func testAgentSessionQuota() async throws {
        try startServer(quota: RoleQuota(maxConnections: 50, maxSessions: 2, maxPendingRequests: 10))
        let r23 = await agent("\"op\":\"update\",\"session\":\"q1\"")
        XCTAssertTrue(ok(r23))
        let r24 = await agent("\"op\":\"update\",\"session\":\"q2\"")
        XCTAssertTrue(ok(r24))
        let r25 = await agent("\"op\":\"update\",\"session\":\"q3\"")
        XCTAssertEqual(err(r25), "too many sessions")
        let r26 = await agent("\"op\":\"update\",\"session\":\"q1\",\"state\":\"working\"")
        XCTAssertTrue(ok(r26))   // existing ids stay usable
        XCTAssertNil(store.sessions.first { $0.id == "q3" })
        // the owner is not subject to the agent quota
        let r27 = await owner("\"op\":\"update\",\"session\":\"q4\"")
        XCTAssertTrue(ok(r27))
        let r28 = await owner("\"op\":\"update\",\"session\":\"q5\"")
        XCTAssertTrue(ok(r28))
    }

    func testAgentPendingRequestQuota() async throws {
        try startServer(quota: RoleQuota(maxConnections: 50, maxSessions: 10, maxPendingRequests: 2))
        peer.set(agentUid)
        let path = server.sharedSocketPath!, tok = server.agentTokenForTests
        let holders: [RawClient] = await detached {
            (0..<2).compactMap { i -> RawClient? in
                guard let c = RawClient(path: path) else { return nil }
                c.send("{\"token\":\"\(tok)\",\"op\":\"ask\",\"session\":\"p\(i)\",\"type\":\"info\",\"text\":\"t\"}\n")
                return c
            }
        }
        for _ in 0..<100 where store.pendingRequestCount < 2 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(store.pendingRequestCount, 2)
        let r29 = await agent("\"op\":\"ask\",\"session\":\"p9\",\"type\":\"info\",\"text\":\"t\",\"timeout\":1")
        XCTAssertEqual(err(r29), "too many pending requests")
        // blocking hook payload: quota failure = no decision (agent's own dialog), never an allow
        let r = await agent("\"op\":\"payload\",\"adapter\":\"claudeCode\",\"payload\":{\"s\":\"p8\"}")
        XCTAssertEqual(r["output"] as? String, "")
        // the owner's own request still works while the agent is at its cap
        peer.set(ownerUid)
        let tokO = server.tokenForTests
        let held: RawClient? = await detached {
            guard let c = RawClient(path: path) else { return nil }
            c.send("{\"token\":\"\(tokO)\",\"op\":\"ask\",\"session\":\"o1\",\"type\":\"info\",\"text\":\"t\"}\n"); return c
        }
        for _ in 0..<100 where store.pendingRequestCount < 3 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(store.pendingRequestCount, 3)
        holders.forEach { $0.close_() }; held?.close_()
    }

    func testAgentConnectionQuota() async throws {
        try startServer(quota: RoleQuota(maxConnections: 2, maxSessions: 10, maxPendingRequests: 10))
        peer.set(agentUid)
        let path = server.sharedSocketPath!
        let idle: [RawClient] = await detached { (0..<2).compactMap { _ in RawClient(path: path) } }
        try await Task.sleep(nanoseconds: 300_000_000)
        let r = await agent("\"op\":\"end\",\"session\":\"z\"")
        XCTAssertTrue(r.isEmpty, "third agent connection is closed by the quota")
        idle.forEach { $0.close_() }
        try await Task.sleep(nanoseconds: 400_000_000)
        let r30 = await agent("\"op\":\"end\",\"session\":\"z\"")
        XCTAssertTrue(ok(r30))
    }

    // MARK: rotation

    func testRotationGraceAndFiles() async throws {
        try startServer()
        let oldOwner = server.tokenForTests, oldAgent = server.agentTokenForTests
        try server.rotateTokens(grace: 0.6)
        XCTAssertNotEqual(oldOwner, server.tokenForTests); XCTAssertNotEqual(oldAgent, server.agentTokenForTests)
        XCTAssertEqual(try String(contentsOfFile: server.tokenPath, encoding: .utf8), server.tokenForTests)
        XCTAssertEqual(try String(contentsOfFile: server.agentTokenPath!, encoding: .utf8), server.agentTokenForTests)
        XCTAssertEqual(perm(server.tokenPath), 0o600); XCTAssertEqual(perm(server.agentTokenPath!), 0o640)
        var st = stat(); stat(server.agentTokenPath!, &st); XCTAssertEqual(st.st_gid, getgid())
        // no temp files left behind
        let left = try FileManager.default.contentsOfDirectory(atPath: sharedDir.path).filter { $0.contains(".tmp") }
        XCTAssertTrue(left.isEmpty, "\(left)")
        peer.set(agentUid)
        let r31 = await call("{\"token\":\"\(oldAgent)\",\"op\":\"end\",\"session\":\"g\"}")
        XCTAssertTrue(ok(r31), "old token valid during grace")
        let r32 = await agent("\"op\":\"end\",\"session\":\"g\"")
        XCTAssertTrue(ok(r32), "new token valid")
        try await Task.sleep(nanoseconds: 800_000_000)
        let r33 = await call("{\"token\":\"\(oldAgent)\",\"op\":\"end\",\"session\":\"g\"}")
        XCTAssertEqual(err(r33), "unauthorized", "old token dead after grace")
        peer.set(ownerUid)
        let r34 = await call("{\"token\":\"\(oldOwner)\",\"op\":\"end\",\"session\":\"g\"}")
        XCTAssertEqual(err(r34), "unauthorized")
        let r35 = await owner("\"op\":\"end\",\"session\":\"g\"")
        XCTAssertTrue(ok(r35))
    }

    func testRotationWithZeroGraceInvalidatesImmediatelyAndKeepsWatchAlive() async throws {
        try startServer()
        let created = await agent("\"op\":\"update\",\"session\":\"w1\"")
        XCTAssertTrue(ok(created))
        peer.set(agentUid)
        let path = server.sharedSocketPath!, tok = server.agentTokenForTests
        let watcher: RawClient? = await detached {
            guard let c = RawClient(path: path) else { return nil }
            c.send("{\"token\":\"\(tok)\",\"op\":\"watch\",\"session\":\"w1\"}\n")
            return c
        }
        let first = await detached { watcher?.readLine() }
        XCTAssertEqual(first, "{\"event\":\"watching\",\"ok\":true}")
        try server.rotateTokens(grace: 0)
        let r36 = await call("{\"token\":\"\(tok)\",\"op\":\"end\",\"session\":\"w1\"}")
        XCTAssertEqual(err(r36), "unauthorized")
        store.stop(sessionId: "w1")
        let ev = await detached { watcher?.readLine() }
        XCTAssertEqual(ev, "{\"event\":\"stop\",\"ok\":true}", "already authenticated watch connection survives rotation")
        watcher?.close_()
    }

    func testRotateBeforeStartIsNoOp() throws {
        let s = TransportServer(store: store, adapters: [:], directory: base.appendingPathComponent("o5"))
        try s.rotateTokens()
        XCTAssertEqual(s.tokenForTests, "")
    }
}

// MARK: chat alias (double-approval guard in ChatSession)

@MainActor
final class ChatAliasReservationTests: XCTestCase {
    func testCliSessionIdIsReservedWhileChatLivesAndReleasedAfterExit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abalias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = FakeChatProcess(), store = SessionStore()
        let cfg = ChatConfig(executable: URL(fileURLWithPath: "/bin/echo"), workingDirectory: dir, sessionId: "c1",
                             idleTimeout: nil, idleCheckInterval: 0.02, killGrace: 0.05)
        let s = ChatSession(config: cfg, store: store, processFactory: { _ in fake }, environment: [:], deliver: { $0() })
        try s.start()
        XCTAssertFalse(store.isChatOwned("cli-uuid"))
        fake.emit(#"{"type":"system","subtype":"init","session_id":"cli-uuid","model":"m","tools":[]}"#)
        XCTAssertTrue(store.isChatOwned("cli-uuid"), "hooks of this claude must not create a second approval")
        XCTAssertTrue(store.isChatOwned("c1"))
        fake.onExit?(0)
        XCTAssertFalse(store.isChatOwned("cli-uuid")); XCTAssertFalse(store.isChatOwned("c1"))
    }
}

/// Adapter that reports a cwd as metadata like ClaudeCodeAdapter does.
private struct CwdAdapter: AgentAdapter {
    var kind: AgentKind { .claudeCode }
    func translate(payload: Data) throws -> [CoreEvent] {
        let o = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        return [.sessionUpdate(id: o?["s"] as? String ?? "?", name: "n", kind: .claudeCode, state: .working, action: nil, supportsStop: nil)]
    }
    func metadataEvents(payload: Data) -> [CoreEvent] {
        let o = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        return [.sessionDirectory(id: o?["s"] as? String ?? "?", path: o?["cwd"] as? String ?? "/x")]
    }
    func encode(response: AgentResponse, for request: AgentRequest) -> Data { Data() }
}

@MainActor
final class ContinueOriginTransportTests: XCTestCase {
    func testAgentCwdIgnoredOwnerCwdAcceptedAndOriginsRecorded() async throws {
        let ownerUid = geteuid() + 1, agentUid = geteuid()
        let base = URL(fileURLWithPath: "/tmp/abo-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = SessionStore()
        let peer = FakePeer(uid: agentUid)
        let sec = TransportSecurity(ownerUid: ownerUid, agentUid: agentUid, sharedDirectory: base.appendingPathComponent("shared"),
                                    sharedGid: getgid(), peerCredentials: peer.credentials)
        let server = TransportServer(store: store, adapters: ["claudeCode": CwdAdapter()], directory: base.appendingPathComponent("owner"), security: sec)
        try server.start(); defer { server.stop() }
        func call(_ role: PeerRole, _ rest: String) async {
            peer.set(role == .agent ? agentUid : ownerUid)
            let tok = role == .agent ? server.agentTokenForTests : server.tokenForTests
            let path = server.sharedSocketPath!
            _ = await detached { () -> String? in
                guard let c = RawClient(path: path) else { return nil }
                defer { c.close_() }
                c.send("{\"token\":\"\(tok)\",\(rest)}\n"); return c.readLine()
            }
        }
        await call(.agent, "\"op\":\"payload\",\"adapter\":\"claudeCode\",\"payload\":{\"s\":\"ag-1\",\"cwd\":\"/tmp/evil\"}")
        await call(.owner, "\"op\":\"payload\",\"adapter\":\"claudeCode\",\"payload\":{\"s\":\"ow-1\",\"cwd\":\"/tmp/fine\"}")
        let ag = store.sessions.first { $0.id == "ag-1" }, ow = store.sessions.first { $0.id == "ow-1" }
        XCTAssertNotNil(ag); XCTAssertNil(ag?.workingDirectory); XCTAssertEqual(ag?.originRole, .agent)
        XCTAssertEqual(ow?.workingDirectory, "/tmp/fine"); XCTAssertEqual(ow?.originRole, .owner)
        XCTAssertFalse(ag?.canContinueInPanel ?? true)
        XCTAssertTrue(ow?.canContinueInPanel ?? false)
    }
}
