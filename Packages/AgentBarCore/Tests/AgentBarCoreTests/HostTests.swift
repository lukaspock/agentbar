import XCTest
@testable import AgentBarCore

// MARK: helpers

final class HostCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = [], _stderr = Data(), _exits: [Int32] = []
    func line(_ d: Data) { lock.lock(); _lines.append(String(decoding: d, as: UTF8.self)); lock.unlock() }
    func err(_ d: Data) { lock.lock(); _stderr.append(d); lock.unlock() }
    func exit(_ s: Int32) { lock.lock(); _exits.append(s); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: _stderr, as: UTF8.self) }
    var exits: [Int32] { lock.lock(); defer { lock.unlock() }; return _exits }
}

final class HostFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
}

func hostWait(_ timeout: TimeInterval = 5, _ cond: @Sendable () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !cond() { if Date() > end { return false }; Thread.sleep(forTimeInterval: 0.01) }
    return true
}

/// Temp "agent home" with a work root and fake `claude` scripts. Everything runs as the test's own uid.
final class HostFixture: @unchecked Sendable {
    let base: URL, home: URL, work: URL, bin: URL
    var service: HostService!
    let client: HostClient
    private var fds: (Int32, Int32) = (-1, -1)
    let serviceDone = HostFlag(), clientDone = HostFlag()

    init(clientPing: TimeInterval = 0.2, clientDeadAfter: TimeInterval = 30) throws {
        let raw = URL(fileURLWithPath: "/tmp/abh-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        base = URL(fileURLWithPath: String(cString: realpath(raw.path, nil)))
        home = base.appendingPathComponent("home"); work = home.appendingPathComponent("work"); bin = base.appendingPathComponent("bin")
        for d in [home, bin] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        client = HostClient(pingInterval: clientPing, deadAfter: clientDeadAfter)
    }
    deinit { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    func script(_ name: String, _ body: String) throws -> URL {
        let u = bin.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
        chmod(u.path, 0o755)
        return u
    }
    func workspace(_ name: String) throws { try FileManager.default.createDirectory(at: work.appendingPathComponent(name), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }

    func config(claude: URL?, deadMan: TimeInterval = 20, grace: TimeInterval = 0.3, max: Int = 16) -> HostService.Config {
        HostService.Config(home: home, user: "tester", uid: geteuid(), claudeExecutable: claude, deadManSeconds: deadMan, killGrace: grace, maxProcesses: max)
    }

    /// socketpair: `client.serve` on one end, `service.run` on the other, each on its own thread.
    func link(_ service: HostService) {
        self.service = service
        let (a, b) = makePair()
        fds = (a, b)
        let c = client, s = service, sd = serviceDone, cd = clientDone
        Thread { _ = c.serve(fd: a, info: .init(user: "tester", uid: Int(geteuid()), workspaceRoot: "/x", agents: [:])); close(a); cd.set() }.start()
        Thread { s.run(fd: b); close(b); sd.set() }.start()
        XCTAssertTrue(hostWait { c.isConnected })
    }

    /// Simulates the app vanishing (crash): closes the client's end.
    func dropClientSide() { Darwin.shutdown(fds.0, SHUT_RDWR) }

    func spawn(_ ws: String, onSpawnLine: Bool = true) throws -> (RemoteChatProcess, HostCollector) {
        let cfg = ChatConfig.remote(workspace: ws)
        let spec = try cfg.launchSpec(environment: [:])
        let p = try client.processFactory(spec) as! RemoteChatProcess
        let col = HostCollector()
        try p.start(onLine: { col.line($0) }, onStderr: { col.err($0) }, onExit: { col.exit($0) })
        return (p, col)
    }
}

func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

func makePair() -> (Int32, Int32) {
    var sv: [Int32] = [-1, -1]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0)
    SocketIO.setNoSigPipe(sv[0]); SocketIO.setNoSigPipe(sv[1])
    return (sv[0], sv[1])
}

// MARK: protocol

final class HostProtocolTests: XCTestCase {
    func testCommandsRoundTrip() throws {
        let cmds: [HostCommand] = [
            .spawn(HostSpawnRequest(id: "p1", workspace: "proj", model: "haiku", maxBudgetUSD: 0.5, tools: ["Read"], permissionMode: "plan")),
            .spawn(HostSpawnRequest(id: "p2", workspace: "proj")),
            .stdin(id: "p1", line: #"{"a":"é\n"}"#), .terminate(id: "p1"), .kill(id: "p1"),
            .workspaces(rid: "r1"), .mkworkspace(rid: "r2", name: "new-1"), .ping,
        ]
        for c in cmds {
            let d = try HostProtocol.encode(c)
            XCTAssertFalse(d.contains(0x0A), "one line per frame")
            XCTAssertEqual(try HostProtocol.decodeCommand(d), c)
        }
    }

    func testEventsRoundTrip() throws {
        let evs: [HostEvent] = [
            .spawned(id: "p1", pid: 42), .spawnFailed(id: "p1", error: "nope"), .stdout(id: "p1", line: "{\"x\":1}"),
            .stderr(id: "p1", data: Data([0, 1, 2, 255])), .exit(id: "p1", status: 143),
            .workspaces(rid: "r", items: [HostWorkspace(name: "a", mtime: 5)]), .workspaceCreated(rid: "r", name: "a"), .pong,
            .error(id: "p1", rid: nil, message: "m"), .error(id: nil, rid: "r", message: "m"), .error(id: nil, rid: nil, message: "m"),
        ]
        for e in evs { XCTAssertEqual(try HostProtocol.decodeEvent(try HostProtocol.encode(e)), e) }
    }

    func testWireShapeIsStable() throws {
        let s = String(decoding: try HostProtocol.encode(.spawn(HostSpawnRequest(id: "p1", workspace: "w"))), as: UTF8.self)
        XCTAssertEqual(s, #"{"agent":"claude","id":"p1","op":"spawn","workspace":"w"}"#)
        XCTAssertEqual(String(decoding: try HostProtocol.encode(HostEvent.stderr(id: "i", data: Data("hi".utf8))), as: UTF8.self),
                       #"{"b64":"aGk=","ev":"stderr","id":"i"}"#)
        let hello = String(decoding: try JSONEncoder().encode(HostHello(token: "t", user: "u", uid: 1, workspaceRoot: "/r", agents: [:])), as: UTF8.self)
        XCTAssertTrue(hello.contains(#""op":"host""#) && hello.contains(#""protocol":1"#))
    }

    func testUnknownOrMalformedFramesThrow() {
        XCTAssertThrowsError(try HostProtocol.decodeCommand(Data(#"{"op":"exec","cmd":"rm"}"#.utf8)))
        XCTAssertThrowsError(try HostProtocol.decodeCommand(Data(#"{"op":"spawn","id":"x"}"#.utf8)))
        XCTAssertThrowsError(try HostProtocol.decodeCommand(Data("garbage".utf8)))
        XCTAssertThrowsError(try HostProtocol.decodeEvent(Data(#"{"ev":"stderr","id":"x","b64":"***"}"#.utf8)))
    }

    func testNameAndIdValidation() {
        for ok in ["a", "proj-1", "My.Proj_2", String(repeating: "a", count: 60)] { XCTAssertTrue(HostProtocol.isValidWorkspaceName(ok), ok) }
        for bad in ["", ".", "..", ".hidden", "-x", "a/b", "../x", "/etc", "a b", "a\nb", "é", String(repeating: "a", count: 61), "a\u{0}b"] {
            XCTAssertFalse(HostProtocol.isValidWorkspaceName(bad), bad.debugDescription)
        }
        XCTAssertTrue(HostProtocol.isValidId("chat-ab12.x_y")); XCTAssertFalse(HostProtocol.isValidId("a b")); XCTAssertFalse(HostProtocol.isValidId(""))
    }
}

// MARK: containment, environment

final class HostContainmentTests: XCTestCase {
    func testResolveListCreate() throws {
        let f = try HostFixture()
        let store = WorkspaceStore(root: f.work)
        XCTAssertEqual(try store.create("alpha").lastPathComponent, "alpha")
        XCTAssertEqual(try store.resolve("alpha").path, f.work.path + "/alpha")
        XCTAssertEqual(try store.list().map(\.name), ["alpha"])
        var st = stat(); stat(f.work.path + "/alpha", &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertThrowsError(try store.create("alpha")) { XCTAssertEqual($0 as? WorkspaceError, .exists) }
        XCTAssertThrowsError(try store.resolve("missing")) { XCTAssertEqual($0 as? WorkspaceError, .notFound) }
    }

    func testRejectsEscapesAndSymlinks() throws {
        let f = try HostFixture()
        let store = WorkspaceStore(root: f.work)
        let outside = f.base.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try f.workspace("real")
        try FileManager.default.createSymbolicLink(at: f.work.appendingPathComponent("evil"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: f.work.appendingPathComponent("alias"), withDestinationURL: f.work.appendingPathComponent("real"))
        try Data().write(to: f.work.appendingPathComponent("afile"))
        for bad in ["..", ".", "../outside", "real/..", "/etc", "/", f.base.path, "", ".hidden", "a/b"] {
            XCTAssertThrowsError(try store.resolve(bad), bad) { XCTAssertEqual($0 as? WorkspaceError, .invalidName, bad) }
            XCTAssertThrowsError(try store.create(bad), bad)
        }
        XCTAssertThrowsError(try store.resolve("evil")) { XCTAssertEqual($0 as? WorkspaceError, .symlink) }
        XCTAssertThrowsError(try store.resolve("alias")) { XCTAssertEqual($0 as? WorkspaceError, .symlink) }
        XCTAssertThrowsError(try store.resolve("afile")) { XCTAssertEqual($0 as? WorkspaceError, .notADirectory) }
        XCTAssertThrowsError(try store.create("evil")) { XCTAssertEqual($0 as? WorkspaceError, .exists) }
        XCTAssertEqual(try store.list().map(\.name), ["real"], "symlinks and files are not workspaces")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testRootThatIsASymlinkIsRefused() throws {
        let f = try HostFixture()
        let target = f.base.appendingPathComponent("elsewhere"); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = f.home.appendingPathComponent("worklink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = WorkspaceStore(root: link)
        XCTAssertThrowsError(try store.create("x")); XCTAssertThrowsError(try store.resolve("x")); XCTAssertThrowsError(try store.list())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testMissingRootIsCreatedPrivateOnlyByCreate() throws {
        let f = try HostFixture()
        let root = f.home.appendingPathComponent("w2")
        let store = WorkspaceStore(root: root)
        XCTAssertThrowsError(try store.list())
        try store.create("p")
        var st = stat(); stat(root.path, &st)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
    }
}

final class HostEnvironmentTests: XCTestCase {
    func writeToken(_ f: HostFixture, _ s: String, mode: mode_t = 0o600) throws -> URL {
        let dir = f.home.appendingPathComponent(".config/agentbar"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("claude-oauth-token")
        try s.write(to: u, atomically: true, encoding: .utf8); chmod(u.path, mode)
        return u
    }

    func testBuildsCleanEnvWithToken() throws {
        let f = try HostFixture()
        let t = try writeToken(f, "sk-ant-oat01-abc_DEF-123\n")
        let env = try HostEnvironment.build(home: f.home, user: "tester", tokenFile: t)
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "sk-ant-oat01-abc_DEF-123")
        XCTAssertEqual(env["HOME"], f.home.path); XCTAssertEqual(env["USER"], "tester")
        XCTAssertNil(env["ANTHROPIC_API_KEY"]); XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertEqual(Set(env.keys), ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "LANG", "TMPDIR", "CLAUDE_CODE_OAUTH_TOKEN"])
    }

    func testMissingOrEmptyTokenFileMeansNoToken() throws {
        let f = try HostFixture()
        XCTAssertNil(try HostEnvironment.build(home: f.home, user: "u", tokenFile: f.home.appendingPathComponent("nope"))["CLAUDE_CODE_OAUTH_TOKEN"])
        let t = try writeToken(f, "  \n")
        XCTAssertNil(try HostEnvironment.build(home: f.home, user: "u", tokenFile: t)["CLAUDE_CODE_OAUTH_TOKEN"])
    }

    func testUnsafeTokenFilesAreRefused() throws {
        let f = try HostFixture()
        let open = try writeToken(f, "tok", mode: 0o644)
        XCTAssertThrowsError(try HostEnvironment.build(home: f.home, user: "u", tokenFile: open))
        let real = try writeToken(f, "tok")
        let link = f.home.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try HostEnvironment.build(home: f.home, user: "u", tokenFile: link))
        let weird = try writeToken(f, "to ken\u{7}x")
        XCTAssertThrowsError(try HostEnvironment.build(home: f.home, user: "u", tokenFile: weird))
        XCTAssertThrowsError(try HostEnvironment.build(home: f.home, user: "u", tokenFile: real, uid: geteuid() &+ 1), "wrong owner")
    }
}

// MARK: host service over a socketpair

final class HostServiceTests: XCTestCase {
    func testSpawnStdinStdoutAndTerminate() throws {
        let f = try HostFixture(); try f.workspace("p")
        f.link(HostService(config: f.config(claude: try f.script("claude", "exec cat"))))
        let (p, c) = try f.spawn("p")
        XCTAssertTrue(hostWait { p.remotePid > 0 })
        p.write(line: Data(#"{"hello":"wörld"}"#.utf8)); p.write(line: Data("second".utf8))
        XCTAssertTrue(hostWait { c.lines.count == 2 })
        XCTAssertEqual(c.lines, [#"{"hello":"wörld"}"#, "second"])
        p.terminate()
        XCTAssertTrue(hostWait { !c.exits.isEmpty })
        XCTAssertTrue([0, 143].contains(c.exits[0]), "\(c.exits)")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(c.exits.count, 1, "exit exactly once")
        XCTAssertTrue(hostWait { f.service.activeProcessCount == 0 })
        XCTAssertEqual(f.client.activeProcessCount, 0)
    }

    func testStderrArrives() throws {
        let f = try HostFixture(); try f.workspace("p")
        f.link(HostService(config: f.config(claude: try f.script("claude", "echo oops >&2; echo out; exit 3"))))
        let (_, c) = try f.spawn("p")
        XCTAssertTrue(hostWait { !c.exits.isEmpty })
        XCTAssertEqual(c.exits, [3]); XCTAssertEqual(c.stderr, "oops\n"); XCTAssertEqual(c.lines, ["out"])
    }

    func testSpawnErrorsBecomeStderrAndExit127() throws {
        let f = try HostFixture(); try f.workspace("p")
        let claude = try f.script("claude", "exec cat")
        f.link(HostService(config: f.config(claude: claude)))
        let (_, c) = try f.spawn("nope")   // workspace does not exist
        XCTAssertTrue(hostWait { !c.exits.isEmpty })
        XCTAssertEqual(c.exits, [127]); XCTAssertTrue(c.stderr.contains("workspace not found"), c.stderr)
        XCTAssertEqual(f.service.activeProcessCount, 0); XCTAssertEqual(f.client.activeProcessCount, 0)

        // claude missing for the agent user
        let g = try HostFixture(); try g.workspace("p")
        g.link(HostService(config: g.config(claude: URL(fileURLWithPath: "/nonexistent/claude"))))
        let (_, c2) = try g.spawn("p")
        XCTAssertTrue(hostWait { !c2.exits.isEmpty })
        XCTAssertEqual(c2.exits, [127]); XCTAssertTrue(c2.stderr.contains("not installed"), c2.stderr)
    }

    func testContainmentIsEnforcedOverTheWire() throws {
        let f = try HostFixture(); try f.workspace("p")
        let outside = f.base.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.work.appendingPathComponent("evil"), withDestinationURL: outside)
        let marker = f.base.appendingPathComponent("ran")
        f.link(HostService(config: f.config(claude: try f.script("claude", "touch \(marker.path); exec cat"))))
        // Raw frames: the typed client API would already refuse some names; the host must refuse on its own.
        let (cl, sr) = makePair()
        let svc = HostService(config: f.config(claude: try f.script("claude2", "touch \(marker.path); exec cat")))
        let fin = HostFlag()
        Thread { svc.run(fd: sr); fin.set() }.start()
        let raw = HostLineReader(fd: cl)
        for ws in ["..", "../outside", "/tmp", "evil", "p/../p", ".hidden", ""] {
            let frame = #"{"agent":"claude","id":"x\#(abs(ws.hashValue % 1000))","op":"spawn","workspace":"\#(ws)"}"# + "\n"
            SocketIO.writeAll(cl, Data(frame.utf8))
            guard case .line(let l) = raw.next(timeout: 5) else { return XCTFail("no reply for \(ws)") }
            let ev = try HostProtocol.decodeEvent(l)
            if case .spawnFailed(_, let e) = ev { XCTAssertTrue(e.hasPrefix("workspace:"), e) } else { XCTFail("\(ws): \(ev)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "nothing may have been spawned")
        Darwin.shutdown(cl, SHUT_RDWR)
        XCTAssertTrue(hostWait { fin.isSet })
        close(cl); close(sr)
    }

    func testChildEnvironmentHasNoOwnerVariables() throws {
        setenv("ANTHROPIC_API_KEY", "owner-api-key-SECRET", 1); setenv("AGENTBAR_OWNER_SECRET", "owner-secret-xyz", 1)
        setenv("GITHUB_TOKEN", "ghp_owner", 1); setenv("CLAUDE_CONFIG_DIR", "/owner/claude", 1); setenv("HTTPS_PROXY", "http://owner-proxy", 1)
        defer { for k in ["ANTHROPIC_API_KEY", "AGENTBAR_OWNER_SECRET", "GITHUB_TOKEN", "CLAUDE_CONFIG_DIR", "HTTPS_PROXY"] { unsetenv(k) } }
        let f = try HostFixture(); try f.workspace("p")
        let tokDir = f.home.appendingPathComponent(".config/agentbar"); try FileManager.default.createDirectory(at: tokDir, withIntermediateDirectories: true)
        let tok = tokDir.appendingPathComponent("claude-oauth-token"); try "agent-oauth-token-1".write(to: tok, atomically: true, encoding: .utf8); chmod(tok.path, 0o600)
        f.link(HostService(config: f.config(claude: try f.script("claude", "env; echo \"PWD=$(pwd -P)\"; for a in \"$@\"; do echo \"ARG=$a\"; done; exec cat"))))
        let (p, c) = try f.spawn("p")
        XCTAssertTrue(hostWait { c.lines.contains { $0.hasPrefix("PWD=") } && c.lines.contains("ARG=--verbose") })
        let all = c.lines.joined(separator: "\n")
        for secret in ["owner-api-key-SECRET", "owner-secret-xyz", "ghp_owner", "/owner/claude", "owner-proxy", NSHomeDirectory()] where !secret.isEmpty && secret != f.home.path {
            if secret == NSHomeDirectory() && f.home.path.hasPrefix(secret) { continue }
            XCTAssertFalse(all.contains(secret), "leaked \(secret)")
        }
        for k in ["ANTHROPIC_API_KEY", "GITHUB_TOKEN", "CLAUDE_CONFIG_DIR", "HTTPS_PROXY", "AGENTBAR_OWNER_SECRET"] {
            XCTAssertFalse(c.lines.contains { $0.hasPrefix(k + "=") }, k)
        }
        XCTAssertTrue(c.lines.contains("HOME=\(f.home.path)")); XCTAssertTrue(c.lines.contains("USER=tester"))
        XCTAssertTrue(c.lines.contains("CLAUDE_CODE_OAUTH_TOKEN=agent-oauth-token-1"))
        XCTAssertTrue(c.lines.contains("PWD=\(f.work.path)/p"), "cwd is the workspace: \(c.lines.filter { $0.hasPrefix("PWD") })")
        XCTAssertTrue(c.lines.contains("ARG=--input-format")); XCTAssertFalse(all.contains("dangerously"))
        p.kill(); XCTAssertTrue(hostWait { !c.exits.isEmpty })
    }

    func testUnsafeTokenFileFailsTheSpawnNotTheHost() throws {
        let f = try HostFixture(); try f.workspace("p")
        let tokDir = f.home.appendingPathComponent(".config/agentbar"); try FileManager.default.createDirectory(at: tokDir, withIntermediateDirectories: true)
        let tok = tokDir.appendingPathComponent("claude-oauth-token"); try "t".write(to: tok, atomically: true, encoding: .utf8); chmod(tok.path, 0o644)
        f.link(HostService(config: f.config(claude: try f.script("claude", "exec cat"))))
        let (_, c) = try f.spawn("p")
        XCTAssertTrue(hostWait { !c.exits.isEmpty })
        XCTAssertEqual(c.exits, [127]); XCTAssertTrue(c.stderr.contains("oauth token file unsafe"), c.stderr)
        XCTAssertTrue(f.client.isConnected)
    }

    func testBadSpawnParametersAreRefused() throws {
        let f = try HostFixture(); try f.workspace("p")
        let (cl, sr) = makePair()
        let svc = HostService(config: f.config(claude: try f.script("claude", "exec cat")))
        Thread { svc.run(fd: sr) }.start()
        let raw = HostLineReader(fd: cl)
        let frames = [#"{"agent":"codex","id":"a1","op":"spawn","workspace":"p"}"#,
                      #"{"agent":"claude","id":"a2","model":"--dangerously-skip-permissions","op":"spawn","workspace":"p"}"#,
                      #"{"agent":"claude","id":"a3","op":"spawn","permissionMode":"bypassPermissions","workspace":"p"}"#,
                      #"{"agent":"claude","id":"a4","op":"spawn","tools":["-x"],"workspace":"p"}"#,
                      #"{"agent":"claude","id":"a5","maxBudgetUSD":-3,"op":"spawn","workspace":"p"}"#]
        for fr in frames {
            SocketIO.writeAll(cl, Data((fr + "\n").utf8))
            guard case .line(let l) = raw.next(timeout: 5), case .spawnFailed = try HostProtocol.decodeEvent(l) else { return XCTFail(fr) }
        }
        // malformed id / unknown op => request-level error, link stays up
        SocketIO.writeAll(cl, Data("{\"agent\":\"claude\",\"id\":\"a b\",\"op\":\"spawn\",\"workspace\":\"p\"}\n{\"op\":\"exec\"}\nnot json\n{\"op\":\"ping\"}\n".utf8))
        var kinds: [String] = []
        for _ in 0..<4 { if case .line(let l) = raw.next(timeout: 5), let e = try? HostProtocol.decodeEvent(l) { if case .error = e { kinds.append("error") } else if case .pong = e { kinds.append("pong") } } }
        XCTAssertEqual(kinds, ["error", "error", "error", "pong"])
        XCTAssertEqual(svc.activeProcessCount, 0)
        Darwin.shutdown(cl, SHUT_RDWR); close(cl)
    }

    func testKillHitsTheWholeProcessGroup() throws {
        let f = try HostFixture(); try f.workspace("p")
        f.link(HostService(config: f.config(claude: try f.script("claude", "sleep 300 &\necho \"child=$!\"\nexec cat"))))
        let (p, c) = try f.spawn("p")
        XCTAssertTrue(hostWait { c.lines.contains { $0.hasPrefix("child=") } })
        let child = Int32(c.lines.first { $0.hasPrefix("child=") }!.dropFirst(6))!
        XCTAssertTrue(alive(child))
        XCTAssertEqual(getpgid(child), pid_t(p.remotePid), "grandchild shares the leader's own process group")
        XCTAssertNotEqual(getpgid(child), getpgrp(), "not our group")
        p.kill()
        XCTAssertTrue(hostWait { !c.exits.isEmpty }); XCTAssertEqual(c.exits, [137])
        XCTAssertTrue(hostWait { !alive(child) }, "tool subprocess must die with its session")
    }

    func testGrandchildDiesWhenLeaderExitsOnItsOwn() throws {
        let f = try HostFixture(); try f.workspace("p")
        f.link(HostService(config: f.config(claude: try f.script("claude", "sleep 300 &\necho \"child=$!\"\nexit 0"))))
        let (_, c) = try f.spawn("p")
        XCTAssertTrue(hostWait { !c.exits.isEmpty })
        let child = Int32(c.lines.first { $0.hasPrefix("child=") }!.dropFirst(6))!
        XCTAssertTrue(hostWait { !alive(child) })
    }

    func testTerminateEscalationIsTheAppsJob() throws {
        let f = try HostFixture(); try f.workspace("p")
        f.link(HostService(config: f.config(claude: try f.script("claude", "trap '' TERM\nwhile :; do sleep 1; done"))))
        let (p, c) = try f.spawn("p")
        XCTAssertTrue(hostWait { p.remotePid > 0 }); Thread.sleep(forTimeInterval: 0.3)
        p.terminate(); Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(c.exits.isEmpty, "ignores SIGTERM; the app escalates with kill")
        p.kill()
        XCTAssertTrue(hostWait { !c.exits.isEmpty }); XCTAssertEqual(c.exits, [137])
    }

    func testDeadManKillsChildrenWhenLinkGoesSilent() throws {
        let f = try HostFixture(clientPing: 3600, clientDeadAfter: 3600)   // client never pings: the host sees silence
        try f.workspace("p")
        f.link(HostService(config: f.config(claude: try f.script("claude", "exec cat"), deadMan: 0.8)))
        let (p, c) = try f.spawn("p")
        XCTAssertTrue(hostWait { p.remotePid > 0 })
        let pid = Int32(p.remotePid)
        XCTAssertTrue(alive(pid))
        XCTAssertTrue(hostWait(6) { f.serviceDone.isSet }, "host gave up on the silent link")
        XCTAssertTrue(hostWait { !alive(pid) }, "child killed")
        XCTAssertTrue(hostWait { c.exits == [RemoteChatProcess.disconnectedStatus] }, "\(c.exits)")
        XCTAssertTrue(c.stderr.contains("agent host disconnected"))
        XCTAssertFalse(f.client.isConnected)
    }

    func testPingsKeepALiveLinkAlive() throws {
        let f = try HostFixture(clientPing: 0.15)
        try f.workspace("p")
        f.link(HostService(config: f.config(claude: try f.script("claude", "exec cat"), deadMan: 0.8)))
        let (p, c) = try f.spawn("p")
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertTrue(f.client.isConnected); XCTAssertTrue(c.exits.isEmpty)
        p.write(line: Data("still here".utf8))
        XCTAssertTrue(hostWait { c.lines == ["still here"] })
    }

    func testAppVanishingKillsChildren() throws {
        let f = try HostFixture(); try f.workspace("p")
        f.link(HostService(config: f.config(claude: try f.script("claude", "sleep 300 &\necho \"child=$!\"\nexec cat"))))
        let (p, c) = try f.spawn("p")
        XCTAssertTrue(hostWait { c.lines.contains { $0.hasPrefix("child=") } })
        let child = Int32(c.lines.first { $0.hasPrefix("child=") }!.dropFirst(6))!
        let leader = Int32(p.remotePid)
        f.dropClientSide()
        XCTAssertTrue(hostWait { f.serviceDone.isSet })
        XCTAssertFalse(alive(leader)); XCTAssertTrue(hostWait { !alive(child) })
        XCTAssertEqual(f.service.activeProcessCount, 0)
        XCTAssertTrue(hostWait { c.exits == [RemoteChatProcess.disconnectedStatus] })
    }

    func testProcessLimitAndDuplicateIds() throws {
        let f = try HostFixture(); try f.workspace("p")
        f.link(HostService(config: f.config(claude: try f.script("claude", "exec cat"), max: 2)))
        let (a, ca) = try f.spawn("p"), (b, cb) = try f.spawn("p"), (_, cc) = try f.spawn("p")
        XCTAssertTrue(hostWait { !cc.exits.isEmpty })
        XCTAssertEqual(cc.exits, [127]); XCTAssertTrue(cc.stderr.contains("too many"), cc.stderr)
        XCTAssertTrue(ca.exits.isEmpty && cb.exits.isEmpty)
        a.kill(); b.kill()
        XCTAssertTrue(hostWait { !ca.exits.isEmpty && !cb.exits.isEmpty })
    }

    func testWorkspacesOverTheWire() throws {
        let f = try HostFixture(); try f.workspace("old")
        f.link(HostService(config: f.config(claude: nil)))
        let sem = DispatchSemaphore(value: 0)
        let out = HostFlag(), names = LockedBox<[String]>([]), errs = LockedBox<[HostError]>([])
        f.client.createWorkspace(name: "fresh-1") { r in if case .failure(let e) = r { errs.mutate { $0.append(e) } }; sem.signal() }
        XCTAssertEqual(sem.wait(timeout: .now() + 5), .success)
        f.client.createWorkspace(name: "fresh-1") { r in if case .failure(let e) = r { errs.mutate { $0.append(e) } }; sem.signal() }
        XCTAssertEqual(sem.wait(timeout: .now() + 5), .success)
        f.client.createWorkspace(name: "../x") { r in if case .failure(let e) = r { errs.mutate { $0.append(e) } }; sem.signal() }
        XCTAssertEqual(sem.wait(timeout: .now() + 5), .success)
        f.client.listWorkspaces { r in if case .success(let items) = r { names.set(items.map(\.name)); out.set() }; sem.signal() }
        XCTAssertEqual(sem.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(names.get, ["fresh-1", "old"])
        XCTAssertEqual(errs.get, [.host("workspace already exists"), .host("invalid workspace name")])
        var st = stat(); stat(f.work.path + "/fresh-1", &st); XCTAssertEqual(st.st_mode & 0o777, 0o700)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var get: T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

// MARK: app side against a scripted fake host (raw frames)

final class HostClientTests: XCTestCase {
    /// Raw "host" end: we write HostEvent frames by hand and read the commands the app sends.
    final class RawHost: @unchecked Sendable {
        let fd: Int32, reader: HostLineReader
        init(fd: Int32) { self.fd = fd; reader = HostLineReader(fd: fd) }
        func send(_ e: HostEvent) { var d = try! HostProtocol.encode(e); d.append(0x0A); SocketIO.writeAll(fd, d) }
        func nextCommand() -> HostCommand? { if case .line(let l) = reader.next(timeout: 5) { return try? HostProtocol.decodeCommand(l) }; return nil }
        func nextNonPing() -> HostCommand? { while let c = nextCommand() { if c != .ping { return c } }; return nil }
    }

    func setup() throws -> (HostClient, RawHost, HostFlag) {
        let client = HostClient(pingInterval: 3600, deadAfter: 3600)
        let (a, b) = makePair()
        let done = HostFlag()
        Thread { _ = client.serve(fd: a, info: .init(user: "u", uid: 1, workspaceRoot: "/r", agents: [:])); close(a); done.set() }.start()
        XCTAssertTrue(hostWait { client.isConnected })
        return (client, RawHost(fd: b), done)
    }

    func start(_ client: HostClient) throws -> (RemoteChatProcess, HostCollector) {
        let spec = try ChatConfig.remote(workspace: "w", model: "haiku").launchSpec(environment: [:])
        let p = try client.processFactory(spec) as! RemoteChatProcess
        let c = HostCollector()
        try p.start(onLine: { c.line($0) }, onStderr: { c.err($0) }, onExit: { c.exit($0) })
        return (p, c)
    }

    func testSpawnFrameIsStructuredAndCarriesNoExecutableOrEnv() throws {
        let (client, host, _) = try setup()
        let (p, _) = try start(client)
        guard case .spawn(let r)? = host.nextNonPing() else { return XCTFail() }
        XCTAssertEqual(r.id, p.processId); XCTAssertEqual(r.workspace, "w"); XCTAssertEqual(r.model, "haiku"); XCTAssertEqual(r.agent, "claude")
        let raw = String(decoding: try HostProtocol.encode(.spawn(r)), as: UTF8.self)
        XCTAssertFalse(raw.contains("env")); XCTAssertFalse(raw.contains("executable")); XCTAssertFalse(raw.contains("/"))
        host.send(.spawned(id: r.id, pid: 77)); XCTAssertTrue(hostWait { p.remotePid == 77 })
    }

    func testForeignAndOutOfOrderFramesAreDropped() throws {
        let (client, host, _) = try setup()
        let (p, c) = try start(client)
        guard case .spawn(let r)? = host.nextNonPing() else { return XCTFail() }
        host.send(.stdout(id: "someone-else", line: "evil"))               // unknown id
        host.send(.exit(id: "someone-else", status: 0))
        host.send(.stdout(id: r.id, line: "too early"))                    // known id but not spawned yet
        host.send(.spawned(id: r.id, pid: 5))
        host.send(.stdout(id: r.id, line: "real"))
        host.send(.stderr(id: "someone-else", data: Data("x".utf8)))
        host.send(.exit(id: r.id, status: 0))
        host.send(.exit(id: r.id, status: 9))                              // second exit
        host.send(.stdout(id: r.id, line: "after exit"))
        host.send(.pong)
        XCTAssertTrue(hostWait { c.exits == [0] && client.droppedFrames >= 6 }, "exits \(c.exits) dropped \(client.droppedFrames)")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(c.lines, ["real"]); XCTAssertEqual(c.exits, [0]); XCTAssertEqual(c.stderr, "")
        XCTAssertEqual(client.droppedFrames, 6)
        _ = p
    }

    func testSpawnFailedAndHostErrorMapToStderrAnd127() throws {
        let (client, host, _) = try setup()
        let (_, c1) = try start(client)
        guard case .spawn(let r1)? = host.nextNonPing() else { return XCTFail() }
        host.send(.spawnFailed(id: r1.id, error: "workspace not found"))
        XCTAssertTrue(hostWait { c1.exits == [127] }); XCTAssertEqual(c1.stderr, "workspace not found\n")
        let (_, c2) = try start(client)
        guard case .spawn(let r2)? = host.nextNonPing() else { return XCTFail() }
        host.send(.error(id: r2.id, rid: nil, message: "duplicate id"))
        XCTAssertTrue(hostWait { c2.exits == [127] })
        XCTAssertEqual(client.activeProcessCount, 0)
    }

    func testOversizedFrameClosesTheLink() throws {
        let (client, host, done) = try setup()
        let big = Data(repeating: 0x61, count: HostProtocol.maxLineBytes + 10)
        DispatchQueue.global().async { SocketIO.writeAll(host.fd, big) }
        XCTAssertTrue(hostWait { done.isSet }); XCTAssertFalse(client.isConnected)
    }

    func testStdinAndSignalFrames() throws {
        let (client, host, _) = try setup()
        let (p, _) = try start(client)
        guard case .spawn(let r)? = host.nextNonPing() else { return XCTFail() }
        host.send(.spawned(id: r.id, pid: 1))
        XCTAssertTrue(hostWait { p.remotePid == 1 })
        p.write(line: Data(#"{"type":"user"}"#.utf8)); p.terminate(); p.kill()
        XCTAssertEqual(host.nextNonPing(), .stdin(id: r.id, line: #"{"type":"user"}"#))
        XCTAssertEqual(host.nextNonPing(), .terminate(id: r.id)); XCTAssertEqual(host.nextNonPing(), .kill(id: r.id))
    }

    func testNotConnectedThrowsSynchronously() throws {
        let client = HostClient()
        let spec = try ChatConfig.remote(workspace: "w").launchSpec(environment: [:])
        XCTAssertThrowsError(try client.processFactory(spec))
        let p = RemoteChatProcess(client: client, launch: spec.remote!)
        XCTAssertThrowsError(try p.start(onLine: { _ in }, onStderr: { _ in }, onExit: { _ in }))
        let sem = DispatchSemaphore(value: 0); let r = LockedBox<HostError?>(nil)
        client.listWorkspaces { if case .failure(let e) = $0 { r.set(e) }; sem.signal() }
        sem.wait(); XCTAssertEqual(r.get, .notConnected)
        // a local (non remote) spec is refused by the remote factory
        let local = ChatLaunchSpec(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], workingDirectory: URL(fileURLWithPath: "/tmp"), environment: [:])
        XCTAssertThrowsError(try client.processFactory(local))
    }

    func testRemoteLaunchSpecHasNoLocalPathsOrEnv() throws {
        let cfg = ChatConfig.remote(workspace: "proj", workspaceRoot: "/Users/agentbar/work", model: "haiku", maxBudgetUSD: 1, tools: ["Read"], permissionMode: .plan)
        let spec = try cfg.launchSpec(environment: ["ANTHROPIC_API_KEY": "owner", "HOME": "/Users/owner"])
        XCTAssertEqual(spec.environment, [:])
        XCTAssertEqual(spec.remote, RemoteLaunch(workspace: "proj", model: "haiku", maxBudgetUSD: 1, tools: ["Read"], permissionMode: "plan"))
        XCTAssertEqual(cfg.workingDirectory.path, "/Users/agentbar/work/proj", "display path for approval cards")
        XCTAssertThrowsError(try ChatConfig.remote(workspace: "../x").launchSpec(environment: [:]))
        XCTAssertThrowsError(try ChatConfig.remote(workspace: "p", model: "--x").launchSpec(environment: [:]))
    }
}
