import XCTest
@testable import AgentBarCore

/// Fixtures built from the documented Codex hook structure. UNVERIFIED against a real Codex.
final class CodexAdapterTests: XCTestCase {
    let a = CodexAdapter()
    func payload(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
    func base(_ ev: String) -> [String: Any] {
        ["session_id": "cx-1", "cwd": "/tmp/proj", "hook_event_name": ev, "model": "gpt-x", "turn_id": "t1",
         "transcript_path": NSNull(), "permission_mode": "default"]
    }
    func ask(_ events: [CoreEvent]) -> AgentRequest? {
        for e in events { if case let .ask(_, r) = e { return r } }
        return nil
    }

    func testPermissionRequestAllowDeny() throws {
        var p = base("PermissionRequest"); p["tool_name"] = "Bash"
        p["tool_input"] = ["command": "rm -rf build", "description": NSNull()]
        let ev = try a.translate(payload: payload(p))
        let r = try XCTUnwrap(ask(ev))
        XCTAssertEqual(r.options.map(\.id), ["allow", "deny"])
        XCTAssertEqual(r.text, "Allow Bash? Project: proj\ncwd: /tmp/proj\ncommand: rm -rf build\ndescription: null")
        if case let .sessionUpdate(_, _, kind, _, _, _) = ev[0] { XCTAssertEqual(kind, .codex) } else { XCTFail() }
        XCTAssertEqual(String(decoding: a.encode(response: AgentResponse(requestId: r.requestId, optionId: "allow"), for: r), as: UTF8.self),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        XCTAssertEqual(String(decoding: a.encode(response: AgentResponse(requestId: r.requestId, optionId: "deny"), for: r), as: UTF8.self),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"Denied via AgentBar"},"hookEventName":"PermissionRequest"}}"#)
    }

    func testNoAlwaysAndUnsafeAnswersAreEmpty() throws {
        var p = base("PermissionRequest"); p["tool_name"] = "Bash"; p["tool_input"] = ["command": "ls"]
        p["permission_suggestions"] = [["type": "addRules"]]
        let r = try XCTUnwrap(ask(try a.translate(payload: payload(p))))
        XCTAssertFalse(r.options.contains { $0.id == "always" })
        XCTAssertTrue(a.encode(response: AgentResponse(requestId: r.requestId, optionId: "always"), for: r).isEmpty)
        XCTAssertTrue(a.encode(response: AgentResponse(requestId: r.requestId, optionId: "bogus"), for: r).isEmpty)
        XCTAssertTrue(a.encode(response: AgentResponse(requestId: r.requestId, optionId: "allow", reason: .timeout), for: r).isEmpty)
        XCTAssertTrue(a.encode(response: AgentResponse(requestId: r.requestId, optionId: nil, reason: .cancelled), for: r).isEmpty)
    }

    func testTooLongOrMissingInputGivesNoRequest() throws {
        var p = base("PermissionRequest"); p["tool_name"] = "apply_patch"
        p["tool_input"] = ["command": String(repeating: "x", count: 5000)]
        var ev = try a.translate(payload: payload(p))
        XCTAssertNil(ask(ev)); XCTAssertEqual(ev.count, 2)
        p["tool_input"] = "just a string"
        ev = try a.translate(payload: payload(p))
        XCTAssertNil(ask(ev))
        p.removeValue(forKey: "tool_input")
        XCTAssertNil(ask(try a.translate(payload: payload(p))))
    }

    func testLifecycleEvents() throws {
        var ev = try a.translate(payload: payload(base("SessionStart")))
        if case let .sessionUpdate(id, name, kind, state, _, _) = ev[0] { XCTAssertEqual(id, "cx-1"); XCTAssertEqual(name, "proj"); XCTAssertEqual(kind, .codex); XCTAssertEqual(state, .idle) } else { XCTFail() }
        ev = try a.translate(payload: payload(base("UserPromptSubmit")))
        if case let .sessionUpdate(_, _, _, state, _, _) = ev[0] { XCTAssertEqual(state, .working) } else { XCTFail() }
        var pre = base("PreToolUse"); pre["tool_name"] = "Bash"; pre["tool_input"] = ["command": "swift test"]
        ev = try a.translate(payload: payload(pre))
        if case let .sessionUpdate(_, _, _, _, action, _) = ev[0] { XCTAssertEqual(action, "Bash: swift test") } else { XCTFail() }
        var stop = base("Stop"); stop["last_assistant_message"] = NSNull(); stop["stop_hook_active"] = false
        ev = try a.translate(payload: payload(stop))
        if case let .sessionUpdate(_, _, _, state, _, _) = ev[0] { XCTAssertEqual(state, .done) } else { XCTFail() }
        ev = try a.translate(payload: payload(base("SessionEnd")))
        if case .sessionEnd(let id) = ev[0] { XCTAssertEqual(id, "cx-1") } else { XCTFail() }
        ev = try a.translate(payload: payload(base("Interrupt")))
        if case let .sessionUpdate(_, _, _, state, _, _) = ev[0] { XCTAssertEqual(state, .idle) } else { XCTFail() }
    }

    func testToleranceUnknownEventsFieldsAndGarbage() throws {
        XCTAssertTrue(try a.translate(payload: payload(base("PostToolUse"))).isEmpty)
        XCTAssertTrue(try a.translate(payload: payload(base("SomethingNew"))).isEmpty)
        var p = base("SessionStart"); p["brand_new_field"] = ["x": 1]
        XCTAssertEqual(try a.translate(payload: payload(p)).count, 1)
        XCTAssertThrowsError(try a.translate(payload: Data("nope".utf8)))
        XCTAssertThrowsError(try a.translate(payload: payload(["foo": 1])))
        var noSid = base("SessionStart"); noSid.removeValue(forKey: "session_id")
        XCTAssertThrowsError(try a.translate(payload: payload(noSid)))
        XCTAssertThrowsError(try a.translate(payload: Data(count: CodexAdapter.maxPayloadBytes + 1)))
    }

    func testNotifyPayload() throws {
        let n: [String: Any] = ["type": "agent-turn-complete", "thread-id": "th-9", "turn-id": "t", "cwd": "/a/b",
                                "input-messages": ["hi"], "last-assistant-message": "All done"]
        let ev = try a.translate(payload: payload(n))
        XCTAssertEqual(ev.count, 2)
        if case let .sessionUpdate(id, name, kind, state, _, _) = ev[0] { XCTAssertEqual(id, "th-9"); XCTAssertEqual(name, "b"); XCTAssertEqual(kind, .codex); XCTAssertEqual(state, .done) } else { XCTFail() }
        XCTAssertTrue(try a.translate(payload: payload(["type": "other"])).isEmpty)
    }

    func testSanitizesHostileInput() throws {
        var p = base("PermissionRequest"); p["tool_name"] = "Bash"
        p["tool_input"] = ["command": "echo hi\u{202E}\nrm -rf /"]
        let r = try XCTUnwrap(ask(try a.translate(payload: payload(p))))
        XCTAssertFalse(r.text.contains("\u{202E}"))
        XCTAssertTrue(r.text.contains("command: echo hi\u{FFFD}\n  rm -rf /"))
    }
}
