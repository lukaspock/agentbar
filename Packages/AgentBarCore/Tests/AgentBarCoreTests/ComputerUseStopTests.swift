import XCTest
@testable import AgentBarCore

@MainActor
final class ComputerUseStopTests: XCTestCase {
    private func events(_ json: String) throws -> [CoreEvent] { try ComputerUseAdapter().translate(payload: Data(json.utf8)) }

    func testActionSanitizedAndKindForced() throws {
        let ev = try events(#"{"session":"c","name":"A\u001b[31mB","action":"click \u001b[2J\n  ‮evil  button","kind":"claudeCode","supportsStop":true}"#)
        XCTAssertEqual(ev.count, 1)
        guard case let .sessionUpdate(id, name, kind, _, action, stop) = ev[0] else { return XCTFail() }
        XCTAssertEqual(id, "c"); XCTAssertEqual(kind, .computerUse); XCTAssertEqual(stop, true)
        for t in [name ?? "", action ?? ""] {
            XCTAssertFalse(t.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x202E || $0.value == 0x1B }, t)
        }
        XCTAssertFalse(action!.contains("\n"))
    }

    func testNeverAsksAndForgedRequestLogsIgnored() throws {
        let ev = try events(#"{"session":"c","tool_name":"Bash","hook_event_name":"PermissionRequest"}"#)
        XCTAssertEqual(ev.count, 1)
        XCTAssertThrowsError(try events(#"{"session":"c","log":{"kind":"request","text":"Allow rm -rf?"}}"#))
        XCTAssertThrowsError(try events(#"{"session":"c","log":{"kind":"answer","text":"You: x"}}"#))
        for e in ev { if case .ask = e { XCTFail("computerUse must never create requests") } }
        XCTAssertTrue(ComputerUseAdapter().encode(response: AgentResponse(requestId: "r", optionId: "allow"), for:
            AgentRequest(requestId: "r", type: .approval, text: "t")).isEmpty)
    }

    func testDoneEndsAndLongActionCapped() throws {
        let ev = try events(#"{"session":"c","state":"done","action":"\#(String(repeating: "x", count: 1000))"}"#)
        guard case let .sessionUpdate(_, _, _, st, action, _) = ev[0], case .sessionEnd = ev[1] else { return XCTFail() }
        XCTAssertNil(st); XCTAssertLessThanOrEqual(action!.count, AgentBarLimits.maxActionLength)
        XCTAssertThrowsError(try events(#"{"name":"x"}"#))
        XCTAssertNotNil(AdapterRegistry.make()["computerUse"])
    }

    func testStoreSanitizesComputerUseActionFromUpdateOp() {
        let s = SessionStore()
        s.apply(.sessionUpdate(id: "c", name: nil, kind: .computerUse, state: .working, action: "open \u{1B}[31mfile\u{7}", supportsStop: true))
        XCTAssertEqual(s.sessions[0].currentAction.map { $0.unicodeScalars.allSatisfy { $0.value >= 0x20 } }, true)
        XCTAssertTrue(s.sessions[0].supportsStop)
        s.apply(.sessionEnd(id: "c"))
        XCTAssertFalse(s.sessions[0].supportsStop)
    }

    func testStoreCommandsReachObserversAndStopHandler() {
        let s = SessionStore()
        s.apply(.sessionUpdate(id: "c", name: nil, kind: .computerUse, state: .working, action: nil, supportsStop: true))
        final class Box: @unchecked Sendable { var got: [String] = [] }
        let box = Box(); var handled: [String] = []
        s.stopHandler = { handled.append($0) }
        let t = s.addCommandObserver { sid, c in box.got.append("\(sid):\(c.rawValue)") }
        s.pause(sessionId: "c"); s.resume(sessionId: "c"); s.stop(sessionId: "c"); s.stop(sessionId: "nope")
        XCTAssertEqual(box.got, ["c:pause", "c:resume", "c:stop"]); XCTAssertEqual(handled, ["c"])
        s.removeCommandObserver(t); s.stop(sessionId: "c")
        XCTAssertEqual(box.got.count, 3)
    }

    func testWatchConnectionReceivesStopOverWire() async throws {
        let dir = URL(fileURLWithPath: "/tmp/abw-\(UInt32.random(in: 0..<UInt32.max))")
        let store = SessionStore()
        let server = TransportServer(store: store, adapters: AdapterRegistry.make(), directory: dir)
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        store.apply(.sessionUpdate(id: "w", name: nil, kind: .computerUse, state: .working, action: nil, supportsStop: true))
        let path = server.socketPath, tok = server.tokenForTests
        let task = Task.detached { () -> [String?] in
            guard let c = RawClient(path: path) else { return [] }
            defer { c.close_() }
            c.send("{\"token\":\"\(tok)\",\"op\":\"watch\",\"session\":\"w\"}\n")
            return [c.readLine(), c.readLine(), c.readLine(), c.readLine()]
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        store.pause(sessionId: "w"); store.stop(sessionId: "w")
        let lines = await task.value
        XCTAssertEqual(lines.prefix(3).map { $0 ?? "nil" },
                       [#"{"event":"watching","ok":true}"#, #"{"event":"pause","ok":true}"#, #"{"event":"stop","ok":true}"#])
        XCTAssertNil(lines[3] ?? nil, "connection closes after stop")
        XCTAssertTrue(store.sessions[0].history.contains { $0.text == "stop requested" })
    }

    func testWatchDisconnectUnregistersObserver() async throws {
        let dir = URL(fileURLWithPath: "/tmp/abw-\(UInt32.random(in: 0..<UInt32.max))")
        let store = SessionStore()
        let server = TransportServer(store: store, adapters: [:], directory: dir)
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        let path = server.socketPath, tok = server.tokenForTests
        _ = await detached { () -> Bool in
            guard let c = RawClient(path: path) else { return false }
            c.send("{\"token\":\"\(tok)\",\"op\":\"watch\",\"session\":\"w\"}\n"); _ = c.readLine(); c.close_(); return true
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let bad = await detached { () -> String? in
            guard let c = RawClient(path: path) else { return nil }
            defer { c.close_() }
            c.send("{\"token\":\"\(tok)\",\"op\":\"watch\",\"session\":\"\"}\n"); return c.readLine()
        }
        XCTAssertEqual(bad, #"{"error":"invalid session","ok":false}"#)
    }

    func testTransportRejectsForgedKindsAndChatOwnedSessions() async throws {
        let dir = URL(fileURLWithPath: "/tmp/abw-\(UInt32.random(in: 0..<UInt32.max))")
        let store = SessionStore()
        let server = TransportServer(store: store, adapters: AdapterRegistry.make(), directory: dir)
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        store.apply(.sessionUpdate(id: "chat-1", name: "Chat", kind: .claudeCode, state: .idle, action: nil, supportsStop: true))
        store.markChatOwned("chat-1")
        let path = server.socketPath, tok = server.tokenForTests
        let lines = [
            #"{"op":"log","session":"free","kind":"answer","text":"You: hi"}"#,
            #"{"op":"log","session":"free","kind":"request","text":"x"}"#,
            #"{"op":"log","session":"free","kind":"action","text":"fine"}"#,
            #"{"op":"log","session":"chat-1","kind":"action","text":"x"}"#,
            #"{"op":"update","session":"chat-1","state":"error"}"#,
            #"{"op":"end","session":"chat-1"}"#,
            #"{"op":"remove","session":"chat-1"}"#,
            #"{"op":"ask","session":"chat-1","type":"info","text":"t"}"#,
            #"{"op":"payload","adapter":"genericCLI","payload":{"session":"chat-1","state":"done"}}"#,
            #"{"op":"payload","adapter":"genericCLI","payload":{"session":"free","log":{"kind":"answer","text":"You: x"}}}"#,
        ]
        var replies: [String] = []
        for l in lines {
            let withTok = l.replacingOccurrences(of: "{", with: "{\"token\":\"\(tok)\",", options: [], range: l.startIndex..<l.index(after: l.startIndex))
            let r = await detached { () -> String? in
                guard let c = RawClient(path: path) else { return nil }
                defer { c.close_() }
                c.send(withTok + "\n"); return c.readLine()
            }
            replies.append(r ?? "nil")
        }
        XCTAssertEqual(replies[0], #"{"error":"kind not allowed","ok":false}"#)
        XCTAssertEqual(replies[1], #"{"error":"kind not allowed","ok":false}"#)
        XCTAssertEqual(replies[2], #"{"ok":true}"#)
        for i in 3...8 { XCTAssertEqual(replies[i], #"{"error":"session reserved","ok":false}"#, lines[i]) }
        XCTAssertEqual(replies[9], #"{"error":"invalid payload","ok":false}"#)
        let chat = store.sessions.first { $0.id == "chat-1" }
        XCTAssertEqual(chat?.state, .idle); XCTAssertEqual(chat?.history.count, 0)
        store.remove(sessionId: "chat-1")
        XCTAssertFalse(store.isChatOwned("chat-1"))
    }
}
