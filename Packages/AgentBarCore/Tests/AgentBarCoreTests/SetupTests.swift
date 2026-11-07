import XCTest
@testable import AgentBarCore

// MARK: - Test doubles

private final class FakeFS: SetupFileSystem, @unchecked Sendable {
    var files: [String: SetupFileInfo] = [:]
    func info(at path: String) -> SetupFileInfo? { files[path] }
}

private final class ScriptedRunner: SetupProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    var responses: [String: SetupProcessResult] = [:]
    private(set) var calls: [String] = []
    func run(_ executable: String, arguments: [String]) async -> SetupProcessResult {
        record(([executable] + arguments).joined(separator: " "))
    }
    private func record(_ key: String) -> SetupProcessResult {
        lock.lock(); defer { lock.unlock() }
        calls.append(key)
        return responses[key] ?? SetupProcessResult(status: 1)
    }
}

private struct StubToken: SetupTokenInspector {
    var result: Result<SetupTokenFileInfo?, Error>
    func tokenInfo() async throws -> SetupTokenFileInfo? { try result.get() }
}

private struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }

/// Mutable world shared by probes and actions: actions flip the flags, probes read them.
private final class World: @unchecked Sendable {
    private let lock = NSLock()
    private var set: Set<SetupStep> = []
    private(set) var actionRuns: [SetupStep] = []
    private(set) var adminRuns: [[SetupStep]] = []
    private(set) var acquireRuns = 0
    func isDone(_ s: SetupStep) -> Bool { lock.lock(); defer { lock.unlock() }; return set.contains(s) }
    func markDone(_ s: SetupStep) { lock.lock(); set.insert(s); lock.unlock() }
    func recordAction(_ s: SetupStep) { lock.lock(); actionRuns.append(s); lock.unlock() }
    func recordAdmin(_ s: [SetupStep]) { lock.lock(); adminRuns.append(s); lock.unlock() }
    func recordAcquire() { lock.lock(); acquireRuns += 1; lock.unlock() }
}

private struct WorldProbe: SetupProbe {
    let step: SetupStep; let world: World
    func check() async -> StepStatus { world.isDone(step) ? .done : .missing }
}

private struct WorldAction: SetupAction {
    let step: SetupStep; let world: World; var fail = false; var noEffect = false
    func run(progress: @Sendable (String) -> Void) async throws {
        world.recordAction(step); progress("working")
        if fail { throw Boom() }
        if !noEffect { world.markDone(step) }
    }
}

private struct WorldAdmin: SetupAdminBlock {
    let world: World; var fail = false; var skip: Set<SetupStep> = []
    func run(steps: [SetupStep], progress: @Sendable (String) -> Void) async throws {
        world.recordAdmin(steps)
        for s in steps where !skip.contains(s) { world.markDone(s) }
        if fail { throw Boom() }
    }
}

private struct WorldAcquirer: SetupTokenAcquirer {
    let world: World; var fail = false
    func acquire(progress: @Sendable (String) -> Void) async throws {
        world.recordAcquire()
        if fail { throw Boom() }
    }
}

final class SetupTests: XCTestCase {
    var tmp: URL!
    override func setUp() {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("agentbar-setup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    // MARK: agentUser probe (table)

    private let paths = SetupPaths(home: "/Users/owner")

    private func healthyAgentWorld() -> (FakeFS, ScriptedRunner) {
        let fs = FakeFS(), r = ScriptedRunner()
        fs.files[paths.agentHome] = .init(isDirectory: true, mode: 0o700, owner: "agentbar", group: "staff")
        fs.files[paths.daemonPlist] = .init(mode: 0o644, owner: "root", group: "wheel")
        fs.files[paths.ipcDirectory] = .init(isDirectory: true, mode: 0o750, owner: "owner", group: "agentbar-ipc")
        r.responses["/usr/bin/dscl . -read /Users/agentbar UniqueID UserShell NFSHomeDirectory Password AuthenticationAuthority"] =
            .init(status: 0, stdout: "UniqueID: 399\nUserShell: /usr/bin/false\nNFSHomeDirectory: /Users/agentbar\n")
        r.responses["/bin/launchctl print system/com.agentbar.host"] = .init(status: 0, stdout: "state = running\nlast exit code = (never exited)\n")
        return (fs, r)
    }

    private func agentStatus(_ mutate: (FakeFS, ScriptedRunner) -> Void) async -> StepStatus {
        let (fs, r) = healthyAgentWorld(); mutate(fs, r)
        return await AgentUserProbe(paths: paths, fileSystem: fs, runner: r).check()
    }

    func testAgentUserProbeTable() async {
        let dscl = "/usr/bin/dscl . -read /Users/agentbar UniqueID UserShell NFSHomeDirectory Password AuthenticationAuthority"
        let lc = "/bin/launchctl print system/com.agentbar.host"
        let cases: [(String, (FakeFS, ScriptedRunner) -> Void, (StepStatus) -> Bool)] = [
            ("healthy", { _, _ in }, { $0 == .done }),
            ("no record", { _, r in r.responses[dscl] = .init(status: 56) }, { $0 == .missing }),
            ("no UniqueID", { _, r in r.responses[dscl] = .init(status: 0, stdout: "UserShell: /usr/bin/false\n") }, { if case .failed = $0 { return true }; return false }),
            ("system uid", { _, r in r.responses[dscl] = .init(status: 0, stdout: "UniqueID: 99\nUserShell: /usr/bin/false\nNFSHomeDirectory: /Users/agentbar\n") }, { if case .failed(let m) = $0 { return m.contains("99") }; return false }),
            ("adopted uid 502, zsh, no AuthenticationAuthority", { _, r in r.responses[dscl] = .init(status: 0, stdout: "UniqueID: 502\nUserShell: /bin/zsh\nNFSHomeDirectory: /Users/agentbar\nPassword: *\n") }, { $0 == .done }),
            ("adopted uid 502, zsh, no password attribute", { _, r in r.responses[dscl] = .init(status: 0, stdout: "UniqueID: 502\nUserShell: /bin/zsh\nNFSHomeDirectory: /Users/agentbar\n") }, { $0 == .done }),
            ("uid 502 with AuthenticationAuthority", { _, r in r.responses[dscl] = .init(status: 0, stdout: "UniqueID: 502\nUserShell: /bin/zsh\nNFSHomeDirectory: /Users/agentbar\nPassword: *\nAuthenticationAuthority:\n ;ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2>\n") }, { $0 == .missing }),
            ("uid 502 with real password", { _, r in r.responses[dscl] = .init(status: 0, stdout: "UniqueID: 502\nUserShell: /bin/zsh\nNFSHomeDirectory: /Users/agentbar\nPassword: ********\n") }, { $0 == .missing }),
            ("uid 502 shell false is fine", { _, r in r.responses[dscl] = .init(status: 0, stdout: "UniqueID: 502\nUserShell: /usr/bin/false\nNFSHomeDirectory: /Users/agentbar\nAuthenticationAuthority:\n x\n") }, { $0 == .done }),
            ("admin", { _, r in r.responses["/usr/sbin/dseditgroup -o checkmember -m agentbar admin"] = .init(status: 0) }, { if case .failed(let m) = $0 { return m.contains("admin") }; return false }),
            ("home missing", { fs, _ in fs.files[self.paths.agentHome] = nil }, { if case .failed = $0 { return true }; return false }),
            ("home owned by root", { fs, _ in fs.files[self.paths.agentHome]?.owner = "root" }, { if case .failed(let m) = $0 { return m.contains("root") }; return false }),
            ("plist missing", { fs, _ in fs.files[self.paths.daemonPlist] = nil }, { $0 == .missing }),
            ("plist not root", { fs, _ in fs.files[self.paths.daemonPlist]?.owner = "owner" }, { if case .failed = $0 { return true }; return false }),
            ("ipc dir missing", { fs, _ in fs.files[self.paths.ipcDirectory] = nil }, { $0 == .missing }),
            ("ipc wrong group", { fs, _ in fs.files[self.paths.ipcDirectory]?.group = "staff" }, { if case .failed(let m) = $0 { return m.contains("group") }; return false }),
            ("ipc mode 0755", { fs, _ in fs.files[self.paths.ipcDirectory]?.mode = 0o755 }, { if case .failed(let m) = $0 { return m.contains("755") }; return false }),
            ("daemon not loaded", { _, r in r.responses[lc] = .init(status: 113) }, { $0 == .missing }),
            ("daemon exit 78", { _, r in r.responses[lc] = .init(status: 0, stdout: "state = waiting\nlast exit code = 78\n") }, { if case .failed(let m) = $0 { return m.contains("78") }; return false }),
            ("daemon not running", { _, r in r.responses[lc] = .init(status: 0, stdout: "state = waiting\n") }, { if case .failed = $0 { return true }; return false }),
        ]
        for (name, mutate, expect) in cases {
            let s = await agentStatus(mutate)
            XCTAssertTrue(expect(s), "\(name): got \(s)")
        }
    }

    // MARK: binary probes

    func testRootBinaryProbeTable() async {
        let p = "/usr/local/bin/agentbar"
        let cases: [(String, SetupFileInfo?, StepStatus?)] = [
            ("absent", nil, .missing),
            ("ok", .init(isExecutable: true, mode: 0o755, owner: "root"), .done),
            ("owned by user", .init(isExecutable: true, mode: 0o755, owner: "owner"), nil),
            ("group writable", .init(isExecutable: true, mode: 0o775, owner: "root"), nil),
            ("not executable", .init(isExecutable: false, mode: 0o644, owner: "root"), nil),
            ("symlink", .init(isSymlink: true, isExecutable: true, mode: 0o755, owner: "root"), nil),
            ("directory", .init(isDirectory: true, isExecutable: true, mode: 0o755, owner: "root"), nil),
        ]
        for (name, info, expected) in cases {
            let fs = FakeFS(); fs.files[p] = info
            let s = await RootBinaryProbe(step: .cli, path: p, fileSystem: fs).check()
            if let expected { XCTAssertEqual(s, expected, name) }
            else if case .failed = s {} else { XCTFail("\(name): expected failed, got \(s)") }
        }
    }

    func testClaudeCLIProbe() async {
        let fs = FakeFS(), r = ScriptedRunner()
        let probe = ClaudeCLIProbe(candidates: ["/a/claude", "/b/claude"], fileSystem: fs, runner: r)
        var s = await probe.check(); XCTAssertEqual(s, .missing)
        fs.files["/b/claude"] = .init(isExecutable: true, mode: 0o755, owner: "owner")
        s = await probe.check()
        if case .failed = s {} else { XCTFail("--version fails -> failed, got \(s)") }
        r.responses["/b/claude --version"] = .init(status: 0, stdout: "2.0.0")
        s = await probe.check(); XCTAssertEqual(s, .done)
        XCTAssertFalse(r.calls.contains { $0.hasPrefix("/a/") })
    }

    // MARK: token probe (never reads content)

    func testTokenProbeTableWithRealTempFile() async throws {
        let f = tmp.appendingPathComponent("token")
        let insp = FileSetupTokenInspector(path: f.path)
        let probe = ClaudeTokenProbe(inspector: insp)
        var s = await probe.check(); XCTAssertEqual(s, .missing)

        try String(repeating: "x", count: 60).write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path)
        s = await probe.check()
        if case .failed(let m) = s { XCTAssertTrue(m.contains("0600")); XCTAssertFalse(m.contains("xxxx")) } else { XCTFail("0644 -> failed, got \(s)") }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
        s = await probe.check(); XCTAssertEqual(s, .done)

        try "short".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
        s = await probe.check()
        if case .failed(let m) = s { XCTAssertTrue(m.contains("length")) } else { XCTFail("short -> failed, got \(s)") }

        try FileManager.default.removeItem(at: f)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: false)   // broken: directory
        s = await probe.check()
        if case .failed = s {} else { XCTFail("directory -> failed, got \(s)") }
    }

    func testTokenProbeInspectorErrorIsFailedNotMissing() async {
        let s = await ClaudeTokenProbe(inspector: StubToken(result: .failure(Boom()))).check()
        if case .failed = s {} else { XCTFail("got \(s)") }
    }

    // MARK: hook probes with temp HOME

    func testClaudeHooksProbeAndAction() async throws {
        let settings = tmp.appendingPathComponent(".claude/settings.json")
        let setup = HookSetup(settingsURL: settings, agentbarPath: "/usr/local/bin/agentbar")
        let probe = ClaudeHooksProbe(setup: setup)
        var s = await probe.check(); XCTAssertEqual(s, .missing, "no file = not installed")
        try await ClaudeHooksAction(setup: setup).run(progress: { _ in })
        s = await probe.check(); XCTAssertEqual(s, .done)

        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ not json".write(to: settings, atomically: true, encoding: .utf8)
        s = await probe.check()
        if case .failed = s {} else { XCTFail("broken JSON -> failed, got \(s)") }

        let bad = ClaudeHooksProbe(setup: HookSetup(settingsURL: settings, agentbarPath: "relative/agentbar"))
        s = await bad.check()
        if case .failed = s {} else { XCTFail("invalid binary path -> failed, got \(s)") }
    }

    func testCodexHooksProbeNotApplicableWhenNotInstalled() async throws {
        let hooks = tmp.appendingPathComponent(".codex/hooks.json")
        let fs = FakeFS()
        let setup = CodexHookSetup(hooksURL: hooks, agentbarPath: "/usr/local/bin/agentbar")
        let probe = CodexHooksProbe(setup: setup, detectionPaths: [tmp.appendingPathComponent(".codex").path], fileSystem: fs)
        var s = await probe.check()
        if case .notApplicable = s {} else { XCTFail("got \(s)") }
        fs.files[tmp.appendingPathComponent(".codex").path] = .init(isDirectory: true, mode: 0o755, owner: "owner")
        s = await probe.check(); XCTAssertEqual(s, .missing)
        try await CodexHooksAction(setup: setup).run(progress: { _ in })
        s = await probe.check(); XCTAssertEqual(s, .done)
    }

    // MARK: autostart / notifications

    func testAutostartAndNotificationProbes() async {
        struct L: SetupLoginItemControlling { var s: SetupLoginItemState; func state() async -> SetupLoginItemState { s } }
        struct N: SetupNotificationAuthorizing { var s: SetupNotificationState; func authorizationState() async -> SetupNotificationState { s } }
        var a = await AutostartProbe(control: L(s: .enabled)).check(); XCTAssertEqual(a, .done)
        a = await AutostartProbe(control: L(s: .notRegistered)).check(); XCTAssertEqual(a, .missing)
        a = await AutostartProbe(control: L(s: .requiresApproval)).check()
        if case .failed = a {} else { XCTFail("requiresApproval -> failed") }
        var n = await NotificationsProbe(auth: N(s: .authorized)).check(); XCTAssertEqual(n, .done)
        n = await NotificationsProbe(auth: N(s: .notDetermined)).check(); XCTAssertEqual(n, .missing)
        n = await NotificationsProbe(auth: N(s: .denied)).check()
        if case .notApplicable = n {} else { XCTFail("denied -> neutral, got \(n)") }
        n = await NotificationsProbe(auth: N(s: .unavailable)).check()
        XCTAssertEqual(n, .notApplicable("Not available in this build"))
        XCTAssertFalse(n.isOpen)
    }

    func testOptionalStepNeverEndsFailed() async {
        let w = World()
        let probes = SetupStep.allCases.map { WorldProbe(step: $0, world: w) as SetupProbe }
        struct Throwing: SetupAction { let step = SetupStep.notifications
            func run(progress: @Sendable (String) -> Void) async throws { throw Boom() } }
        let r = SetupRunner(probes: probes, actions: [Throwing()], store: InMemorySetupStore(), useAgentUser: false)
        _ = await r.run(step: .notifications)
        let st = await r.state()
        if case .notApplicable = st.status(of: .notifications) {} else { XCTFail("got \(st.status(of: .notifications))") }
        XCTAssertFalse(st.status(of: .notifications).isOpen)
    }

    func testRootBinaryProbeOutdatedHashIsMissing() async {
        let fs = FakeFS()
        fs.files["/b"] = .init(isDirectory: false, isExecutable: true, mode: 0o755, owner: "root")
        var p = await RootBinaryProbe(step: .hostBinary, path: "/b", fileSystem: fs, expectedSHA256: "aa", hashOf: { _ in "bb" }).check()
        XCTAssertEqual(p, .missing)
        p = await RootBinaryProbe(step: .hostBinary, path: "/b", fileSystem: fs, expectedSHA256: "aa", hashOf: { _ in "aa" }).check()
        XCTAssertEqual(p, .done)
        p = await RootBinaryProbe(step: .hostBinary, path: "/b", fileSystem: fs).check()
        XCTAssertEqual(p, .done)
    }

    func testTokenProbeRetriesThenReportsUnknown() async {
        final class Counter: @unchecked Sendable { var n = 0 }
        struct Flaky: SetupTokenInspector { let c: Counter; let failures: Int
            func tokenInfo() async throws -> SetupTokenFileInfo? {
                c.n += 1
                if c.n <= failures { throw Boom() }
                return SetupTokenFileInfo(mode: 0o600, size: 108)
            } }
        let c1 = Counter()
        var s = await ClaudeTokenProbe(inspector: Flaky(c: c1, failures: 1), attempts: 2, retryDelay: .zero).check()
        XCTAssertEqual(s, .done); XCTAssertEqual(c1.n, 2)
        let c2 = Counter()
        s = await ClaudeTokenProbe(inspector: Flaky(c: c2, failures: 9), attempts: 2, retryDelay: .zero).check()
        XCTAssertTrue(s.isTokenStateUnknown, "\(s)"); XCTAssertTrue(s.isOpen); XCTAssertEqual(c2.n, 2)
    }

    func testPOSIXFileSystemReportsModeAndMissing() throws {
        let f = tmp.appendingPathComponent("f")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: f.path)
        let fs = POSIXSetupFileSystem()
        XCTAssertEqual(fs.info(at: f.path)?.mode, 0o640)
        XCTAssertEqual(fs.info(at: f.path)?.isDirectory, false)
        XCTAssertNil(fs.info(at: tmp.appendingPathComponent("nope").path))
    }

    // MARK: pure planner

    private func all(_ s: StepStatus) -> [SetupStep: StepStatus] { Dictionary(uniqueKeysWithValues: SetupStep.allCases.map { ($0, s) }) }

    func testPlanOrderForFreshSystem() {
        let plan = SetupState.plan(from: all(.missing), options: SetupOptions())
        XCTAssertEqual(plan, [
            .init(step: .claudeCLI, phase: .run),
            .init(step: .claudeToken, phase: .acquire),
            .init(step: .agentUser, phase: .admin), .init(step: .hostBinary, phase: .admin), .init(step: .cli, phase: .admin),
            .init(step: .claudeToken, phase: .admin),
            .init(step: .claudeHooks, phase: .run), .init(step: .codexHooks, phase: .run),
            .init(step: .autostart, phase: .run), .init(step: .notifications, phase: .run),
        ])
    }

    func testPlanSkipsDoneRunningNotApplicableAndSkipped() {
        var s = all(.done)
        s[.cli] = .failed("x"); s[.autostart] = .running; s[.notifications] = .missing; s[.codexHooks] = .notApplicable("n/a")
        XCTAssertEqual(SetupState.plan(from: s, options: SetupOptions(skippedSteps: [.notifications])),
                       [.init(step: .cli, phase: .admin)])
        XCTAssertTrue(SetupState.plan(from: all(.done), options: SetupOptions()).isEmpty)
        XCTAssertTrue(SetupState(statuses: all(.done)).isComplete)
    }

    func testPlanTokenAloneHasAcquireAndInstall() {
        var s = all(.done); s[.claudeToken] = .missing
        XCTAssertEqual(SetupState.plan(from: s, options: SetupOptions()),
                       [.init(step: .claudeToken, phase: .acquire), .init(step: .claudeToken, phase: .admin)])
    }

    func testLocalModeMarksAgentStepsNotApplicable() {
        let st = SetupState(statuses: all(.missing), options: SetupOptions(useAgentUser: false))
        for s in [SetupStep.agentUser, .hostBinary, .claudeToken] {
            XCTAssertEqual(st.status(of: s), .notApplicable("local mode"))
        }
        XCTAssertEqual(st.plan.map(\.step), [.claudeCLI, .cli, .claudeHooks, .codexHooks, .autostart, .notifications])
        XCTAssertEqual(st.plan.filter { $0.phase == .acquire }.count, 0)
    }

    // MARK: runner

    private func makeRunner(_ w: World, fail: Set<SetupStep> = [], noEffect: Set<SetupStep> = [], adminFail: Bool = false,
                            acquireFail: Bool = false, adminSkip: Set<SetupStep> = [], agentUser: Bool = true,
                            store: SetupKeyValueStore = InMemorySetupStore()) -> SetupRunner {
        let probes = SetupStep.allCases.map { WorldProbe(step: $0, world: w) as SetupProbe }
        let actions = [SetupStep.claudeCLI, .claudeHooks, .codexHooks, .autostart, .notifications].map {
            WorldAction(step: $0, world: w, fail: fail.contains($0), noEffect: noEffect.contains($0)) as SetupAction
        }
        return SetupRunner(probes: probes, actions: actions, adminBlock: WorldAdmin(world: w, fail: adminFail, skip: adminSkip),
                           tokenAcquirer: WorldAcquirer(world: w, fail: acquireFail), store: store, useAgentUser: agentUser)
    }

    func testRunAllCompletesAndIsIdempotent() async {
        let w = World(); let r = makeRunner(w)
        let events = EventLog()
        var st = await r.runAll(progress: { events.add($0) })
        XCTAssertTrue(st.isComplete, "\(st.statuses)")
        XCTAssertEqual(w.adminRuns, [[.agentUser, .hostBinary, .cli, .claudeToken]], "exactly one admin block")
        XCTAssertEqual(w.acquireRuns, 1)
        XCTAssertEqual(w.actionRuns, [.claudeCLI, .claudeHooks, .codexHooks, .autostart, .notifications])
        XCTAssertTrue(events.all.contains(.started(.agentUser)))
        XCTAssertTrue(events.all.contains(.message(.claudeHooks, "working")))

        st = await r.runAll()
        XCTAssertTrue(st.isComplete)
        XCTAssertEqual(w.adminRuns.count, 1, "second run is a no-op")
        XCTAssertEqual(w.acquireRuns, 1)
        XCTAssertEqual(w.actionRuns.count, 5)
    }

    func testUnknownTokenStateIsPlannedAsAcquireBeforeAdmin() {
        var st = all(.done)
        st[.agentUser] = .missing
        st[.claudeToken] = .failed("token state unknown: timeout")
        let plan = SetupState(statuses: st).plan
        let acq = plan.firstIndex(of: .init(step: .claudeToken, phase: .acquire))
        let adm = plan.firstIndex(of: .init(step: .agentUser, phase: .admin))
        XCTAssertNotNil(acq); XCTAssertNotNil(adm)
        XCTAssertLessThan(acq!, adm!)
        XCTAssertTrue(plan.contains(.init(step: .claudeToken, phase: .admin)))
    }

    func testUnknownTokenStateRunsAcquireFirstAndGoesGreenAfterInstaller() async {
        final class Order: @unchecked Sendable { var log: [String] = [] }
        let o = Order()
        let w = World()
        struct Unknown: SetupProbe { let step = SetupStep.claudeToken
            func check() async -> StepStatus { .failed("token state unknown: timeout") } }
        struct Acq: SetupTokenAcquirer { let o: Order; func acquire(progress: @Sendable (String) -> Void) async throws { o.log.append("acquire") } }
        struct Adm: SetupAdminBlock { let o: Order; let w: World
            func run(steps: [SetupStep], progress: @Sendable (String) -> Void) async throws {
                o.log.append("admin:" + steps.map(\.rawValue).joined(separator: ","))
                steps.filter { $0 != .claudeToken }.forEach { w.markDone($0) } } }
        var probes = SetupStep.allCases.filter { $0 != .claudeToken }.map { WorldProbe(step: $0, world: w) as SetupProbe }
        probes.append(Unknown())
        let actions = [SetupStep.claudeCLI, .claudeHooks, .codexHooks, .autostart, .notifications].map { WorldAction(step: $0, world: w) as SetupAction }
        let r = SetupRunner(probes: probes, actions: actions, adminBlock: Adm(o: o, w: w), tokenAcquirer: Acq(o: o), store: InMemorySetupStore())
        let st = await r.runAll()
        XCTAssertEqual(o.log, ["acquire", "admin:agentUser,hostBinary,cli,claudeToken"], "token first, then ONE admin block with the token")
        XCTAssertEqual(st.status(of: .claudeToken), .done, "unknown after a successful installer is not red")
    }

    func testTokenIsAcquiredBeforeAdminBlock() async {
        let w = World()
        final class Order: @unchecked Sendable { var log: [String] = [] }
        let o = Order()
        struct Acq: SetupTokenAcquirer { let o: Order; func acquire(progress: @Sendable (String) -> Void) async throws { o.log.append("acquire") } }
        struct Adm: SetupAdminBlock { let o: Order; let w: World
            func run(steps: [SetupStep], progress: @Sendable (String) -> Void) async throws { o.log.append("admin"); steps.forEach { w.markDone($0) } } }
        let probes = SetupStep.allCases.map { WorldProbe(step: $0, world: w) as SetupProbe }
        let actions = [SetupStep.claudeCLI, .claudeHooks, .codexHooks, .autostart, .notifications].map { WorldAction(step: $0, world: w) as SetupAction }
        let r = SetupRunner(probes: probes, actions: actions, adminBlock: Adm(o: o, w: w), tokenAcquirer: Acq(o: o), store: InMemorySetupStore())
        _ = await r.runAll()
        XCTAssertEqual(o.log, ["acquire", "admin"])
    }

    func testActionFailureSetsFailedAndIndependentStepsContinue() async {
        let w = World(); let r = makeRunner(w, fail: [.claudeHooks])
        let st = await r.runAll()
        XCTAssertEqual(st.status(of: .claudeHooks), .failed("boom"))
        XCTAssertEqual(st.status(of: .autostart), .done)
        XCTAssertEqual(st.status(of: .notifications), .done)
        XCTAssertEqual(st.status(of: .agentUser), .done)
        XCTAssertFalse(st.isComplete)
        // Retry only touches the failed step.
        let before = w.actionRuns.count
        _ = await r.runAll()
        XCTAssertEqual(w.actionRuns.count, before + 1)
    }

    func testActionThatDoesNotSatisfyProbeIsFailed() async {
        let w = World(); let r = makeRunner(w, noEffect: [.autostart])
        let st = await r.runAll()
        if case .failed = st.status(of: .autostart) {} else { XCTFail("got \(st.status(of: .autostart))") }
    }

    func testClaudeCLIFailureBlocksTokenButNotAdminOrHooks() async {
        let w = World(); let r = makeRunner(w, fail: [.claudeCLI])
        let st = await r.runAll()
        XCTAssertEqual(st.status(of: .claudeToken), .failed("requires claudeCLI"))
        XCTAssertEqual(w.acquireRuns, 0)
        XCTAssertEqual(w.adminRuns, [[.agentUser, .hostBinary, .cli]])
        XCTAssertEqual(st.status(of: .agentUser), .done)
        XCTAssertEqual(st.status(of: .claudeHooks), .done)
    }

    func testAcquireFailureSkipsTokenInstallOnly() async {
        let w = World(); let r = makeRunner(w, acquireFail: true)
        let st = await r.runAll()
        XCTAssertEqual(st.status(of: .claudeToken), .failed("boom"))
        XCTAssertEqual(w.adminRuns, [[.agentUser, .hostBinary, .cli]])
        XCTAssertEqual(st.status(of: .cli), .done)
    }

    func testAdminFailureMarksAdminStepsAndTokenDependsOnAgentUser() async {
        let w = World(); let r = makeRunner(w, adminFail: true)
        let st = await r.runAll()
        for s in [SetupStep.agentUser, .hostBinary, .cli] {
            // WorldAdmin marks done before throwing; the probe is authoritative, but the error is kept only when not done.
            XCTAssertEqual(st.status(of: s), .done)
        }
        let w2 = World(); let r2 = makeRunner(w2, adminSkip: [.agentUser])
        let st2 = await r2.runAll()
        if case .failed = st2.status(of: .agentUser) {} else { XCTFail("agentUser must stay failed") }
        XCTAssertEqual(st2.status(of: .claudeToken), .failed("requires agentUser"))
        XCTAssertEqual(st2.status(of: .claudeHooks), .done)
    }

    func testMissingAdminHandlerFails() async {
        let w = World()
        let r = SetupRunner(probes: SetupStep.allCases.map { WorldProbe(step: $0, world: w) }, actions: [], store: InMemorySetupStore(), useAgentUser: false)
        let st = await r.runAll()
        XCTAssertEqual(st.status(of: .cli), .failed(SetupError.noAdminHandler.description))
    }

    func testLocalModeRunnerNeverTouchesAgentSteps() async {
        let w = World(); let r = makeRunner(w, agentUser: false)
        let st = await r.runAll()
        XCTAssertEqual(w.acquireRuns, 0)
        XCTAssertEqual(w.adminRuns, [[.cli]])
        XCTAssertEqual(st.status(of: .agentUser), .notApplicable("local mode"))
        XCTAssertTrue(st.isComplete)
    }

    func testRunSingleStep() async {
        let w = World(); let r = makeRunner(w)
        var st = await r.run(step: .autostart)
        XCTAssertEqual(st.status(of: .autostart), .done)
        XCTAssertEqual(w.actionRuns, [.autostart])
        st = await r.run(step: .autostart)
        XCTAssertEqual(w.actionRuns, [.autostart], "idempotent")
        st = await r.run(step: .claudeToken)   // dependencies not met
        XCTAssertEqual(st.status(of: .claudeToken), .failed("requires claudeCLI"))
    }

    func testPersistenceOnlyVersionAndSkippedSteps() async {
        let store = InMemorySetupStore()
        let w = World(); let r = makeRunner(w, store: store)
        var v = await r.completedVersion; XCTAssertNil(v)
        await r.markCompleted(version: "1.2")
        v = await r.completedVersion; XCTAssertEqual(v, "1.2")
        await r.skip(.notifications); await r.skip(.autostart)
        var sk = await r.skippedSteps; XCTAssertEqual(sk, [.notifications, .autostart])
        XCTAssertEqual(store.string(forKey: "onboarding.skippedSteps"), "autostart,notifications")
        _ = await r.runAll()
        XCTAssertFalse(w.actionRuns.contains(.notifications) || w.actionRuns.contains(.autostart))
        _ = await r.run(step: .notifications)   // explicit run overrides skip
        XCTAssertTrue(w.actionRuns.contains(.notifications))
        await r.unskip(.autostart); await r.unskip(.notifications)
        sk = await r.skippedSteps; XCTAssertTrue(sk.isEmpty)
        XCTAssertNil(store.string(forKey: "onboarding.skippedSteps"))
    }

    func testUserDefaultsStoreRoundTrip() {
        let name = "agentbar.setup.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let s = UserDefaultsSetupStore(defaults: d)
        s.set("3", forKey: "k"); XCTAssertEqual(s.string(forKey: "k"), "3")
        s.set(nil, forKey: "k"); XCTAssertNil(s.string(forKey: "k"))
    }

    // MARK: fake runner

    func testFakeSetupRunner() async {
        let f = FakeSetupRunner(failing: [.autostart])
        var st = await f.state()
        XCTAssertFalse(st.plan.isEmpty)
        st = await f.runAll(progress: { _ in })
        XCTAssertEqual(st.status(of: .autostart), .failed("simulated failure"))
        XCTAssertEqual(st.status(of: .cli), .done)
        let local = FakeSetupRunner(options: SetupOptions(useAgentUser: false))
        st = await local.runAll(progress: { _ in })
        XCTAssertEqual(st.status(of: .agentUser), .notApplicable("local mode"))
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock(); private var events: [SetupEvent] = []
    func add(_ e: SetupEvent) { lock.lock(); events.append(e); lock.unlock() }
    var all: [SetupEvent] { lock.lock(); defer { lock.unlock() }; return events }
}
