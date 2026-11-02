import XCTest
@testable import AgentBarCore

final class CodexHookSetupTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cxhs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testInstallMergeBackupAndUninstall() throws {
        let url = dir.appendingPathComponent("hooks.json")
        let existing = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]},"description":"d"}"#
        try existing.write(to: url, atomically: true, encoding: .utf8)
        let s = CodexHookSetup(hooksURL: url, agentbarPath: "/Apps/Agent Bar/agentbar")
        XCTAssertTrue(try s.command().hasSuffix("hook --adapter codex"))
        let plan = try s.planInstall()
        XCTAssertFalse(plan.isNoOp)
        // nothing written before confirmation
        XCTAssertEqual(try String(contentsOf: url), existing)
        XCTAssertEqual(try s.apply(plan, confirm: { _ in false }), .cancelled)
        XCTAssertEqual(try String(contentsOf: url), existing)
        guard case let .applied(backup) = try s.apply(plan, confirm: { _ in true }) else { return XCTFail() }
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(backup)), existing)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(obj["description"] as? String, "d")
        let hooks = obj["hooks"] as! [String: Any]
        XCTAssertEqual(Set(hooks.keys), Set(CodexHookSetup.entries.map(\.event)))
        XCTAssertEqual((hooks["Stop"] as! [Any]).count, 2)   // user's hook kept
        XCTAssertTrue(try s.planInstall().isNoOp)
        let un = try s.planUninstall()
        try s.apply(un, confirm: { _ in true })
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual((after["hooks"] as! [String: Any]).keys.sorted(), ["Stop"])
    }

    func testInvalidFileAndBadPath() throws {
        let url = dir.appendingPathComponent("hooks.json")
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CodexHookSetup(hooksURL: url, agentbarPath: "/x/agentbar").planInstall())
        XCTAssertThrowsError(try CodexHookSetup(hooksURL: url, agentbarPath: "relative/agentbar").command())
    }
}
