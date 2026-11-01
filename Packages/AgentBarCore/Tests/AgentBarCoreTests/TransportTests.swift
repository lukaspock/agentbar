import XCTest
@testable import AgentBarCore

struct FakeAdapter: AgentAdapter {
    var kind: AgentKind { .claudeCode }
    func translate(payload: Data) throws -> [CoreEvent] {
        guard let o = try JSONSerialization.jsonObject(with: payload) as? [String: Any], let s = o["s"] as? String else {
            throw CocoaError(.coderReadCorrupt)
        }
        if o["noask"] != nil { return [.sessionUpdate(id: s, name: "n", kind: nil, state: .working, action: nil, supportsStop: nil)] }
        return [.ask(sessionId: s, request: AgentRequest(requestId: "p-\(s)", type: .approval, text: "ok?",
                options: [.init(id: "allow", label: "Allow")], timeoutSeconds: 20, defaultOptionId: "deny"))]
    }
    func encode(response: AgentResponse, for request: AgentRequest) -> Data {
        response.reason == .answered ? Data("ANS:\(response.optionId ?? "")".utf8) : Data()
    }
}

/// Blocking POSIX test client; runs on its own thread so the main actor stays free.
final class RawClient: @unchecked Sendable {
    let fd: Int32
    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let rc = SocketIO.withSockaddr(path: path) { connect(fd, $0, $1) }
        if rc != 0 { close(fd); return nil }
    }
    func send(_ s: String) { SocketIO.writeAll(fd, Data(s.utf8)) }
    func readLine() -> String? {
        var buf = Data(); var b = [UInt8](repeating: 0, count: 4096)
        while !buf.contains(0x0A) { let n = read(fd, &b, b.count); if n <= 0 { break }; buf.append(contentsOf: b[0..<n]) }
        return buf.isEmpty ? nil : String(decoding: buf.prefix(while: { $0 != 0x0A }), as: UTF8.self)
    }
    func close_() { close(fd) }
}

func detached<T: Sendable>(_ f: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in Thread { c.resume(returning: f()) }.start() }
}

@MainActor
final class TransportTests: XCTestCase {
    var dir: URL!
    var store: SessionStore!
    var server: TransportServer!
    var token: String { server.tokenForTests }

    override func setUp() async throws {
        dir = URL(fileURLWithPath: "/tmp/abt-\(UInt32.random(in: 0..<UInt32.max))")
        store = SessionStore()
        server = TransportServer(store: store, adapters: ["claudeCode": FakeAdapter()], directory: dir)
        try server.start()
    }
    override func tearDown() async throws { server.stop(); try? FileManager.default.removeItem(at: dir) }

    func call(_ json: String) async -> String? {
        let path = server.socketPath
        return await detached {
            guard let c = RawClient(path: path) else { return nil }
            defer { c.close_() }
            c.send(json + "\n")
            return c.readLine()
        }
    }
    func field(_ json: String, _ k: String) async -> Any? { obj(await call(json))[k] }
    func tok(_ rest: String) -> String { "{\"token\":\"\(token)\",\(rest)}" }
    func obj(_ s: String?) -> [String: Any] { (s.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:] }
    func perm(_ p: String) -> Int { var st = stat(); stat(p, &st); return Int(st.st_mode & 0o777) }

    func waitFor(_ cond: @MainActor @escaping () -> Bool, timeout: TimeInterval = 5) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testPermissionsAndTokenFile() throws {
        XCTAssertEqual(perm(dir.path), 0o700)
        XCTAssertEqual(perm(server.socketPath), 0o600)
        XCTAssertEqual(perm(server.tokenPath), 0o600)
        XCTAssertEqual(try String(contentsOfFile: server.tokenPath).count, 64)
    }

    func testTokenRegeneratedAndStaleSocketCleaned() throws {
        let t1 = try String(contentsOfFile: server.tokenPath)
        server.stop()
        // Simulate crash leftovers: a stale socket file with no listener.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = SocketIO.withSockaddr(path: server.socketPath) { Darwin.bind(fd, $0, $1) }
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: server.socketPath))
        try server.start()
        XCTAssertNotEqual(t1, try String(contentsOfFile: server.tokenPath))
    }

    func testSecondInstanceRefused() {
        let other = TransportServer(store: store, directory: dir)
        XCTAssertThrowsError(try other.start()) { XCTAssertEqual($0 as? TransportServer.ServerError, .alreadyRunning) }
    }

    func testUpdateLogEnd() async {
        var r = obj(await call(tok("\"op\":\"update\",\"session\":\"s1\",\"name\":\"N\",\"kind\":\"codex\",\"state\":\"working\",\"action\":\"doing\",\"supportsStop\":true")))
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(store.sessions.first?.name, "N")
        XCTAssertEqual(store.sessions.first?.kind, .codex)
        XCTAssertEqual(store.sessions.first?.supportsStop, true)
        r = obj(await call(tok("\"op\":\"log\",\"session\":\"s1\",\"kind\":\"error\",\"text\":\"boom\"")))
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(store.sessions.first?.history.last?.text, "boom")
        r = obj(await call(tok("\"op\":\"end\",\"session\":\"s1\"")))
        XCTAssertEqual(store.sessions.first?.state, .done)
    }

    func testRejects() async {
        let v1 = await field("{\"op\":\"update\",\"session\":\"s\"}", "error")
        XCTAssertEqual(v1 as? String, "unauthorized")
        let v2 = await field("{\"token\":\"nope\",\"op\":\"update\",\"session\":\"s\"}", "error")
        XCTAssertEqual(v2 as? String, "unauthorized")
        XCTAssertTrue(store.sessions.isEmpty)
        let v3 = await field("not json", "error")
        XCTAssertEqual(v3 as? String, "malformed json")
        let v4 = await field("[1,2]", "ok")
        XCTAssertEqual(v4 as? Bool, false)
        let v5 = await field(tok("\"op\":\"zzz\",\"session\":\"s\""), "error")
        XCTAssertEqual(v5 as? String, "unknown op")
        let v6 = await field(tok("\"op\":\"update\",\"session\":\"s\",\"state\":\"bogus\""), "ok")
        XCTAssertEqual(v6 as? Bool, false)
        let opts = (0..<7).map { "{\"id\":\"o\($0)\",\"label\":\"l\"}" }.joined(separator: ",")
        let v7 = await field(tok("\"op\":\"ask\",\"session\":\"s\",\"type\":\"info\",\"text\":\"t\",\"options\":[\(opts)]"), "error")
        XCTAssertEqual(v7 as? String, "too many options")
        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testOversizedLine() async {
        let path = server.socketPath
        let big = String(repeating: "a", count: 200_000)
        let reply = await detached { () -> String? in
            guard let c = RawClient(path: path) else { return nil }
            defer { c.close_() }
            c.send("{\"x\":\"\(big)\"}\n")
            return c.readLine()
        }
        XCTAssertEqual(obj(reply)["error"] as? String, "line too long")
        // Newline-less flood must also be cut off.
        let reply2 = await detached { () -> String? in
            guard let c = RawClient(path: path) else { return nil }
            defer { c.close_() }
            c.send(big)
            return c.readLine()
        }
        XCTAssertEqual(obj(reply2)["error"] as? String, "line too long")
    }

    func testAskAnswered() async {
        let path = server.socketPath
        let line = tok("\"op\":\"ask\",\"session\":\"s\",\"requestId\":\"r1\",\"type\":\"approval\",\"text\":\"go?\",\"options\":[{\"id\":\"allow\",\"label\":\"Allow\",\"style\":\"primary\"}]") + "\n"
        async let reply = detached { () -> String? in
            guard let c = RawClient(path: path) else { return nil }
            defer { c.close_() }
            c.send(line); return c.readLine()
        }
        await waitFor { self.store.pendingRequestCount == 1 }
        XCTAssertEqual(store.sessions.first?.state, .needsInput)
        store.respond(AgentResponse(requestId: "r1", optionId: "allow"), sessionId: "s")
        store.respond(AgentResponse(requestId: "r1", optionId: "allow"), sessionId: "s")
        let r = obj(await reply)
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["reason"] as? String, "answered")
        XCTAssertEqual(r["option"] as? String, "allow")
        XCTAssertEqual(r["requestId"] as? String, "r1")
    }

    func testAskTimeoutDefault() async {
        let r = obj(await call(tok("\"op\":\"ask\",\"session\":\"s\",\"type\":\"approval\",\"text\":\"t\",\"options\":[{\"id\":\"deny\",\"label\":\"D\"}],\"timeout\":1,\"default\":\"deny\"")))
        XCTAssertEqual(r["reason"] as? String, "timeout")
        XCTAssertEqual(r["option"] as? String, "deny")
    }

    func testDisconnectCancels() async {
        let path = server.socketPath
        let line = tok("\"op\":\"ask\",\"session\":\"s\",\"requestId\":\"rc\",\"type\":\"info\",\"text\":\"t\"") + "\n"
        let c = await detached { () -> RawClient? in
            guard let c = RawClient(path: path) else { return nil }
            c.send(line); return c
        }
        await waitFor { self.store.pendingRequestCount == 1 }
        XCTAssertEqual(store.pendingRequestCount, 1)
        c?.close_()
        await waitFor { self.store.pendingRequestCount == 0 }
        XCTAssertEqual(store.pendingRequestCount, 0)
        XCTAssertEqual(store.sessions.first?.history.last?.text, "cancelled")
    }

    func testServerStopCancelsWaiting() async {
        let path = server.socketPath
        let line = tok("\"op\":\"ask\",\"session\":\"s\",\"type\":\"info\",\"text\":\"t\"") + "\n"
        async let reply = detached { () -> String? in
            guard let c = RawClient(path: path) else { return nil }
            defer { c.close_() }
            c.send(line); return c.readLine()
        }
        await waitFor { self.store.pendingRequestCount == 1 }
        server.stop()
        _ = await reply
        await waitFor { self.store.pendingRequestCount == 0 }
        XCTAssertEqual(store.pendingRequestCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.socketPath))
    }

    func testPendingCapOverWire() async {
        let path = server.socketPath
        var clients: [RawClient] = []
        for i in 0..<100 {
            let line = tok("\"op\":\"ask\",\"session\":\"s\(i % 7)\",\"requestId\":\"r\(i)\",\"type\":\"info\",\"text\":\"t\"") + "\n"
            if let c = await detached({ () -> RawClient? in
                guard let c = RawClient(path: path) else { return nil }; c.send(line); return c }) { clients.append(c) }
        }
        await waitFor { self.store.pendingRequestCount == 100 }
        XCTAssertEqual(store.pendingRequestCount, 100)
        let r = obj(await call(tok("\"op\":\"ask\",\"session\":\"z\",\"type\":\"info\",\"text\":\"t\"")))
        XCTAssertEqual(r["error"] as? String, "too many pending requests")
        for c in clients { c.close_() }
        await waitFor { self.store.pendingRequestCount == 0 }
        XCTAssertEqual(store.pendingRequestCount, 0)
    }

    func testPayloadBlockingAndUnknownAdapter() async {
        let v8 = await field(tok("\"op\":\"payload\",\"adapter\":\"nope\",\"payload\":{}"), "error")
        XCTAssertEqual(v8 as? String, "unknown adapter")
        let v9 = await field(tok("\"op\":\"payload\",\"adapter\":\"claudeCode\",\"payload\":{\"bad\":1}"), "error")
        XCTAssertEqual(v9 as? String, "invalid payload")
        let v10 = await field(tok("\"op\":\"payload\",\"adapter\":\"claudeCode\",\"payload\":{\"s\":\"x\",\"noask\":1}"), "output")
        XCTAssertEqual(v10 as? String, "")
        let path = server.socketPath
        let line = tok("\"op\":\"payload\",\"adapter\":\"claudeCode\",\"payload\":{\"s\":\"hk\"}") + "\n"
        async let reply = detached { () -> String? in
            guard let c = RawClient(path: path) else { return nil }
            defer { c.close_() }
            c.send(line); return c.readLine()
        }
        await waitFor { self.store.pendingRequestCount == 1 }
        store.respond(AgentResponse(requestId: "p-hk", optionId: "allow"), sessionId: "hk")
        let r = obj(await reply)
        XCTAssertEqual(r["output"] as? String, "ANS:allow")
    }

    func testPayloadTimeoutGivesEmptyOutput() async {
        // Fake adapter uses 20s timeout; cancel via disconnect-less path: answer with timeout reason by ending session.
        let path = server.socketPath
        let line = tok("\"op\":\"payload\",\"adapter\":\"claudeCode\",\"payload\":{\"s\":\"hk2\"}") + "\n"
        async let reply = detached { () -> String? in
            guard let c = RawClient(path: path) else { return nil }
            defer { c.close_() }
            c.send(line); return c.readLine()
        }
        await waitFor { self.store.pendingRequestCount == 1 }
        store.apply(.sessionEnd(id: "hk2"))   // cancelled => adapter encodes empty
        let rr = obj(await reply)
        XCTAssertEqual(rr["output"] as? String, "")
    }

    func testRemoveOpCancelsWaitingAsk() async {
        let path = server.socketPath
        let line = tok("\"op\":\"ask\",\"session\":\"rs\",\"requestId\":\"rr1\",\"type\":\"approval\",\"text\":\"go?\",\"options\":[{\"id\":\"allow\",\"label\":\"Allow\"}],\"timeout\":30") + "\n"
        async let reply = detached { () -> String? in
            guard let c = RawClient(path: path) else { return nil }
            defer { c.close_() }
            c.send(line); return c.readLine()
        }
        await waitFor { self.store.pendingRequestCount == 1 }
        // Unauthorized remove changes nothing.
        let bad = await field("{\"token\":\"nope\",\"op\":\"remove\",\"session\":\"rs\"}", "error")
        XCTAssertEqual(bad as? String, "unauthorized")
        XCTAssertEqual(store.sessions.count, 1)
        let ok = obj(await call(tok("\"op\":\"remove\",\"session\":\"rs\"")))
        XCTAssertEqual(ok["ok"] as? Bool, true)
        let r = obj(await reply)
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["reason"] as? String, "cancelled")
        XCTAssertEqual(r["requestId"] as? String, "rr1")
        XCTAssertTrue(store.sessions.isEmpty)
        // Idempotent / unknown id: still ok.
        let again = obj(await call(tok("\"op\":\"remove\",\"session\":\"rs\"")))
        XCTAssertEqual(again["ok"] as? Bool, true)
        let missing = await field(tok("\"op\":\"remove\""), "error")
        XCTAssertEqual(missing as? String, "invalid session")
    }
}
