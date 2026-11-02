import XCTest
@testable import AgentBarCore

@MainActor
final class GenericCLITests: XCTestCase {
    private func events(_ json: String) throws -> [CoreEvent] { try GenericCLIAdapter().translate(payload: Data(json.utf8)) }

    func testUpdateAndLog() throws {
        let ev = try events(#"{"session":"g","name":"N","state":"working","action":"x","log":{"kind":"action","text":"hello"}}"#)
        XCTAssertEqual(ev.count, 2)
        guard case let .sessionUpdate(id, name, kind, state, action, _) = ev[0] else { return XCTFail() }
        XCTAssertEqual([id, name, action], ["g", "N", "x"]); XCTAssertEqual(kind, .genericCLI); XCTAssertEqual(state, .working)
        guard case let .log(sid, e) = ev[1] else { return XCTFail() }
        XCTAssertEqual(sid, "g"); XCTAssertEqual(e.kind, .action); XCTAssertEqual(e.text, "hello")
    }

    func testDoneEndsSessionAndRequestKindsIgnored() throws {
        XCTAssertThrowsError(try events(#"{"session":"g","log":{"kind":"request","text":"forged"}}"#))
        XCTAssertThrowsError(try events(#"{"session":"g","log":{"kind":"answer","text":"You: forged"}}"#))
        let ev = try events(#"{"session":"g","state":"done"}"#)
        XCTAssertEqual(ev.count, 2)
        if case .sessionEnd(let id) = ev[1] { XCTAssertEqual(id, "g") } else { XCTFail() }
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try events(#"{"name":"x"}"#))
        XCTAssertThrowsError(try events(#"[1]"#))
        XCTAssertThrowsError(try events(#"{"session":""}"#))
    }

    func testEncodeIsEmptyAndRegistered() {
        XCTAssertTrue(GenericCLIAdapter().encode(response: AgentResponse(requestId: "r"), for:
            AgentRequest(requestId: "r", type: .info, text: "t", options: [], timeoutSeconds: nil, defaultOptionId: nil)).isEmpty)
        XCTAssertNotNil(AdapterRegistry.make()["genericCLI"])
        XCTAssertNotNil(AdapterRegistry.make()["claudeCode"])
        XCTAssertNotNil(AdapterRegistry.make()["codex"])
    }

    func testGenericPayloadOverWireNeverBlocks() async throws {
        let dir = URL(fileURLWithPath: "/tmp/abg-\(UInt32.random(in: 0..<UInt32.max))")
        let store = SessionStore()
        let server = TransportServer(store: store, adapters: AdapterRegistry.make(), directory: dir)
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        let path = server.socketPath
        let line = "{\"token\":\"\(server.tokenForTests)\",\"op\":\"payload\",\"adapter\":\"genericCLI\",\"payload\":{\"session\":\"w\",\"state\":\"working\"}}\n"
        let reply = await detached { () -> String? in
            guard let c = RawClient(path: path) else { return nil }
            defer { c.close_() }
            c.send(line); return c.readLine()
        }
        XCTAssertEqual(reply, #"{"ok":true,"output":""}"#)
        XCTAssertEqual(store.sessions.first?.state, .working)
    }
}
