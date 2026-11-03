import XCTest
@testable import AgentBarCore

/// The `host` op through the real TransportServer (fake peer uids, no second macOS user needed), the HostRunner on a real
/// unix socket, and ChatSession + RemoteChatProcess ⇄ transport ⇄ HostService + PosixChatProcess with a shell script as "claude".
@MainActor
final class HostChannelTests: XCTestCase {
    let ownerUid = geteuid() + 1
    let agentUid = geteuid()
    var base: URL!
    var sharedDir: URL { base.appendingPathComponent("shared") }
    var store: SessionStore!
    var server: TransportServer!
    var peer: FakePeer!
    var fixture: HostFixture!
    var runner: HostRunner?
    var runnerDone = HostFlag()

    override func setUp() async throws {
        base = URL(fileURLWithPath: "/tmp/abc-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = SessionStore()
        peer = FakePeer(uid: agentUid)
        let sec = TransportSecurity(ownerUid: ownerUid, agentUid: agentUid, sharedDirectory: sharedDir, sharedGid: getgid(),
                                    peerCredentials: peer.credentials)
        server = TransportServer(store: store, adapters: ["claudeCode": FakeAdapter()], directory: base.appendingPathComponent("owner"), security: sec)
        try server.start()
        XCTAssertEqual(server.sharedStatus, .active)
        fixture = try HostFixture()
    }
    override func tearDown() async throws {
        runner?.stop()
        server?.stop()
        try? FileManager.default.removeItem(at: base)
    }

    func call(_ json: String) async -> [String: Any] {
        let p = server.sharedSocketPath!
        let line: String? = await detached {
            guard let c = RawClient(path: p) else { return nil }
            defer { c.close_() }
            c.send(json + "\n")
            return c.readLine()
        }
        return (line.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
    }
    func hello(token: String? = nil, protocolVersion: Int = 1, user: String = "agentbar", extra: String = "") -> String {
        "{\"token\":\"\(token ?? server.agentTokenForTests)\",\"op\":\"host\",\"protocol\":\(protocolVersion),\"user\":\"\(user)\",\"uid\":1,\"workspaceRoot\":\"/Users/agentbar/work\",\"agents\":{\"claude\":\"/x/claude\"}\(extra)}"
    }

    func startRunner(claude: URL) -> HostRunner {
        let svc = HostService(config: fixture.config(claude: claude, grace: 0.3))
        let r = HostRunner(service: svc, ipcDirectory: sharedDir)
        r.log = { _ in }
        runner = r
        let done = HostFlag(); runnerDone = done
        Thread { _ = try? r.connectOnce(); done.set() }.start()
        return r
    }

    func expectMain(_ message: String = "timeout", timeout: TimeInterval = 5, line: UInt = #line, _ cond: @escaping @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { XCTFail(message, line: line); return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: access control

    func testOnlyTheAgentRoleMayOpenTheHostChannel() async {
        peer.set(ownerUid)
        var r = await call("{\"token\":\"\(server.tokenForTests)\",\"op\":\"host\",\"protocol\":1,\"user\":\"u\",\"workspaceRoot\":\"/r\"}")
        XCTAssertEqual(r["error"] as? String, "forbidden", "owner role")
        peer.set(agentUid)
        r = await call(hello(token: server.tokenForTests))
        XCTAssertEqual(r["error"] as? String, "unauthorized", "owner token does not open the agent role")
        r = await call(hello(token: "bogus"))
        XCTAssertEqual(r["error"] as? String, "unauthorized")
        XCTAssertFalse(server.hostClient.isConnected)
    }

    func testBadHelloIsRejected() async {
        var r = await call(hello(protocolVersion: 2)); XCTAssertEqual(r["error"] as? String, "unsupported protocol")
        r = await call(hello(user: "a\\nb")); XCTAssertEqual(r["error"] as? String, "invalid hello")
        r = await call(hello(user: "")); XCTAssertEqual(r["error"] as? String, "invalid hello")
        r = await call(hello(extra: ",\"agents2\":1").replacingOccurrences(of: "\"agents\":{\"claude\":\"/x/claude\"}", with: "\"agents\":[1]"))
        XCTAssertEqual(r["error"] as? String, "invalid hello")
        XCTAssertFalse(server.hostClient.isConnected)
    }

    func testHostConnectionCannotInjectStoreOps() async {
        // The host speaks HostEvent frames only. Store ops sent over the host channel (hostile host) are not even recognised.
        let p = server.sharedSocketPath!, tok = server.agentTokenForTests
        let ok: Bool = await detached {
            guard let c = RawClient(path: p) else { return false }
            defer { c.close_() }
            c.send("{\"token\":\"\(tok)\",\"op\":\"host\",\"protocol\":1,\"user\":\"u\",\"workspaceRoot\":\"/r\"}\n")
            guard let ready = c.readLine(), ready.contains("\"ready\"") else { return false }
            c.send("{\"token\":\"\(tok)\",\"op\":\"update\",\"session\":\"evil\",\"state\":\"working\"}\n"
                   + "{\"ev\":\"stdout\",\"id\":\"chat-x\",\"line\":\"forged\"}\n{\"ev\":\"pong\"}\n")
            Thread.sleep(forTimeInterval: 0.3)
            return true
        }
        XCTAssertTrue(ok)
        XCTAssertTrue(store.sessions.isEmpty, "no session may appear through the host channel")
        let hc = server.hostClient; XCTAssertTrue(hostWait { !hc.isConnected })
        XCTAssertGreaterThanOrEqual(server.hostClient.droppedFrames, 1, "forged frame for an id the app never handed out")
    }

    // MARK: runner + real socket

    func testRunnerConnectsAndSecondHostIsRefused() async throws {
        try fixture.workspace("ws")
        _ = startRunner(claude: try fixture.script("claude", "exec cat"))
        await expectMain("") { self.server.hostClient.isConnected }
        let info = server.hostClient.info!
        XCTAssertEqual(info.user, "tester"); XCTAssertEqual(info.uid, Int(agentUid), "uid is the kernel's, not the hello's")
        XCTAssertEqual(info.workspaceRoot, fixture.work.path); XCTAssertEqual(info.agents["claude"], fixture.bin.appendingPathComponent("claude").path)
        let second = await call(hello())
        XCTAssertEqual(second["error"] as? String, "host already connected")
        XCTAssertTrue(server.hostClient.isConnected, "first host unaffected")
    }

    func testServerStopTerminatesChildrenAndReportsDisconnect() async throws {
        try fixture.workspace("ws")
        _ = startRunner(claude: try fixture.script("claude", "sleep 300 &\necho \"child=$!\"\nexec cat"))
        await expectMain("") { self.server.hostClient.isConnected }
        let spec = try ChatConfig.remote(workspace: "ws").launchSpec(environment: [:])
        let p = try server.hostClient.processFactory(spec)
        let c = HostCollector()
        try p.start(onLine: { c.line($0) }, onStderr: { c.err($0) }, onExit: { c.exit($0) })
        XCTAssertTrue(hostWait { c.lines.contains { $0.hasPrefix("child=") } })
        let child = Int32(c.lines.first { $0.hasPrefix("child=") }!.dropFirst(6))!
        server.stop()
        XCTAssertTrue(hostWait { c.exits == [RemoteChatProcess.disconnectedStatus] }, "\(c.exits)")
        XCTAssertTrue(hostWait { !alive(child) })
        let rd = runnerDone; XCTAssertTrue(hostWait { rd.isSet })
        XCTAssertFalse(server.hostClient.isConnected)
    }

    // MARK: ChatSession end to end

    let fixtureClaude = """
    read -r first
    echo '{"type":"system","subtype":"init","session_id":"cli-sess-1","model":"claude-x"}'
    echo '{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build"},"tool_use_id":"tu1"}}'
    read -r resp
    printf '%s\\n' "$first" > first.txt
    printf '%s\\n' "$resp" > resp.txt
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"finished"}]}}'
    echo '{"type":"result","subtype":"success","is_error":false,"result":"finished"}'
    exec cat
    """

    func testChatSessionOverTheHostChannel() async throws {
        try fixture.workspace("proj")
        _ = startRunner(claude: try fixture.script("claude", fixtureClaude))
        await expectMain("") { self.server.hostClient.isConnected }
        let info = server.hostClient.info!
        let cfg = ChatConfig.remote(workspace: "proj", workspaceRoot: info.workspaceRoot, sessionId: "chat-remote1", model: "haiku", killGrace: 0.5)
        let chat = ChatSession(config: cfg, store: store, processFactory: server.hostClient.processFactory)
        try chat.start()
        XCTAssertTrue(store.isChatOwned("chat-remote1"))
        try chat.send(text: "please clean")
        let sid = "chat-remote1"
        func session() -> AgentSession? { store.sessions.first { $0.id == sid } }
        await expectMain("approval arrives in the owner's store") { session()?.pendingRequests.isEmpty == false }
        let req = session()!.pendingRequests[0]
        // Rendering happens owner-side from the raw tool input; the cwd line shows the agent workspace path.
        XCTAssertTrue(req.text.hasPrefix("Allow Bash?"), req.text)
        XCTAssertTrue(req.text.contains("command: rm -rf build"), req.text)
        XCTAssertTrue(req.text.contains("cwd: \(fixture.work.path)/proj"), req.text)
        XCTAssertTrue(store.isChatOwned("cli-sess-1"), "claude's own session id is reserved (no double approval via hooks)")
        store.respond(AgentResponse(requestId: req.requestId, optionId: "deny"), sessionId: sid)
        await expectMain("") { session()?.history.contains { $0.text == "Claude: finished" } == true }
        let ws = fixture.work.appendingPathComponent("proj")
        let resp = try String(contentsOf: ws.appendingPathComponent("resp.txt"), encoding: .utf8)
        XCTAssertTrue(resp.contains("\"behavior\":\"deny\"") && resp.contains("\"request_id\":\"r1\""), resp)
        let first = try String(contentsOf: ws.appendingPathComponent("first.txt"), encoding: .utf8)
        XCTAssertTrue(first.contains("please clean"), first)
        chat.stop()
        await expectMain("stop works through the host: \(chat.phase)") { chat.phase == .exited }
        let rn = runner; XCTAssertTrue(hostWait { rn?.service.activeProcessCount == 0 })
    }

    func testChatStartFailsSynchronouslyWhenHostIsDown() throws {
        let cfg = ChatConfig.remote(workspace: "proj", sessionId: "chat-down")
        let chat = ChatSession(config: cfg, store: store, processFactory: server.hostClient.processFactory)
        XCTAssertThrowsError(try chat.start())
        XCTAssertFalse(store.isChatOwned("chat-down"), "reservation released again")
    }

    func testSpawnFailureShowsUpAsExit127InTheChat() async throws {
        _ = startRunner(claude: try fixture.script("claude", "exec cat"))   // workspace "gone" does not exist
        await expectMain("") { self.server.hostClient.isConnected }
        let chat = ChatSession(config: .remote(workspace: "gone", sessionId: "chat-f"), store: store, processFactory: server.hostClient.processFactory)
        try chat.start()
        await expectMain("") { chat.phase == .exited }
        let h = store.sessions.first { $0.id == "chat-f" }?.history.map(\.text) ?? []
        XCTAssertTrue(h.contains { $0.contains("127") && $0.contains("workspace not found") }, "\(h)")
    }

    func testHostLossEndsTheChatWithAnError() async throws {
        try fixture.workspace("proj")
        let r = startRunner(claude: try fixture.script("claude", "exec cat"))
        await expectMain("") { self.server.hostClient.isConnected }
        let chat = ChatSession(config: .remote(workspace: "proj", sessionId: "chat-l", killGrace: 0.2), store: store, processFactory: server.hostClient.processFactory)
        try chat.start()
        XCTAssertTrue(hostWait { r.service.activeProcessCount == 1 })
        r.stop()
        await expectMain("") { chat.phase == .exited }
        let h = store.sessions.first { $0.id == "chat-l" }?.history.map(\.text) ?? []
        XCTAssertTrue(h.contains { $0.contains("disconnected") }, "\(h)")
    }
}
