import XCTest
@testable import AgentBarCore

/// Logs every raw hook payload (one JSON per line) before delegating to the real adapter.
final class LoggingAdapter: AgentAdapter, @unchecked Sendable {
    let inner = ClaudeCodeAdapter()
    let logURL: URL
    private let lock = NSLock()
    init(logURL: URL) { self.logURL = logURL }
    var kind: AgentKind { inner.kind }
    func translate(payload: Data) throws -> [CoreEvent] {
        lock.lock()
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(payload); h.write(Data("\n".utf8)); try? h.close() }
        lock.unlock()
        return try inner.translate(payload: payload)
    }
    func encode(response: AgentResponse, for request: AgentRequest) -> Data {
        let d = inner.encode(response: response, for: request)
        lock.lock()
        let line = "ENCODE option=\(response.optionId ?? "nil") reason=\(response.reason.rawValue) -> \(String(decoding: d, as: UTF8.self))\n"
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        lock.unlock()
        return d
    }
}

@MainActor
final class ClaudeCodeEndToEndTests: XCTestCase {
    var dir: URL!
    var store: SessionStore!
    var server: TransportServer!
    var logURL: URL!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: "/tmp/abe2e-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("payloads.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        store = SessionStore()
        server = TransportServer(store: store, adapters: ["claudeCode": LoggingAdapter(logURL: logURL)],
                                 directory: dir.appendingPathComponent("ab"))
        try server.start()
    }
    override func tearDown() async throws { server.stop(); try? FileManager.default.removeItem(at: dir) }

    var cliURL: URL? {
        let u = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("agentbar")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    /// Runs a process on its own thread; returns (exit code, stdout).
    func runProcess(_ exe: URL, args: [String], stdin: Data?, env: [String: String], cwd: URL? = nil,
                    timeout: TimeInterval = 30) async -> (Int32, String, String) {
        await withCheckedContinuation { cont in
            Thread {
                let p = Process(); p.executableURL = exe; p.arguments = args
                var e = ProcessInfo.processInfo.environment; env.forEach { e[$0] = $1 }; p.environment = e
                if let cwd { p.currentDirectoryURL = cwd }
                let i = Pipe(), o = Pipe(), er = Pipe()
                p.standardInput = i; p.standardOutput = o; p.standardError = er
                do { try p.run() } catch { cont.resume(returning: (-1, "", "\(error)")); return }
                if let stdin { i.fileHandleForWriting.write(stdin) }
                try? i.fileHandleForWriting.close()
                let killer = DispatchWorkItem { p.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let out = o.fileHandleForReading.readDataToEndOfFile()
                let err = er.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); killer.cancel()
                cont.resume(returning: (p.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self)))
            }.start()
        }
    }

    /// Answers pending requests according to `policy` ("allow", "deny", "always", "timeout", "hold").
    func startResponder(policy: String) -> Task<Void, Never> {
        Task { @MainActor [store] in
            guard let store else { return }
            while !Task.isCancelled {
                for s in store.sessions {
                    for r in s.pendingRequests where policy != "hold" {
                        let resp = policy == "timeout"
                            ? AgentResponse(requestId: r.requestId, reason: .timeout)
                            : AgentResponse(requestId: r.requestId, optionId: policy)
                        store.respond(resp, sessionId: s.id)
                    }
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    func fixture(_ extra: [String: Any] = [:]) -> Data {
        var p: [String: Any] = ["session_id": "e2e-1", "cwd": "/tmp/proj", "hook_event_name": "PermissionRequest",
                                "permission_mode": "default", "tool_name": "Write",
                                "tool_input": ["file_path": "/tmp/proj/hello.txt", "content": "hi"],
                                "permission_suggestions": [["type": "addRules", "behavior": "allow", "destination": "localSettings",
                                                            "rules": [["toolName": "Write"]]]]]
        extra.forEach { p[$0] = $1 }
        return try! JSONSerialization.data(withJSONObject: p)
    }

    func hook(_ payload: Data) async -> (Int32, String, String) {
        await runProcess(cliURL!, args: ["hook", "--adapter", "claudeCode"], stdin: payload,
                         env: ["AGENTBAR_DIR": server.directory.path], timeout: 20)
    }

    func decision(_ out: String) -> [String: Any]? {
        guard let o = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let h = o["hookSpecificOutput"] as? [String: Any] else { return nil }
        return h["decision"] as? [String: Any]
    }

    // MARK: fixture-driven end to end (real server + real adapter + real `agentbar hook` process)

    func testHookProcessAllowDenyAlwaysTimeout() async throws {
        try XCTSkipIf(cliURL == nil, "agentbar binary not built next to the test bundle")
        for (policy, expect) in [("allow", "allow"), ("deny", "deny"), ("always", "allow")] {
            let r = startResponder(policy: policy)
            let (rc, out, _) = await hook(fixture())
            r.cancel()
            XCTAssertEqual(rc, 0)
            let d = try XCTUnwrap(decision(out), "policy \(policy) output: \(out)")
            XCTAssertEqual(d["behavior"] as? String, expect)
            if policy == "always" { XCTAssertNotNil(d["updatedPermissions"]) } else { XCTAssertNil(d["updatedPermissions"]) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let r = startResponder(policy: "timeout")
        let (rc, out, _) = await hook(fixture())
        r.cancel()
        XCTAssertEqual(rc, 0); XCTAssertEqual(out, "", "timeout must produce empty output (Claude's own dialog)")
    }

    /// Truncated / unrenderable input: the hook answer must be EMPTY (Claude's own dialog), no request is created,
    /// the session only flags attention. Must never be an allow.
    func testTruncatedInputGivesEmptyHookOutputAndNoRequest() async throws {
        try XCTSkipIf(cliURL == nil, "agentbar binary not built next to the test bundle")
        let r = startResponder(policy: "allow")   // would allow anything that is offered
        defer { r.cancel() }
        let long = ["command": String(repeating: "echo safe; ", count: 600) + "rm -rf ~"]
        let zalgo = ["command": "r" + String(repeating: "\u{0301}", count: 5) + "m -rf ~"]
        for input in [long as Any, [String: Any](), zalgo] {
            let (rc, out, _) = await hook(fixture(["tool_name": "Bash", "tool_input": input]))
            XCTAssertEqual(rc, 0); XCTAssertEqual(out, "", "no decision for non-displayable input")
            let s = try XCTUnwrap(store.sessions.first { $0.id == "e2e-1" })
            XCTAssertTrue(s.pendingRequests.isEmpty)
            XCTAssertEqual(s.state, .needsInput)
            XCTAssertTrue(s.currentAction?.contains("truncated, check in terminal") ?? false)
            XCTAssertFalse(s.history.contains { $0.kind == .request })
        }
        // sanity: a displayable input is still answered
        let (_, ok, _) = await hook(fixture())
        XCTAssertNotNil(decision(ok))
    }

    func testNonBlockingEventsReturnEmptyAndUpdateStore() async throws {
        try XCTSkipIf(cliURL == nil, "agentbar binary not built next to the test bundle")
        let (rc, out, _) = await hook(fixture(["hook_event_name": "PreToolUse", "tool_name": "Bash",
                                               "tool_input": ["command": "npm test"], "tool_use_id": "t1"]))
        XCTAssertEqual(rc, 0); XCTAssertEqual(out, "")
        let s = try XCTUnwrap(store.sessions.first { $0.id == "e2e-1" })
        XCTAssertEqual(s.state, .working); XCTAssertEqual(s.currentAction, "Bash: npm test"); XCTAssertEqual(s.name, "proj")
        let (rc2, out2, _) = await hook(fixture(["hook_event_name": "SessionEnd"]))
        XCTAssertEqual(rc2, 0); XCTAssertEqual(out2, "")
        XCTAssertEqual(store.sessions.first { $0.id == "e2e-1" }?.state, .done)   // store keeps ended sessions as done
    }

    // MARK: real Claude Code run (opt-in). AB_REAL_CLAUDE=<allow|deny|always|timeout> AB_REAL_OUT=<scratch dir>

    func testRealClaudeRun() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let policy = env["AB_REAL_CLAUDE"], let outDirPath = env["AB_REAL_OUT"] else { throw XCTSkip("opt-in only") }
        let cli = try XCTUnwrap(cliURL)
        let outDir = URL(fileURLWithPath: outDirPath).appendingPathComponent("run-\(policy)")
        let work = outDir.appendingPathComponent("work")
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // Settings generated with HookSetup against a temp file; ~/.claude is never touched.
        let settings = outDir.appendingPathComponent("settings.json")
        let setup = HookSetup(settingsURL: settings, agentbarPath: cli.path)
        try setup.apply(try setup.planInstall(), confirm: { _ in true })

        let r = startResponder(policy: policy)
        let claude = URL(fileURLWithPath: env["AB_CLAUDE_BIN"] ?? (NSHomeDirectory() + "/.local/bin/claude"))
        let prompt = "Use the Write tool to create a file named hello.txt in the current directory containing exactly: hi. Then reply with the single word done."
        let (rc, out, err) = await runProcess(claude,
            args: ["-p", prompt, "--settings", settings.path, "--setting-sources", "project", "--tools", "Write",
                   "--permission-mode", "default", "--model", "haiku", "--max-budget-usd", "0.5", "--no-session-persistence"],
            stdin: nil, env: ["AGENTBAR_DIR": server.directory.path], cwd: work, timeout: 150)
        r.cancel()
        let fileExists = FileManager.default.fileExists(atPath: work.appendingPathComponent("hello.txt").path)
        let summary = "policy=\(policy)\nexit=\(rc)\nhello.txt exists=\(fileExists)\n--- stdout ---\n\(out)\n--- stderr ---\n\(err)\n"
        try summary.write(to: outDir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: logURL, to: outDir.appendingPathComponent("payloads.log"))
        print("REAL RUN DONE policy=\(policy) exit=\(rc) file=\(fileExists)")
    }
}
