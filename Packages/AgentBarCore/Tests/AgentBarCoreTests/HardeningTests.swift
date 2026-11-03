import XCTest
@testable import AgentBarCore

@MainActor
final class StoreHardeningTests: XCTestCase {
    func req(_ id: String) -> AgentRequest {
        AgentRequest(requestId: id, type: .approval, text: "t", options: [.init(id: "allow", label: "Allow")])
    }

    func testAnswerLeavesNeedsInputImmediately() {
        let s = SessionStore()
        _ = s.submit(sessionId: "a", request: req("r1"), waiter: nil)
        XCTAssertEqual(s.sessions[0].state, .needsInput)
        s.respond(AgentResponse(requestId: "r1", optionId: "allow"), sessionId: "a")
        XCTAssertEqual(s.sessions[0].state, .working)
        XCTAssertEqual(s.aggregateState, .working)
    }

    func testStaysNeedsInputWhileAnotherPending() {
        let s = SessionStore()
        _ = s.submit(sessionId: "a", request: req("r1"), waiter: nil)
        _ = s.submit(sessionId: "a", request: req("r2"), waiter: nil)
        s.respond(AgentResponse(requestId: "r1", optionId: "allow"), sessionId: "a")
        XCTAssertEqual(s.sessions[0].state, .needsInput)
        s.respond(AgentResponse(requestId: "r2", optionId: "allow"), sessionId: "a")
        XCTAssertEqual(s.sessions[0].state, .working)
    }

    /// User decision: finished sessions stay visible until the user closes them (no time-based expiry).
    func testEndedSessionStaysUntilUserRemovesIt() {
        var t = Date()
        let s = SessionStore(now: { t })
        s.apply(.sessionUpdate(id: "x", name: "x", kind: nil, state: .working, action: nil, supportsStop: nil))
        s.apply(.sessionUpdate(id: "live", name: "live", kind: nil, state: .working, action: nil, supportsStop: nil))
        s.apply(.sessionEnd(id: "x"))
        t = t.addingTimeInterval(24 * 3600); s.pruneEnded()
        t = t.addingTimeInterval(7 * 24 * 3600); s.pruneEnded()
        XCTAssertEqual(Set(s.sessions.map(\.id)), ["x", "live"])
        XCTAssertEqual(s.sessions.first { $0.id == "x" }?.state, .done)
        s.remove(sessionId: "x")
        XCTAssertEqual(s.sessions.map(\.id), ["live"])
    }

    func testReactivatedSessionIsNotPruned() {
        var t = Date()
        let s = SessionStore(now: { t })
        s.apply(.sessionUpdate(id: "x", name: "x", kind: nil, state: .working, action: nil, supportsStop: nil))
        s.apply(.sessionEnd(id: "x"))
        s.apply(.sessionUpdate(id: "x", name: nil, kind: nil, state: .working, action: nil, supportsStop: nil))
        t = t.addingTimeInterval(3600); s.pruneEnded()
        XCTAssertEqual(s.sessions.count, 1)
        XCTAssertEqual(s.sessions[0].state, .working)
    }

    func testOldestEndedRemovedBeyondCap() {
        var t = Date()
        let s = SessionStore(now: { t })
        for i in 0..<25 {
            s.apply(.sessionUpdate(id: "s\(i)", name: nil, kind: nil, state: .working, action: nil, supportsStop: nil))
            s.apply(.sessionEnd(id: "s\(i)"))
            t = t.addingTimeInterval(1)
        }
        XCTAssertEqual(s.sessions.count, SessionStore.maxListedSessions)
        XCTAssertFalse(s.sessions.contains { $0.id == "s0" })
        XCTAssertTrue(s.sessions.contains { $0.id == "s24" })
    }

    func testWorkingSessionsNeverPrunedByCap() {
        let s = SessionStore()
        for i in 0..<30 { s.apply(.sessionUpdate(id: "w\(i)", name: nil, kind: nil, state: .working, action: nil, supportsStop: nil)) }
        s.pruneEnded()
        XCTAssertEqual(s.sessions.count, 30)
    }
}

@MainActor
final class TransportHardeningTests: XCTestCase {
    var dir: URL!
    var store: SessionStore!
    var server: TransportServer!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: "/tmp/abh-\(UInt32.random(in: 0..<UInt32.max))")
        store = SessionStore()
        server = TransportServer(store: store, adapters: ["claudeCode": FakeAdapter()], directory: dir)
        try server.start()
    }
    override func tearDown() async throws { server.stop(); try? FileManager.default.removeItem(at: dir) }

    func call(_ raw: Data) async -> String? {
        let path = server.socketPath
        return await detached {
            guard let c = RawClient(path: path) else { return nil }
            defer { c.close_() }
            SocketIO.writeAll(c.fd, raw)
            return c.readLine()
        }
    }

    func testStopRemovesSocketAndToken() {
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.tokenPath))
    }

    func testHostilePayloadsDoNotCrashOrChangeState() async {
        let tok = server.tokenForTests
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        var binary = Data((0..<2000).map { _ in UInt8.random(in: 0...255) }.filter { $0 != 0x0A }); binary.append(0x0A)
        let cases: [Data] = [
            Data((deep + "\n").utf8),
            Data("{\"token\":\"\(tok)\",\"op\":\"payload\",\"adapter\":\"claudeCode\",\"payload\":\(deep)}\n".utf8),
            binary,
            Data("{\"token\":\"\(tok)\",\"op\":\"log\",\"session\":\"a\\u0000b\",\"kind\":\"status\",\"text\":\"x\\u0000y\"}\n".utf8),
            Data("{\"token\":\"\(tok)\",\"op\":\"update\",\"session\":\"s\",\"name\":\"[x](https://evil.example)\\n**b**\"}\n".utf8),
            Data("\u{0}\u{0}\u{0}\n".utf8),
        ]
        for c in cases { _ = await call(c) }
        // Server still alive and answering after the barrage.
        let r = await call(Data("{\"token\":\"\(tok)\",\"op\":\"end\",\"session\":\"zz\"}\n".utf8))
        XCTAssertEqual(r, "{\"ok\":true}")
        // Markdown/links are kept verbatim as plain data (UI uses verbatim Text).
        XCTAssertEqual(store.sessions.first { $0.id == "s" }?.name, "[x](https://evil.example)\n**b**")
    }

    func testConnectionCapAndRecovery() async {
        let path = server.socketPath
        let n = TransportServer.maxConnections + 60
        let fds: [Int32] = await detached {
            (0..<n).compactMap { _ in RawClient(path: path)?.fd }
        }
        XCTAssertGreaterThan(fds.count, 300)   // connects may fail once the 128-entry backlog is full; excess is closed by the server
        try? await Task.sleep(nanoseconds: 500_000_000)
        fds.forEach { close($0) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let r = await call(Data("{\"token\":\"\(server.tokenForTests)\",\"op\":\"end\",\"session\":\"q\"}\n".utf8))
        XCTAssertEqual(r, "{\"ok\":true}")
    }
}
