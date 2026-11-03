import XCTest
@testable import AgentBarCore

final class ClaudeCodeHookSetupTests: XCTestCase {
    var dir: URL!
    var file: URL { dir.appendingPathComponent("settings.json") }
    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString)"); try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func setup(_ path: String = "/Applications/Agent Bar.app/Contents/MacOS/agentbar") -> HookSetup {
        HookSetup(settingsURL: file, agentbarPath: path, now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }
    func obj(_ d: Data) -> [String: Any] { try! JSONSerialization.jsonObject(with: d) as! [String: Any] }
    func fileObj() -> [String: Any] { obj(try! Data(contentsOf: file)) }

    let foreign = """
    {"model":"opus","env":{"A":"1"},"permissions":{"allow":["Bash(ls:*)"]},
     "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/mine.sh"}]}],
              "PostToolUse":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}
    """

    func testInstallIntoMissingFile() throws {
        let s = setup()
        let plan = try s.planInstall()
        XCTAssertFalse(plan.isNoOp); XCTAssertNil(plan.original)
        XCTAssertEqual(try s.apply(plan, confirm: { _ in true }), .applied(backup: nil))
        let hooks = fileObj()["hooks"] as! [String: Any]
        XCTAssertEqual(Set(hooks.keys), ["PermissionRequest", "PreToolUse", "Notification", "Stop", "UserPromptSubmit", "SessionStart", "SessionEnd"])
        let g = (hooks["PermissionRequest"] as! [[String: Any]])[0]
        XCTAssertEqual(g["matcher"] as? String, "*")
        let h = (g["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(h["command"] as? String, "/Applications/Agent\\ Bar.app/Contents/MacOS/agentbar hook --adapter claudeCode")
        XCTAssertEqual(h["timeout"] as? Int, 600)
        XCTAssertEqual((((hooks["Stop"] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]["timeout"]) as? Int, 5)
    }

    func testPreservesForeignKeysAndHooks() throws {
        try foreign.write(to: file, atomically: true, encoding: .utf8)
        let s = setup()
        try s.apply(try s.planInstall(), confirm: { _ in true })
        let o = fileObj()
        XCTAssertEqual(o["model"] as? String, "opus")
        XCTAssertEqual((o["env"] as? [String: String])?["A"], "1")
        XCTAssertEqual(((o["permissions"] as! [String: Any])["allow"] as! [String]), ["Bash(ls:*)"])
        let hooks = o["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["PostToolUse"])
        let pre = hooks["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(pre.count, 2)
        XCTAssertEqual(pre[0]["matcher"] as? String, "Bash")
        XCTAssertEqual(((pre[0]["hooks"] as! [[String: Any]])[0]["command"]) as? String, "/usr/local/bin/mine.sh")
    }

    func testIdempotent() throws {
        try foreign.write(to: file, atomically: true, encoding: .utf8)
        let s = setup()
        try s.apply(try s.planInstall(), confirm: { _ in true })
        let after1 = try Data(contentsOf: file)
        let plan2 = try s.planInstall()
        XCTAssertTrue(plan2.isNoOp)
        XCTAssertTrue(plan2.preview.contains("Already set up"))
        var asked = false
        XCTAssertEqual(try s.apply(plan2, confirm: { _ in asked = true; return true }), .unchanged)
        XCTAssertFalse(asked)
        XCTAssertEqual(try Data(contentsOf: file), after1)
        // only one backup (from the first apply)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("agentbar-backup") }
        XCTAssertEqual(backups.count, 1)
    }

    func testBackupWrittenWithOriginalContent() throws {
        try foreign.write(to: file, atomically: true, encoding: .utf8)
        let s = setup()
        let out = try s.apply(try s.planInstall(), confirm: { _ in true })
        guard case let .applied(b?) = out else { return XCTFail() }
        XCTAssertEqual(b.lastPathComponent, "settings.json.agentbar-backup-\(stamp())")
        XCTAssertEqual(try String(contentsOf: b), foreign)
    }
    func stamp() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testCancelWritesNothing() throws {
        try foreign.write(to: file, atomically: true, encoding: .utf8)
        let s = setup()
        XCTAssertEqual(try s.apply(try s.planInstall(), confirm: { _ in false }), .cancelled)
        XCTAssertEqual(try String(contentsOf: file), foreign)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["settings.json"])
    }

    func testInvalidJSONRefused() throws {
        for bad in ["{not json", "", "[1,2]", "42", "{\"hooks\":[]}", "{\"hooks\":{\"Stop\":{}}}"] {
            try bad.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try setup().planInstall(), bad)
            XCTAssertThrowsError(try setup().planUninstall(), bad)
            XCTAssertEqual(try String(contentsOf: file), bad)
        }
    }

    func testChangedOnDiskAfterPreviewRefused() throws {
        try foreign.write(to: file, atomically: true, encoding: .utf8)
        let s = setup()
        let plan = try s.planInstall()
        try "{\"x\":1}".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try s.apply(plan, confirm: { _ in true })) { XCTAssertEqual($0 as? HookSetup.SetupError, .changedOnDisk) }
        XCTAssertEqual(try String(contentsOf: file), "{\"x\":1}")
    }

    func testPreviewTextShowsDiff() throws {
        try foreign.write(to: file, atomically: true, encoding: .utf8)
        let p = try setup().planInstall().preview
        XCTAssertTrue(p.contains("settings.json"))
        XCTAssertTrue(p.contains("add PermissionRequest"))
        XCTAssertTrue(p.contains("+ "))
        XCTAssertTrue(p.contains("agentbar hook --adapter claudeCode"))
        XCTAssertFalse(p.contains("- ") && p.contains("\n- {"), "no removals expected")
        XCTAssertTrue(p.contains("re-formatted"))
    }

    func testPathChangeUpdatesInPlace() throws {
        let s1 = setup("/old/agentbar"), s2 = setup("/new/agentbar")
        try s1.apply(try s1.planInstall(), confirm: { _ in true })
        let plan = try s2.planInstall()
        XCTAssertFalse(plan.isNoOp)
        try s2.apply(plan, confirm: { _ in true })
        let txt = try String(contentsOf: file)
        XCTAssertFalse(txt.contains("/old/agentbar")); XCTAssertTrue(txt.contains("/new/agentbar"))
        XCTAssertEqual(txt.components(separatedBy: "agentbar hook").count - 1, 7)
    }

    func testUninstallRestoresForeignOnly() throws {
        try foreign.write(to: file, atomically: true, encoding: .utf8)
        let s = setup()
        try s.apply(try s.planInstall(), confirm: { _ in true })
        let up = try s.planUninstall()
        XCTAssertFalse(up.isNoOp); XCTAssertTrue(up.preview.contains("remove PermissionRequest"))
        try s.apply(up, confirm: { _ in true })
        XCTAssertEqual(NSDictionary(dictionary: fileObj()), NSDictionary(dictionary: obj(Data(foreign.utf8))))
        XCTAssertTrue(try s.planUninstall().isNoOp)
    }

    func testUninstallOnEmptyInstallDropsHooksKey() throws {
        let s = setup()
        try s.apply(try s.planInstall(), confirm: { _ in true })
        try s.apply(try s.planUninstall(), confirm: { _ in true })
        XCTAssertNil(fileObj()["hooks"])
    }

    func testInvalidBinaryPathRejected() {
        for p in ["relative/agentbar", "/x/other", "/x/agentbar\n; rm -rf ~"] {
            XCTAssertThrowsError(try setup(p).planInstall(), p)
        }
    }

    func testHostilePathIsEscaped() throws {
        let c = try setup("/tmp/a b;$(x)/agentbar").command()
        XCTAssertEqual(c, #"/tmp/a\ b\;\$\(x\)/agentbar hook --adapter claudeCode"#)
    }

    func testPermissionsPreserved() throws {
        try foreign.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let s = setup()
        try s.apply(try s.planInstall(), confirm: { _ in true })
        let perm = (try FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as? Int
        XCTAssertEqual(perm, 0o600)
    }

    // MARK: locateCLI / wrong-path repair

    private func fakeBundle(gui: Bool = true, cli: Bool) throws -> (exe: URL, res: URL) {
        let fm = FileManager.default
        let macos = dir.appendingPathComponent("AgentBar.app/Contents/MacOS")
        let res = dir.appendingPathComponent("AgentBar.app/Contents/Resources")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: res, withIntermediateDirectories: true)
        let exe = macos.appendingPathComponent("AgentBar")
        if gui { try "#!/bin/sh\n".write(to: exe, atomically: true, encoding: .utf8); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path) }
        if cli {
            let c = res.appendingPathComponent("agentbar")
            try "#!/bin/sh\n".write(to: c, atomically: true, encoding: .utf8); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: c.path)
        }
        return (exe, res)
    }

    func testLocateCLIPicksResourcesNotGUI() throws {
        let b = try fakeBundle(cli: true)
        XCTAssertEqual(HookSetup.locateCLI(executableURL: b.exe, resourceURL: b.res), b.res.appendingPathComponent("agentbar").path)
    }

    func testLocateCLIRejectsGUIBinaryOnly() throws {
        let b = try fakeBundle(cli: false)
        // On a case-insensitive volume MacOS/agentbar IS MacOS/AgentBar; on a case-sensitive one it does not exist. Both: nil.
        XCTAssertNil(HookSetup.locateCLI(executableURL: b.exe, resourceURL: b.res))
    }

    func testLocateCLIRejectsGUIBinaryViaSymlink() throws {
        let b = try fakeBundle(cli: false)
        let link = dir.appendingPathComponent("agentbar")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b.exe)
        XCTAssertNil(HookSetup.locateCLI(executableURL: b.exe, resourceURL: b.res, override: link.path))
    }

    func testLocateCLIOverrideStaysValid() throws {
        let b = try fakeBundle(cli: false)
        let o = dir.appendingPathComponent("custom/agentbar")
        try FileManager.default.createDirectory(at: o.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: o, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: o.path)
        XCTAssertEqual(HookSetup.locateCLI(executableURL: b.exe, resourceURL: b.res, override: o.path), o.path)
    }

    func testReinstallReplacesWrongGUIPathWithoutDuplicating() throws {
        let wrong = setup("/Users/x/Desktop/AgentBar.app/Contents/MacOS/agentbar")
        try wrong.apply(try wrong.planInstall(), confirm: { _ in true })
        let right = setup("/Users/x/Desktop/AgentBar.app/Contents/Resources/agentbar")
        let plan = try right.planInstall()
        XCTAssertFalse(plan.isNoOp)
        try right.apply(plan, confirm: { _ in true })
        let hooks = fileObj()["hooks"] as! [String: Any]
        for (_, v) in hooks {
            let groups = v as! [[String: Any]]
            XCTAssertEqual(groups.count, 1)
            let cmds = groups.flatMap { ($0["hooks"] as! [[String: Any]]).map { $0["command"] as! String } }
            XCTAssertEqual(cmds, ["/Users/x/Desktop/AgentBar.app/Contents/Resources/agentbar hook --adapter claudeCode"])
        }
        XCTAssertTrue(try right.planInstall().isNoOp)
    }
}
