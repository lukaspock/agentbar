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

// MARK: origin gate and directory vetting for "Continue in panel"

final class ContinueInPanelSecurityTests: XCTestCase {
    var base: URL!
    override func setUp() {
        let raw = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("abcip-\(UInt32.random(in: 0..<UInt32.max))")
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        base = URL(fileURLWithPath: String(cString: realpath(raw.path, nil)), isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    @MainActor func testAgentOriginNeverGetsDirectory() {
        let store = SessionStore()
        store.setOrigin(.agent, for: "s")
        store.apply(.sessionUpdate(id: "s", name: "x", kind: .claudeCode, state: .idle, action: nil, supportsStop: nil))
        store.apply(.sessionDirectory(id: "s", path: "/tmp/evil"))
        XCTAssertNil(store.sessions[0].workingDirectory)
        XCTAssertEqual(store.sessions[0].originRole, .agent)
        XCTAssertFalse(store.sessions[0].canContinueInPanel)
    }

    @MainActor func testOwnerOriginAllowsButUnknownDoesNot() {
        let store = SessionStore()
        store.setOrigin(.owner, for: "o-1")
        store.apply(.sessionUpdate(id: "o-1", name: "x", kind: .claudeCode, state: .idle, action: nil, supportsStop: nil))
        store.apply(.sessionDirectory(id: "o-1", path: "/tmp/ok"))
        func get(_ id: String) -> AgentSession { store.sessions.first { $0.id == id }! }
        XCTAssertTrue(get("o-1").canContinueInPanel)
        store.apply(.sessionUpdate(id: "u-1", name: "x", kind: .claudeCode, state: .idle, action: nil, supportsStop: nil))
        store.apply(.sessionDirectory(id: "u-1", path: "/tmp/ok"))
        XCTAssertNil(get("u-1").originRole)
        XCTAssertFalse(get("u-1").canContinueInPanel, "unknown origin: no button")
        store.setOrigin(.agent, for: "o-1")   // an agent claim never downgrades an owner session
        XCTAssertEqual(get("o-1").originRole, .owner)
    }

    func dir(_ name: String, mode: mode_t = 0o700) throws -> String {
        let d = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        chmod(d.path, mode)
        return d.path
    }

    func testResolveDirectoryRules() throws {
        let good = try dir("good")
        XCTAssertEqual(try ContinueInPanelCheck.resolveDirectory(good, forbiddenPrefixes: []).get(), good)
        XCTAssertNotNil(try? ContinueInPanelCheck.resolveDirectory(good, forbiddenPrefixes: []).get())
        for mode: mode_t in [0o770, 0o707, 0o777, 0o720] {
            let d = try dir("w\(mode)", mode: mode)
            XCTAssertThrowsError(try ContinueInPanelCheck.resolveDirectory(d, forbiddenPrefixes: []).get(), "mode \(String(mode, radix: 8))")
        }
        XCTAssertNotNil(try? ContinueInPanelCheck.resolveDirectory(try dir("ro", mode: 0o755), forbiddenPrefixes: []).get())
        XCTAssertThrowsError(try ContinueInPanelCheck.resolveDirectory(good + "/nope", forbiddenPrefixes: []).get())
        let file = base.appendingPathComponent("f"); FileManager.default.createFile(atPath: file.path, contents: Data())
        XCTAssertThrowsError(try ContinueInPanelCheck.resolveDirectory(file.path, forbiddenPrefixes: []).get())
        XCTAssertThrowsError(try ContinueInPanelCheck.resolveDirectory(good, ownerUid: geteuid() &+ 1, forbiddenPrefixes: []).get(), "foreign owner")
    }

    func testSymlinkIsResolvedAndForbiddenPrefixCaught() throws {
        let agentHome = try dir("agenthome")
        let proj = agentHome + "/proj"; try FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: proj)
        // The link itself lives outside the forbidden tree, its target does not.
        if case .success = ContinueInPanelCheck.resolveDirectory(link, forbiddenPrefixes: [agentHome]) { XCTFail("link into agent home accepted") }
        // Without the prefix the link resolves to the real path.
        XCTAssertEqual(try ContinueInPanelCheck.resolveDirectory(link, forbiddenPrefixes: []).get(), proj)
    }

    func testForbiddenPrefixMatching() {
        let f = ["/Users/agentbar", "/Users/Shared/AgentBar"]
        XCTAssertTrue(ContinueInPanelCheck.isInside("/Users/agentbar", anyOf: f))
        XCTAssertTrue(ContinueInPanelCheck.isInside("/Users/agentbar/work/x", anyOf: f))
        XCTAssertTrue(ContinueInPanelCheck.isInside("/users/AgentBar/work", anyOf: f), "case-insensitive volume")
        XCTAssertTrue(ContinueInPanelCheck.isInside("/Users/Shared/AgentBar/ws", anyOf: f))
        XCTAssertFalse(ContinueInPanelCheck.isInside("/Users/agentbar2/x", anyOf: f))
        XCTAssertFalse(ContinueInPanelCheck.isInside("/Users/me/agentbar", anyOf: f))
        XCTAssertTrue(ContinueInPanelCheck.defaultForbiddenPrefixes().contains("/Users/agentbar"))
    }

    func testTranscriptLookup() throws {
        let root = base.appendingPathComponent("projects")
        let cwd = "/Users/me/my.proj"
        XCTAssertEqual(ContinueInPanelCheck.encodedProjectName(cwd), "-Users-me-my-proj")
        XCTAssertFalse(ContinueInPanelCheck.transcriptExists(sessionId: "abc-1", directory: cwd, projectsRoot: root))
        let d = root.appendingPathComponent("-Users-me-my-proj"); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: d.appendingPathComponent("abc-1.jsonl").path, contents: Data())
        XCTAssertTrue(ContinueInPanelCheck.transcriptExists(sessionId: "abc-1", directory: cwd, projectsRoot: root))
        XCTAssertTrue(ContinueInPanelCheck.transcriptExists(sessionId: "abc-1", directory: "/elsewhere", projectsRoot: root), "glob fallback")
        XCTAssertFalse(ContinueInPanelCheck.transcriptExists(sessionId: "abc-2", directory: cwd, projectsRoot: root))
        XCTAssertFalse(ContinueInPanelCheck.transcriptExists(sessionId: "../x", directory: cwd, projectsRoot: root))
    }

    func testValidateGate() throws {
        let root = base.appendingPathComponent("projects")
        let cwd = try dir("work")
        let d = root.appendingPathComponent(ContinueInPanelCheck.encodedProjectName(cwd)); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: d.appendingPathComponent("sid-1.jsonl").path, contents: Data())
        func s(_ role: PeerRole?, id: String = "sid-1") -> AgentSession {
            AgentSession(id: id, name: "n", kind: .claudeCode, workingDirectory: cwd, originRole: role)
        }
        XCTAssertNotNil(try? ContinueInPanelCheck.validate(session: s(.owner), forbiddenPrefixes: [], projectsRoot: root).get())
        for bad in [s(.agent), s(nil), s(.owner, id: "sid-2")] {
            switch ContinueInPanelCheck.validate(session: bad, forbiddenPrefixes: [], projectsRoot: root) {
            case .success: XCTFail("accepted \(bad.id) \(String(describing: bad.originRole))")
            case .failure(let f): XCTAssertTrue(f.message.hasPrefix("Cannot continue: "))
            }
        }
    }
}
