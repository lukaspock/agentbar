import XCTest
@testable import AgentBarCore

final class PreferencesTests: XCTestCase {
    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("AgentBar/preferences.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("prefs-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func store() -> PreferencesStore { PreferencesStore(fileURL: file) }

    func testRoundtrip() throws {
        let s = store()
        s.setTheme(.neon)
        try s.setSessionName("s1", "Reviewer")
        try s.setSessionColor("s1", "#ff0000")
        try s.setAgentDefaultColor(.codex, "00ff00")
        s.setAgentDefaultName(.codex, "Cody")
        let bot = try s.createBot(name: "Bot", colorHex: "#112233", blobKindName: "cloud", agentKind: .claudeCode, startPrompt: "Hi\nthere", skill: "review")
        try s.setBot(bot.id, forSession: "s2")
        let r = store()
        XCTAssertEqual(r.theme, .neon)
        XCTAssertEqual(r.sessionOverride(for: "s1"), AgentAppearance(displayName: "Reviewer", colorHex: "#FF0000"))
        XCTAssertEqual(r.agentDefault(for: .codex), AgentAppearance(displayName: "Cody", colorHex: "#00FF00"))
        XCTAssertEqual(r.bots(), [bot])
        XCTAssertEqual(r.botID(forSession: "s2"), bot.id)
    }

    func testFileMode0600AndAtomicNoTempLeft() throws {
        let s = store()
        s.setTheme(.pastel)
        for i in 0..<5 { try s.setSessionName("a\(i)", "n\(i)") }
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["preferences.json"], "no temp files may remain")
        XCTAssertNil(s.lastSaveError)
        // Overwrite keeps 0600 and valid JSON.
        s.setTheme(.mono)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: file)))
        let a2 = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((a2[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testBrokenFileFallsBackToDefaultsAndKeepsBackup() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: file)
        let s = store()
        XCTAssertEqual(s.theme, .automatic)
        XCTAssertTrue(s.bots().isEmpty)
        XCTAssertEqual(try String(contentsOf: file.appendingPathExtension("bak")), "{ not json")
        s.setTheme(.neon) // now overwrites the main file, the backup stays
        XCTAssertEqual(store().theme, .neon)
        XCTAssertEqual(try String(contentsOf: file.appendingPathExtension("bak")), "{ not json")
    }

    func testNewerVersionIsNotOverwrittenWithoutBackup() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = #"{"version":99,"theme":"neon","bots":[]}"#
        try Data(future.utf8).write(to: file)
        let s = store()
        XCTAssertEqual(s.theme, .automatic)
        XCTAssertEqual(try String(contentsOf: file.appendingPathExtension("bak")), future)
    }

    func testBadEntriesAreDroppedButRestSurvives() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {"version":1,"theme":"nonsense","agentDefaults":{"codex":{"colorHex":"red"},"alien":{"colorHex":"#FFFFFF"}},
         "sessions":{"s":{"displayName":"ok\\u202Eevil","colorHex":"#abcdef"}},"sessionBots":{"s":"gone"},
         "bots":[{"id":"x"},{"id":"b","name":"Good","colorHex":"#000000","agentKind":"codex","startPrompt":"p","createdAt":"2026-01-01T00:00:00Z"}]}
        """
        try Data(json.utf8).write(to: file)
        let s = store()
        XCTAssertEqual(s.theme, .automatic)
        XCTAssertEqual(s.agentDefault(for: .codex), AgentAppearance())
        XCTAssertEqual(s.sessionOverride(for: "s").colorHex, "#ABCDEF")
        XCTAssertFalse(s.sessionOverride(for: "s").displayName!.contains("\u{202E}"))
        XCTAssertEqual(s.bots().map(\.id), ["b"])
        XCTAssertNil(s.botID(forSession: "s"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path))
    }

    func testResolutionOrder() throws {
        let s = store()
        let sid = "sess-1"
        var r = s.appearance(forSession: sid, kind: .codex, project: "proj")
        XCTAssertEqual(r.colorSource, .legacyTint)
        XCTAssertEqual(r.colorHex, ThemePalette.legacyTintHex(forSession: sid))
        XCTAssertEqual(r.displayName, "proj")

        s.setTheme(.pastel)
        r = s.appearance(forSession: sid, kind: .codex, project: "proj")
        XCTAssertEqual(r.colorSource, .theme)
        XCTAssertEqual(r.colorHex, ThemePalette.pastel.defaultColorHex(for: .codex))

        try s.setAgentDefaultColor(.codex, "#111111")
        s.setAgentDefaultName(.codex, "Cody")
        r = s.appearance(forSession: sid, kind: .codex, project: "proj")
        XCTAssertEqual(desc(r), "agentDefault #111111 Cody nil nil")

        let bot = try s.createBot(name: "Rev", colorHex: "#222222", blobKindName: "drop", agentKind: .codex, startPrompt: "x")
        try s.setBot(bot.id, forSession: sid)
        r = s.appearance(forSession: sid, kind: .codex, project: "proj")
        XCTAssertEqual(desc(r), "bot #222222 Rev drop \(bot.id)")

        try s.setSessionColor(sid, "#333333")
        try s.setSessionName(sid, "Mine")
        r = s.appearance(forSession: sid, kind: .codex, project: "proj")
        XCTAssertEqual(desc(r), "session #333333 Mine drop \(bot.id)")

        // Clearing a level falls through to the next one.
        try s.setSessionColor(sid, nil)
        XCTAssertEqual(s.appearance(forSession: sid, kind: .codex, project: "proj").colorSource, .bot)
        XCTAssertTrue(s.deleteBot(id: bot.id))
        r = s.appearance(forSession: sid, kind: .codex, project: "proj")
        XCTAssertEqual(desc(r), "agentDefault #111111 Mine nil nil")
    }

    private func desc(_ r: ResolvedAppearance) -> String {
        "\(r.colorSource) \(r.colorHex) \(r.displayName) \(r.blobKindName ?? "nil") \(r.botID ?? "nil")"
    }

    func testLegacyTintMatchesAppPalette() {
        // First palette entry (0.45, 0.85, 0.70) in StatusCircle.swift.
        XCTAssertEqual(ThemePalette.legacyTints[0], "#73D9B3")
        XCTAssertEqual(ThemePalette.legacyTints.count, 5)
        for t in ThemePalette.allCases where t != .automatic {
            for k in AgentKind.allCases { XCTAssertNotNil(HexColor.normalize(t.defaultColorHex(for: k) ?? "")) }
        }
    }

    func testSanitizing() throws {
        let s = store()
        XCTAssertThrowsError(try s.setSessionColor("a", "red")) { XCTAssertEqual($0 as? PreferencesError, .invalidColor) }
        XCTAssertThrowsError(try s.setSessionColor("a", "#12345")) { _ in }
        XCTAssertThrowsError(try s.setSessionColor("a", "#GGGGGG")) { _ in }
        XCTAssertThrowsError(try s.setSessionName("", "x")) { XCTAssertEqual($0 as? PreferencesError, .invalidSessionID) }
        XCTAssertEqual(s.sessionOverride(for: "a"), AgentAppearance())

        try s.setSessionName("a", "  Bo\u{202E}b\u{0007}\nx  ")
        let n = s.sessionOverride(for: "a").displayName!
        XCTAssertFalse(n.unicodeScalars.contains { $0.value == 0x202E || $0.value == 7 || $0 == "\n" })
        let zalgo = "ok" + String(repeating: "\u{0301}", count: 30)
        try s.setSessionName("a", zalgo)
        XCTAssertFalse(s.sessionOverride(for: "a").displayName!.unicodeScalars.contains("\u{0301}"))
        try s.setSessionName("a", String(repeating: "x", count: 500))
        XCTAssertEqual(s.sessionOverride(for: "a").displayName!.count, PreferenceText.maxNameLength)
        try s.setSessionName("a", " \u{200B} ")
        XCTAssertNil(s.sessionOverride(for: "a").displayName)

        let prompt = String(repeating: "p", count: 20_000)
        let b = try s.createBot(name: "B", colorHex: "#abc123", blobKindName: "../x", agentKind: .claudeCode, startPrompt: prompt, skill: "a\u{202E}b")
        XCTAssertEqual(b.startPrompt.count, PreferenceText.maxStartPromptLength)
        XCTAssertNil(b.blobKindName)
        XCTAssertEqual(b.colorHex, "#ABC123")
        XCTAssertFalse(b.skill!.contains("\u{202E}"))
    }

    func testBotCRUD() throws {
        var t = Date(timeIntervalSince1970: 1_000)
        let box = TimeBox()
        let s = PreferencesStore(fileURL: file, now: { box.now })
        box.now = t
        let a = try s.createBot(name: "A", colorHex: "#000001", agentKind: .claudeCode, startPrompt: "pa")
        t.addTimeInterval(10); box.now = t
        let b = try s.createBot(name: "B", colorHex: "#000002", agentKind: .codex, startPrompt: "pb")
        XCTAssertEqual(s.bots().map(\.name), ["A", "B"])
        XCTAssertNotEqual(a.id, b.id)

        var edit = a
        edit.name = "A2"; edit.colorHex = "#0000ff"; edit.startPrompt = "new"
        let upd = try s.updateBot(edit)
        XCTAssertEqual(upd.name, "A2"); XCTAssertEqual(upd.colorHex, "#0000FF"); XCTAssertEqual(upd.createdAt, a.createdAt)
        XCTAssertEqual(s.bot(id: a.id)?.startPrompt, "new")

        var bad = a; bad.colorHex = "nope"
        XCTAssertThrowsError(try s.updateBot(bad)) { XCTAssertEqual($0 as? PreferencesError, .invalidColor) }
        XCTAssertEqual(s.bot(id: a.id)?.name, "A2")
        var ghost = a; ghost = Bot(id: "ghost", name: "G", colorHex: "#000000", agentKind: .codex, startPrompt: "", createdAt: Date())
        XCTAssertThrowsError(try s.updateBot(ghost)) { XCTAssertEqual($0 as? PreferencesError, .notFound) }
        XCTAssertThrowsError(try s.createBot(name: "\u{202E} ", colorHex: "#000000", agentKind: .codex, startPrompt: "")) {
            XCTAssertEqual($0 as? PreferencesError, .invalidName)
        }
        XCTAssertThrowsError(try s.setBot("ghost", forSession: "x")) { XCTAssertEqual($0 as? PreferencesError, .notFound) }

        try s.setBot(b.id, forSession: "sess")
        XCTAssertTrue(s.deleteBot(id: b.id))
        XCTAssertFalse(s.deleteBot(id: b.id))
        XCTAssertNil(s.botID(forSession: "sess"))
        XCTAssertEqual(PreferencesStore(fileURL: file).bots().map(\.name), ["A2"])
    }

    func testBotLimit() throws {
        let s = store()
        for i in 0..<PreferencesStore.maxBots { try s.createBot(name: "b\(i)", colorHex: "#000000", agentKind: .codex, startPrompt: "") }
        XCTAssertThrowsError(try s.createBot(name: "x", colorHex: "#000000", agentKind: .codex, startPrompt: "")) {
            XCTAssertEqual($0 as? PreferencesError, .limitReached)
        }
    }

    func testChangeObserverAndThreadSafety() throws {
        let s = store()
        let count = Counter()
        let id = s.addChangeObserver { count.bump() }
        s.setTheme(.mono)
        try s.setSessionName("a", "x")
        XCTAssertEqual(count.value, 2)
        _ = try? s.setSessionColor("a", "bad") // failed change: no callback
        XCTAssertEqual(count.value, 2)
        s.removeChangeObserver(id)
        s.setTheme(.neon)
        XCTAssertEqual(count.value, 2)

        DispatchQueue.concurrentPerform(iterations: 200) { i in
            try? s.setSessionName("c\(i % 20)", "n\(i)")
            _ = s.appearance(forSession: "c\(i % 20)", kind: .codex, project: "p")
        }
        let r = store()
        XCTAssertEqual(r.sessionOverride(for: "c0").displayName?.hasPrefix("n"), true)
    }

    // MARK: mascot

    func testMascotDefaultsAndRoundtrip() throws {
        let s = store()
        XCTAssertEqual(s.mascot(), MascotAppearance.standard)
        let saved = try s.setMascot(MascotAppearance(name: "  Pixel\n", bodyKindName: "cloud", colorHex: "ff8800",
                                                     eyeStyle: .happy, accessory: .hat))
        XCTAssertEqual(saved, MascotAppearance(name: "Pixel", bodyKindName: "cloud", colorHex: "#FF8800", eyeStyle: .happy, accessory: .hat))
        XCTAssertEqual(store().mascot(), saved)
        s.resetMascot()
        XCTAssertEqual(store().mascot(), MascotAppearance.standard)
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(json.contains("mascot"), "a reset mascot is not stored")
    }

    func testMascotValidation() throws {
        let s = store()
        let good = try s.setMascot(MascotAppearance(name: "Ok"))
        XCTAssertThrowsError(try s.setMascot(MascotAppearance(name: "\u{202E}\u{200B}", colorHex: "#112233"))) {
            XCTAssertEqual($0 as? PreferencesError, .invalidName)
        }
        XCTAssertThrowsError(try s.setMascot(MascotAppearance(name: "Ok", colorHex: "red"))) {
            XCTAssertEqual($0 as? PreferencesError, .invalidColor)
        }
        XCTAssertEqual(s.mascot(), good, "failed changes keep the old value")
        let long = try s.setMascot(MascotAppearance(name: String(repeating: "x", count: 100), bodyKindName: "not a shape!"))
        XCTAssertEqual(long.name.count, PreferenceText.maxNameLength)
        XCTAssertEqual(long.bodyKindName, MascotAppearance.defaultBodyKindName)
    }

    func testMascotObserverFires() throws {
        let s = store()
        let count = Counter()
        s.addChangeObserver { count.bump() }
        try s.setMascot(MascotAppearance(name: "A"))
        s.resetMascot()
        XCTAssertEqual(count.value, 2)
        _ = try? s.setMascot(MascotAppearance(name: "A", colorHex: "zz"))
        XCTAssertEqual(count.value, 2)
    }

    // MARK: bot default folder / workspace, initial message

    func testBotDefaultFolderAndWorkspaceRoundtripAndValidation() throws {
        let s = store()
        let bot = try s.createBot(name: "Rev", colorHex: "#102030", agentKind: .claudeCode, startPrompt: "p",
                                  defaultFolder: " /Users/me/proj/ ", defaultWorkspace: "my-ws_1.0")
        XCTAssertEqual(bot.defaultFolder, "/Users/me/proj")
        XCTAssertEqual(bot.defaultWorkspace, "my-ws_1.0")
        XCTAssertEqual(store().bot(id: bot.id)?.defaultFolder, "/Users/me/proj")
        XCTAssertEqual(store().bot(id: bot.id)?.defaultWorkspace, "my-ws_1.0")

        // Invalid values are rejected and change nothing.
        for bad in ["relative/path", "/a/../etc", "/tmp/x\nrm", "/tmp/\u{202E}x", "/" + String(repeating: "a", count: 1100)] {
            XCTAssertThrowsError(try s.createBot(name: "B", colorHex: "#000000", agentKind: .codex, startPrompt: "", defaultFolder: bad), bad) {
                XCTAssertEqual($0 as? PreferencesError, .invalidFolder)
            }
        }
        for bad in [".hidden", "a/b", "sp ace", "ümlaut", String(repeating: "w", count: 65)] {
            XCTAssertThrowsError(try s.createBot(name: "B", colorHex: "#000000", agentKind: .codex, startPrompt: "", defaultWorkspace: bad), bad) {
                XCTAssertEqual($0 as? PreferencesError, .invalidWorkspace)
            }
        }
        XCTAssertEqual(s.bots().count, 1)

        var edit = bot
        edit.defaultFolder = "relative"
        XCTAssertThrowsError(try s.updateBot(edit)) { XCTAssertEqual($0 as? PreferencesError, .invalidFolder) }
        XCTAssertEqual(s.bot(id: bot.id)?.defaultFolder, "/Users/me/proj")
        edit.defaultFolder = "  "; edit.defaultWorkspace = nil     // blank clears
        let cleared = try s.updateBot(edit)
        XCTAssertNil(cleared.defaultFolder); XCTAssertNil(cleared.defaultWorkspace)
    }

    func testOldBotWithoutDefaultsLoadsAndBrokenDefaultsAreDropped() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {"version":1,"theme":"neon","bots":[
        {"id":"old","name":"Old","colorHex":"#112233","agentKind":"claudeCode","startPrompt":"p","createdAt":"2026-11-01T10:00:00Z"},
        {"id":"typo","name":"Typo","colorHex":"#112233","agentKind":"claudeCode","startPrompt":"p","defaultFolder":42,"defaultWorkspace":"ok","createdAt":"2026-11-02T10:00:00Z"},
        {"id":"evil","name":"Evil","colorHex":"#112233","agentKind":"claudeCode","startPrompt":"p","defaultFolder":"../../etc","defaultWorkspace":".x","createdAt":"2026-11-03T10:00:00Z"}]}
        """
        try Data(json.utf8).write(to: file)
        let s = store()
        XCTAssertEqual(s.bots().map(\.id), ["old", "typo", "evil"])
        XCTAssertNil(s.bot(id: "old")?.defaultFolder)
        XCTAssertNil(s.bot(id: "typo")?.defaultFolder)
        XCTAssertEqual(s.bot(id: "typo")?.defaultWorkspace, "ok")
        XCTAssertNil(s.bot(id: "evil")?.defaultFolder)
        XCTAssertNil(s.bot(id: "evil")?.defaultWorkspace)
    }

    func testInitialMessageComposition() {
        func bot(prompt: String, skill: String?) -> Bot {
            Bot(id: "b", name: "B", colorHex: "#000000", agentKind: .claudeCode, startPrompt: prompt, skill: skill, createdAt: Date())
        }
        XCTAssertEqual(bot(prompt: "Review this.", skill: "review-code").initialMessage, "/review-code Review this.")
        XCTAssertEqual(bot(prompt: "Review this.", skill: nil).initialMessage, "Review this.")
        XCTAssertEqual(bot(prompt: "", skill: "ckm:design_2").initialMessage, "/ckm:design_2")
        XCTAssertNil(bot(prompt: "  \n ", skill: nil).initialMessage)
        XCTAssertNil(bot(prompt: "", skill: "../ ").initialMessage)
        // Skill name is cleaned to [A-Za-z0-9:_-]: no way to smuggle a second command, a path or a newline.
        XCTAssertEqual(bot(prompt: "x", skill: "/review code;rm -rf").initialMessage, "/reviewcoderm-rf x")
        XCTAssertEqual(bot(prompt: "x", skill: "a\n/b").initialMessage, "/ab x")
        XCTAssertEqual(PreferenceText.skillCommandName("  /review-code  "), "review-code")
        XCTAssertNil(PreferenceText.skillCommandName("///"))
        XCTAssertEqual(PreferenceText.skillCommandName(String(repeating: "a", count: 100))?.count, PreferenceText.maxSkillCommandLength)
        // Multi-line prompts keep their line breaks.
        XCTAssertEqual(bot(prompt: "line1\nline2", skill: "s").initialMessage, "/s line1\nline2")
    }

    func testBotDefaultsAffectOnlyTheirOwnBot() throws {
        let s = store()
        let a = try s.createBot(name: "A", colorHex: "#000001", agentKind: .claudeCode, startPrompt: "", defaultFolder: "/tmp/a")
        let b = try s.createBot(name: "B", colorHex: "#000002", agentKind: .claudeCode, startPrompt: "", defaultWorkspace: "wsb")
        XCTAssertNil(s.bot(id: a.id)?.defaultWorkspace)
        XCTAssertNil(s.bot(id: b.id)?.defaultFolder)
        XCTAssertTrue(s.deleteBot(id: a.id))
        XCTAssertEqual(s.bot(id: b.id)?.defaultWorkspace, "wsb")
    }

    func testOldFileWithoutMascotStillLoads() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"theme":"neon","agentDefaults":{},"sessions":{},"sessionBots":{},"bots":[]}"#.utf8).write(to: file)
        let s = store()
        XCTAssertEqual(s.theme, .neon)
        XCTAssertEqual(s.mascot(), MascotAppearance.standard)
        XCTAssertFalse(s.isReadOnly)
    }

    func testBrokenMascotFieldsFallBackWithoutLosingTheRest() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"version":1,"theme":"mono","bots":[],"mascot":{"name":"Zed","bodyKindName":"drop","colorHex":"nope","eyeStyle":"laser","accessory":"bow"}}"#
        try Data(json.utf8).write(to: file)
        let s = store()
        XCTAssertEqual(s.theme, .mono)
        XCTAssertEqual(s.mascot(), MascotAppearance(name: "Zed", bodyKindName: "drop", colorHex: MascotAppearance.defaultColorHex,
                                                    eyeStyle: .round, accessory: .bow))
        // A mascot of the wrong type is dropped, other data survives.
        try Data(#"{"version":1,"theme":"neon","mascot":"oops"}"#.utf8).write(to: file)
        let t = store()
        XCTAssertEqual(t.theme, .neon)
        XCTAssertEqual(t.mascot(), MascotAppearance.standard)
    }
}

private final class TimeBox: @unchecked Sendable {
    private let l = NSLock(); private var d = Date()
    var now: Date { get { l.lock(); defer { l.unlock() }; return d } set { l.lock(); d = newValue; l.unlock() } }
}
private final class Counter: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func bump() { l.lock(); n += 1; l.unlock() }
    var value: Int { l.lock(); defer { l.unlock() }; return n }
}
