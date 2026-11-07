import XCTest
@testable import AgentBarCore

/// "Continue in panel": argument building for `--resume <id> --fork-session`, strict id validation, the fork note
/// and the working directory carried from hook payloads. No real claude is started.
@MainActor
final class ChatResumeTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("abresume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func config(resume: ChatResume?) -> ChatConfig {
        ChatConfig(executable: URL(fileURLWithPath: "/bin/echo"), workingDirectory: dir, sessionId: "c1", resume: resume)
    }

    func testArgumentsWithoutResumeUnchanged() throws {
        let args = try config(resume: nil).launchSpec(environment: [:]).arguments
        XCTAssertEqual(args, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"])
        XCTAssertFalse(args.contains("--resume")); XCTAssertFalse(args.contains("--fork-session"))
    }

    func testArgumentsWithResumeAlwaysFork() throws {
        let id = "3f2b8c1e-5a4d-4e6f-9a0b-1c2d3e4f5a6b"
        let spec = try config(resume: ChatResume(sessionId: id)).launchSpec(environment: [:])
        XCTAssertEqual(spec.arguments, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                        "--resume", id, "--fork-session"])
        XCTAssertEqual(spec.workingDirectory.path, dir.standardizedFileURL.path)
    }

    func testInvalidIdsRejected() {
        let bad = ["", "-x", "--dangerous", "a b", "a;rm -rf /", "a$(id)", "a`id`", "a\nb", "a/b", "a..b/c", "ä", "x\u{0}y",
                   String(repeating: "a", count: ChatResume.maxIdLength + 1), "a_b", "a.b"]
        for id in bad {
            XCTAssertFalse(ChatResume.isValidSessionId(id), "should reject \(id.debugDescription)")
            XCTAssertThrowsError(try config(resume: ChatResume(sessionId: id)).launchSpec(environment: [:]), id.debugDescription)
        }
        XCTAssertTrue(ChatResume.isValidSessionId(String(repeating: "a", count: ChatResume.maxIdLength)))
        XCTAssertTrue(ChatResume.isValidSessionId("abc-DEF-123"))
    }

    func testResumeWithoutForkRejected() {
        XCTAssertThrowsError(try config(resume: ChatResume(sessionId: "abc", fork: false)).launchSpec(environment: [:]))
    }

    func testResumeRejectedForAgentHost() {
        var c = ChatConfig.remote(workspace: "proj")
        c.resume = ChatResume(sessionId: "abc")
        XCTAssertThrowsError(try c.launchSpec(environment: [:]))
    }

    func testForkSessionLogsNoteAndPassesArgs() throws {
        let fake = FakeChatProcess()
        let captured = Box<[String]>([])
        let store = SessionStore()
        var cfg = config(resume: ChatResume(sessionId: "abc-123", sourceName: "notchy-app"))
        cfg.name = "notchy-app (fork)"
        let chat = ChatSession(config: cfg, store: store, processFactory: { spec in captured.set(spec.arguments); return fake },
                               environment: [:], deliver: { $0() })
        try chat.start()
        XCTAssertEqual(Array(captured.get.suffix(3)), ["--resume", "abc-123", "--fork-session"])
        let s = store.sessions.first { $0.id == "c1" }!
        XCTAssertEqual(s.name, "notchy-app (fork)")
        XCTAssertTrue(s.history.contains { $0.kind == .status && $0.text == "Forked from notchy-app" })
        chat.stop()
    }

    func testInvalidResumeFailsStartWithoutProcess() {
        let store = SessionStore()
        let spawned = Box(0)
        let chat = ChatSession(config: config(resume: ChatResume(sessionId: "bad id")), store: store,
                               processFactory: { _ in spawned.mutate { $0 += 1 }; return FakeChatProcess() },
                               environment: [:], deliver: { $0() })
        XCTAssertThrowsError(try chat.start())
        XCTAssertEqual(spawned.get, 0)
        XCTAssertFalse(store.isChatOwned("c1"))
    }

    // MARK: working directory from hooks

    func testHookCarriesWorkingDirectory() throws {
        let adapter = ClaudeCodeAdapter()
        let store = SessionStore()
        let p = try JSONSerialization.data(withJSONObject: ["hook_event_name": "UserPromptSubmit", "session_id": "s-1",
                                                            "cwd": "/Users/me/proj", "prompt": "hi"])
        for e in try adapter.translate(payload: p) + adapter.metadataEvents(payload: p) { store.apply(e) }
        XCTAssertEqual(store.sessions.first?.workingDirectory, "/Users/me/proj")
        XCTAssertEqual(store.sessions.first?.name, "proj")
    }

    func testHostileDirectoriesIgnored() {
        let store = SessionStore()
        store.apply(.sessionUpdate(id: "s", name: "x", kind: .claudeCode, state: .idle, action: nil, supportsStop: nil))
        for bad in ["relative/path", "/a/../etc", "/a\nb", "/a\u{0}b", "", String(repeating: "/a", count: 600)] {
            store.apply(.sessionDirectory(id: "s", path: bad))
            XCTAssertNil(store.sessions.first?.workingDirectory, bad.debugDescription)
        }
        store.apply(.sessionDirectory(id: "s", path: "/ok/dir"))
        XCTAssertEqual(store.sessions.first?.workingDirectory, "/ok/dir")
    }

    func testSessionEndCarriesNoDirectory() throws {
        let p = try JSONSerialization.data(withJSONObject: ["hook_event_name": "SessionEnd", "session_id": "s-1", "cwd": "/x"])
        XCTAssertTrue(ClaudeCodeAdapter().metadataEvents(payload: p).isEmpty)
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var get: T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}
