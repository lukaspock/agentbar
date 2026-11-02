import XCTest
@testable import AgentBarCore

/// Scripted stand-in for the claude process. Fixtures are UNVERIFIED (derived from docs + binary field names).
final class FakeChatProcess: ChatProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var _written: [Data] = []
    private var _terminated = 0, _killed = 0
    var onLine: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?
    var onStderr: (@Sendable (Data) -> Void)?
    var failStart = false
    func start(onLine: @escaping @Sendable (Data) -> Void, onStderr: @escaping @Sendable (Data) -> Void,
               onExit: @escaping @Sendable (Int32) -> Void) throws {
        if failStart { throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]) }
        self.onLine = onLine; self.onStderr = onStderr; self.onExit = onExit
    }
    func write(line: Data) { lock.lock(); _written.append(line); lock.unlock() }
    func terminate() { lock.lock(); _terminated += 1; lock.unlock() }
    func kill() { lock.lock(); _killed += 1; lock.unlock() }
    var written: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return _written.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
    var terminated: Int { lock.lock(); defer { lock.unlock() }; return _terminated }
    var killed: Int { lock.lock(); defer { lock.unlock() }; return _killed }
    func emit(_ json: String) { onLine?(Data(json.utf8)) }
}

@MainActor
final class ChatSessionTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("abchat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func make(idle: TimeInterval? = nil, check: TimeInterval = 0.02, grace: TimeInterval = 0.05,
              clock: @escaping @MainActor () -> Date = { Date() }, failStart: Bool = false)
        -> (ChatSession, SessionStore, FakeChatProcess) {
        let fake = FakeChatProcess(); fake.failStart = failStart
        let store = SessionStore()
        let cfg = ChatConfig(executable: URL(fileURLWithPath: "/bin/echo"), workingDirectory: dir, sessionId: "c1",
                             idleTimeout: idle, idleCheckInterval: check, killGrace: grace)
        let s = ChatSession(config: cfg, store: store, processFactory: { _ in fake }, environment: [:], clock: clock,
                            deliver: { work in work() })
        return (s, store, fake)
    }
    func session(_ store: SessionStore) -> AgentSession { store.sessions.first { $0.id == "c1" }! }

    let permission = #"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm -rf build","description":"clean"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm -rf build"}],"behavior":"allow","destination":"localSettings"}],"tool_use_id":"tu1"}}"#

    // MARK: wire

    func testParseAssistantResultInit() {
        let a = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hi"},{"type":"tool_use","id":"t","name":"Read","input":{"file_path":"/x"}}]},"session_id":"s"}"#
        let parts = ChatWire.assistantParts(line: Data(a.utf8))
        XCTAssertEqual(parts.count, 2)
        if case let .result(e, st, t)? = ChatWire.parse(line: Data(#"{"type":"result","subtype":"success","is_error":false,"result":"done"}"#.utf8)) {
            XCTAssertFalse(e); XCTAssertEqual(st, "success"); XCTAssertEqual(t, "done")
        } else { XCTFail() }
        XCTAssertNil(ChatWire.parse(line: Data("garbage".utf8)))
        // sub-agent assistant messages are not shown as the main agent's text
        let sub = #"{"type":"assistant","parent_tool_use_id":"x","message":{"content":[{"type":"text","text":"hidden"}]}}"#
        XCTAssertTrue(ChatWire.assistantParts(line: Data(sub.utf8)).isEmpty)
    }

    func testEncoders() throws {
        let u = try JSONSerialization.jsonObject(with: ChatWire.userMessage("hi \"x\"\n")) as! [String: Any]
        XCTAssertEqual(u["type"] as? String, "user")
        XCTAssertEqual((u["message"] as? [String: Any])?["content"] as? String, "hi \"x\"\n")
        let allowData = ChatWire.allow(requestId: "r", updatedInput: ["a": 1])
        XCTAssertFalse(allowData.contains(0x0A), "one JSON object per line")
        let d = try JSONSerialization.jsonObject(with: ChatWire.deny(requestId: "r", message: "no")) as! [String: Any]
        let resp = d["response"] as! [String: Any]
        XCTAssertEqual(d["type"] as? String, "control_response")
        XCTAssertEqual(resp["request_id"] as? String, "r")
        XCTAssertEqual((resp["response"] as? [String: Any])?["behavior"] as? String, "deny")
    }

    // MARK: config

    func testLaunchSpecArgsAndMinimalEnv() throws {
        let cfg = ChatConfig(executable: URL(fileURLWithPath: "/bin/echo"), workingDirectory: dir, model: "haiku",
                             maxBudgetUSD: 0.5, tools: ["Read", "Grep"], permissionMode: .plan,
                             extraEnvironment: ["AB": "1"])
        let spec = try cfg.launchSpec(environment: ["PATH": "/usr/bin", "SECRET_TOKEN": "x", "AWS_SECRET_ACCESS_KEY": "y", "HOME": "/h"])
        XCTAssertEqual(Array(spec.arguments.prefix(6)), ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"])
        XCTAssertTrue(spec.arguments.contains("--model")); XCTAssertTrue(spec.arguments.contains("Read,Grep"))
        XCTAssertEqual(spec.environment, ["PATH": "/usr/bin", "HOME": "/h", "AB": "1"])
        XCTAssertEqual(spec.workingDirectory.path, dir.standardizedFileURL.path)
        XCTAssertFalse(spec.arguments.contains("--dangerously-skip-permissions"))
    }

    func testLaunchSpecRejectsBadInput() {
        let exe = URL(fileURLWithPath: "/bin/echo")
        func bad(_ c: ChatConfig, line: UInt = #line) { XCTAssertThrowsError(try c.launchSpec(environment: [:]), line: line) }
        bad(ChatConfig(executable: exe, workingDirectory: URL(fileURLWithPath: "/")))
        bad(ChatConfig(executable: exe, workingDirectory: dir.appendingPathComponent("missing")))
        bad(ChatConfig(executable: URL(fileURLWithPath: "/nonexistent/claude"), workingDirectory: dir))
        bad(ChatConfig(executable: exe, workingDirectory: dir, model: "--dangerously-skip-permissions"))
        bad(ChatConfig(executable: exe, workingDirectory: dir, tools: ["-x"]))
        bad(ChatConfig(executable: exe, workingDirectory: dir, maxBudgetUSD: -1))
    }

    // MARK: session flow

    func testSendTurnAndResult() throws {
        let (s, store, fake) = make()
        XCTAssertThrowsError(try s.send(text: "x"))  // not started
        try s.start()
        XCTAssertTrue(session(store).supportsStop)
        XCTAssertEqual(session(store).state, .idle)
        try s.send(text: "  hello  ")
        XCTAssertEqual(session(store).state, .working)
        let msg = fake.written.first!
        XCTAssertEqual((msg["message"] as? [String: Any])?["content"] as? String, "hello")
        XCTAssertThrowsError(try s.send(text: "   ")) { XCTAssertEqual($0 as? ChatError, .emptyText) }
        fake.emit(#"{"type":"system","subtype":"init","session_id":"abc","model":"claude-x","tools":[]}"#)
        fake.emit(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Working on it"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#)
        XCTAssertEqual(session(store).currentAction, "Bash: ls")
        XCTAssertTrue(session(store).history.contains { $0.text == "Claude: Working on it" })
        fake.emit(#"{"type":"result","subtype":"success","is_error":false,"result":"All done"}"#)
        XCTAssertEqual(session(store).state, .idle)
        XCTAssertNil(session(store).currentAction)
    }

    func testResultErrorSetsErrorState() throws {
        let (s, store, fake) = make()
        try s.start(); try s.send(text: "go")
        fake.emit(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Failed to authenticate"}"#)
        XCTAssertEqual(session(store).state, .error)
        XCTAssertTrue(session(store).history.contains { $0.kind == .error && $0.text.contains("Failed to authenticate") })
        try s.send(text: "again")   // recoverable
        XCTAssertEqual(session(store).state, .working)
    }

    func testMalformedLineIsIgnored() throws {
        let (s, store, fake) = make()
        try s.start()
        fake.emit("not json at all")
        fake.emit(#"{"type":"stream_event","event":{}}"#)
        XCTAssertEqual(session(store).state, .idle)
        XCTAssertEqual(s.phase, .running)
    }

    // MARK: permissions

    func testApprovalAllowEchoesInputAndSecurityText() throws {
        let (s, store, fake) = make()
        try s.start(); try s.send(text: "clean")
        fake.emit(permission)
        let req = try XCTUnwrap(session(store).pendingRequests.first)
        XCTAssertEqual(session(store).state, .needsInput)
        XCTAssertTrue(req.text.hasPrefix("Allow Bash? Project:"))
        XCTAssertTrue(req.text.contains("command: rm -rf build"))
        XCTAssertEqual(req.options.map(\.id), ["allow", "deny", "always"])
        XCTAssertNil(req.defaultOptionId)
        store.respond(AgentResponse(requestId: req.requestId, optionId: "allow"), sessionId: "c1")
        let resp = try XCTUnwrap(fake.written.last?["response"] as? [String: Any])
        XCTAssertEqual(resp["request_id"] as? String, "r1")
        let inner = resp["response"] as! [String: Any]
        XCTAssertEqual(inner["behavior"] as? String, "allow")
        XCTAssertEqual((inner["updatedInput"] as? [String: Any])?["command"] as? String, "rm -rf build")
        XCTAssertNil(inner["updatedPermissions"])
        XCTAssertEqual(session(store).state, .working)
    }

    func testAlwaysDenyTextAndTimeout() throws {
        let (s, store, fake) = make()
        try s.start()
        fake.emit(permission)
        var req = session(store).pendingRequests[0]
        store.respond(AgentResponse(requestId: req.requestId, optionId: "always"), sessionId: "c1")
        var inner = (fake.written.last?["response"] as! [String: Any])["response"] as! [String: Any]
        XCTAssertEqual((inner["updatedPermissions"] as? [[String: Any]])?.first?["destination"] as? String, "localSettings")

        fake.emit(permission)
        req = session(store).pendingRequests[0]
        store.respond(AgentResponse(requestId: req.requestId, optionId: "deny"), sessionId: "c1")
        inner = (fake.written.last?["response"] as! [String: Any])["response"] as! [String: Any]
        XCTAssertEqual(inner["behavior"] as? String, "deny")

        fake.emit(permission)
        req = session(store).pendingRequests[0]
        store.respond(AgentResponse(requestId: req.requestId, text: "use git clean instead"), sessionId: "c1")
        inner = (fake.written.last?["response"] as! [String: Any])["response"] as! [String: Any]
        XCTAssertEqual(inner["behavior"] as? String, "deny")
        XCTAssertTrue((inner["message"] as? String ?? "").contains("git clean"))

        fake.emit(permission)
        req = session(store).pendingRequests[0]
        store.respond(AgentResponse(requestId: req.requestId, reason: .timeout), sessionId: "c1")
        inner = (fake.written.last?["response"] as! [String: Any])["response"] as! [String: Any]
        XCTAssertEqual(inner["behavior"] as? String, "deny")   // never auto-allow
    }

    func testNotFullyDisplayableApprovalIsDeniedWithoutRequest() throws {
        let (s, store, fake) = make()
        try s.start()
        let long = String(repeating: "A", count: 5000)
        fake.emit(#"{"type":"control_request","request_id":"r9","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"\#(long)"},"tool_use_id":"t"}}"#)
        XCTAssertTrue(session(store).pendingRequests.isEmpty, "no one-click allow when the input cannot be shown in full")
        let inner = (fake.written.last?["response"] as! [String: Any])["response"] as! [String: Any]
        XCTAssertEqual(inner["behavior"] as? String, "deny")
        XCTAssertTrue(session(store).currentAction?.contains("gekürzt") == true)
        // empty input is not renderable either
        fake.emit(#"{"type":"control_request","request_id":"r10","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{},"tool_use_id":"t"}}"#)
        XCTAssertTrue(session(store).pendingRequests.isEmpty)
        XCTAssertEqual(fake.written.count, 2)
    }

    func testControlCancelRemovesRequestWithoutReply() throws {
        let (s, store, fake) = make()
        try s.start()
        fake.emit(permission)
        XCTAssertEqual(session(store).pendingRequests.count, 1)
        fake.emit(#"{"type":"control_cancel_request","request_id":"r1"}"#)
        XCTAssertTrue(session(store).pendingRequests.isEmpty)
        XCTAssertTrue(fake.written.isEmpty)
    }

    func testAskUserQuestion() throws {
        let (s, store, fake) = make()
        try s.start()
        fake.emit(#"{"type":"control_request","request_id":"q1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which format?","header":"Format","options":[{"label":"Summary","description":"s"},{"label":"Detailed","description":"d"}],"multiSelect":false}]},"tool_use_id":"t"}}"#)
        let req = try XCTUnwrap(session(store).pendingRequests.first)
        XCTAssertEqual(req.type, .question)
        XCTAssertEqual(req.options.map(\.label), ["Summary", "Detailed"])
        store.respond(AgentResponse(requestId: req.requestId, optionId: req.options[1].id), sessionId: "c1")
        let inner = (fake.written.last?["response"] as! [String: Any])["response"] as! [String: Any]
        XCTAssertEqual(inner["behavior"] as? String, "allow")
        let upd = inner["updatedInput"] as! [String: Any]
        XCTAssertEqual((upd["answers"] as? [String: String])?["Which format?"], "Detailed")
        XCTAssertNotNil(upd["questions"])
        // multi-select is not supported: refused instead of shown wrongly
        fake.emit(#"{"type":"control_request","request_id":"q2","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"x","options":[{"label":"a"}],"multiSelect":true}]},"tool_use_id":"t"}}"#)
        XCTAssertTrue(session(store).pendingRequests.isEmpty)
    }

    // MARK: lifecycle

    func testStopIsImmediateAndKillsAfterGrace() async throws {
        let (s, store, fake) = make(grace: 0.05)
        try s.start()
        fake.emit(permission)
        XCTAssertEqual(session(store).pendingRequests.count, 1)
        s.stop()
        XCTAssertEqual(fake.terminated, 1, "SIGTERM synchronously")
        XCTAssertTrue(session(store).pendingRequests.isEmpty)
        let inner = (fake.written.last?["response"] as! [String: Any])["response"] as! [String: Any]
        XCTAssertEqual(inner["behavior"] as? String, "deny")
        XCTAssertFalse(session(store).supportsStop)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(fake.killed, 1, "SIGKILL after grace when the process does not exit")
        fake.onExit?(143)
        XCTAssertEqual(s.phase, .exited)
        XCTAssertEqual(session(store).state, .done)
        XCTAssertThrowsError(try s.send(text: "late"))
    }

    func testStopThenExitBeforeGraceDoesNotKill() async throws {
        let (s, _, fake) = make(grace: 0.1)
        try s.start()
        s.stop()
        fake.onExit?(143)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(fake.killed, 0)
        s.stop()  // no-op after exit
        XCTAssertEqual(fake.terminated, 1)
    }

    func testCrashExitSetsError() throws {
        let (s, store, fake) = make()
        try s.start()
        fake.onStderr?(Data("Failed to authenticate\n".utf8))
        fake.onExit?(1)
        XCTAssertEqual(session(store).state, .error)
        XCTAssertEqual(session(store).currentAction, "exit 1")
        XCTAssertTrue(session(store).history.contains { $0.kind == .error && $0.text.contains("authenticate") })
    }

    func testCleanExitEndsSession() throws {
        let (s, store, fake) = make()
        try s.start()
        fake.onExit?(0)
        XCTAssertEqual(session(store).state, .done)
    }

    func testSpawnFailure() {
        let (s, store, _) = make(failStart: true)
        XCTAssertThrowsError(try s.start())
        XCTAssertEqual(s.phase, .exited)
        XCTAssertEqual(session(store).state, .error)
    }

    func testIdleWatchdogKills() async throws {
        let (s, store, fake) = make(idle: 0.1, check: 0.02, grace: 0.05)
        try s.start(); try s.send(text: "go")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(fake.terminated, 1)
        XCTAssertEqual(fake.killed, 1)
        fake.onExit?(137)
        XCTAssertEqual(session(store).state, .error)
        XCTAssertEqual(session(store).currentAction, "timeout")
    }

    func testWatchdogPausedWhilePrompting() async throws {
        let (s, store, fake) = make(idle: 0.1, check: 0.02)
        try s.start(); try s.send(text: "go")
        fake.emit(permission)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(fake.terminated, 0)
        XCTAssertEqual(session(store).pendingRequests.count, 1)
        s.stop()
    }

    func testRemoveCancelsPromptWithDeny() throws {
        let (s, store, fake) = make()
        try s.start()
        fake.emit(permission)
        store.remove(sessionId: "c1")
        let inner = (fake.written.last?["response"] as! [String: Any])["response"] as! [String: Any]
        XCTAssertEqual(inner["behavior"] as? String, "deny")
        s.stop()
    }
}

// MARK: real process plumbing (harmless /bin/cat), and opt-in real claude

@MainActor
final class ChatProcessPlumbingTests: XCTestCase {
    func spec(_ exe: String, _ args: [String] = []) -> ChatLaunchSpec {
        ChatLaunchSpec(executable: URL(fileURLWithPath: exe), arguments: args,
                       workingDirectory: FileManager.default.temporaryDirectory, environment: ["PATH": "/usr/bin:/bin"])
    }

    func testCatEchoesLinesAndExitsOnTerminate() async throws {
        let p = PosixChatProcess(spec: spec("/bin/cat"))
        let lines = Box<[String]>([]), exit = Box<Int32?>(nil)
        try p.start(onLine: { d in lines.mutate { $0.append(String(decoding: d, as: UTF8.self)) } },
                    onStderr: { _ in }, onExit: { exit.set($0) })
        p.write(line: Data(#"{"a":1}"#.utf8)); p.write(line: Data("second".utf8))
        try await waitFor { lines.get.count == 2 }
        XCTAssertEqual(lines.get, [#"{"a":1}"#, "second"])
        p.terminate()
        try await waitFor { exit.get != nil }
        XCTAssertTrue([0, 143].contains(exit.get ?? -1))   // SIGTERM races with stdin EOF
    }

    func testKillStopsStubbornProcess() async throws {
        let p = PosixChatProcess(spec: spec("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 1; done"]))
        let exit = Box<Int32?>(nil)
        try p.start(onLine: { _ in }, onStderr: { _ in }, onExit: { exit.set($0) })
        try await Task.sleep(nanoseconds: 200_000_000)
        p.terminate()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(exit.get, "ignores SIGTERM")
        p.kill()
        try await waitFor { exit.get != nil }
        XCTAssertEqual(exit.get, 128 + 9)
    }

    func testMissingExecutableThrows() {
        let p = PosixChatProcess(spec: spec("/nonexistent/claude"))
        XCTAssertThrowsError(try p.start(onLine: { _ in }, onStderr: { _ in }, onExit: { _ in }))
    }

    /// Opt-in: AB_REAL_CLAUDE=1 starts the real claude (needs a valid login; costs a little).
    func testRealClaudeOneTurn() async throws {
        guard ProcessInfo.processInfo.environment["AB_REAL_CLAUDE"] != nil else { throw XCTSkip("set AB_REAL_CLAUDE=1 to run") }
        guard let exe = ChatConfig.locateClaude() else { throw XCTSkip("claude not found") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("abchat-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore()
        let cfg = ChatConfig(executable: exe, workingDirectory: dir, sessionId: "real", model: "haiku", maxBudgetUSD: 0.25,
                             tools: ["Read"], permissionMode: .dontAsk, idleTimeout: 90)
        let chat = ChatSession(config: cfg, store: store)
        try chat.start()
        try chat.send(text: "Reply with the single word: ok")
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, store.sessions.first?.history.contains(where: { $0.text.hasPrefix("Claude:") || $0.kind == .error }) != true {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let hist = store.sessions.first?.history.map { "\($0.kind.rawValue): \($0.text)" } ?? []
        chat.stop()
        print("REAL CLAUDE HISTORY:", hist)
        XCTAssertFalse(hist.isEmpty)
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var get: T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

@MainActor
private func waitFor(timeout: TimeInterval = 5, _ cond: @escaping @Sendable () -> Bool) async throws {
    let end = Date().addingTimeInterval(timeout)
    while !cond() { if Date() > end { XCTFail("timeout"); return }; try await Task.sleep(nanoseconds: 20_000_000) }
}
