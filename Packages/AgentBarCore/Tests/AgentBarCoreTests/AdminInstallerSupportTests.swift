import XCTest
@testable import AgentBarCore

final class AdminInstallerSupportTests: XCTestCase {
    private func sh(_ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try? p.run(); let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(decoding: d, as: UTF8.self))
    }

    func testQuoteRoundTripsThroughRealShell() {
        let nasty = ["plain", "with space", "it's", "a'b'c", "$(touch /tmp/x)", "`id`", "a;b|c&d", "\"dq\"", "back\\slash", "new\nline", "-n", "*", ""]
        for s in nasty {
            let (st, out) = sh(["-c", "printf %s " + AdminShell.quote(s)])
            XCTAssertEqual(st, 0); XCTAssertEqual(out, s, "round trip of \(s.debugDescription)")
        }
    }

    func testAppleScriptLiteralEscapes() {
        XCTAssertEqual(AdminShell.appleScriptLiteral(#"a"b\c"#), #""a\"b\\c""#)
        XCTAssertEqual(AdminShell.appleScriptLiteral("l1\nl2"), "\"l1\\nl2\"")
    }

    func testAccountNameAllowList() {
        for ok in ["lukas", "a.b_c-d", "User1"] { XCTAssertTrue(AdminShell.isSafeAccountName(ok), ok) }
        for bad in ["", "-x", "a b", "a;b", "a'b", "a$b", String(repeating: "a", count: 32), "ü"] { XCTAssertFalse(AdminShell.isSafeAccountName(bad), bad) }
    }

    private func manifest() -> AdminManifest {
        AdminManifest(files: Dictionary(uniqueKeysWithValues: AdminInstallerSpec.payloadFiles.map { ($0, String(repeating: "ab", count: 32)) }))
    }

    func testProgramParsesAndQuotesPathsWithSpacesAndQuotes() throws {
        let dir = "/Applications/Agent Bar's/AgentBar.app/Contents/Resources/AgentSetup"
        let p = try AdminInstallerSpec.program(payloadDir: dir, manifest: manifest(), owner: "lukas", steps: ["agentUser", "cli"],
                                               tokenFile: "/tmp/dir with space/tok", migrate: true, runID: "r1")
        XCTAssertEqual(sh(["-n", "-c", p]).0, 0, "program must be valid shell")
        XCTAssertTrue(p.contains(AdminShell.quote(dir + "/agentbar-host")))
        XCTAssertTrue(p.contains("--token-file '/tmp/dir with space/tok'"))
        XCTAssertTrue(p.contains("--migrate"))
        XCTAssertTrue(p.contains("exit 72") && p.contains("shasum -a 256 -c"))
        // Hash check must come before the script runs.
        XCTAssertLessThan(try XCTUnwrap(p.range(of: "shasum")).lowerBound, try XCTUnwrap(p.range(of: "/bin/bash \"$S/")).lowerBound)
        // The whole thing survives wrapping into one AppleScript command.
        let src = AdminInstallerSpec.appleScriptSource(program: p)
        XCTAssertTrue(src.hasPrefix("do shell script \"/bin/bash -c ")); XCTAssertTrue(src.hasSuffix("with administrator privileges"))
    }

    func testProgramRejectsUnsafeOwner() {
        XCTAssertThrowsError(try AdminInstallerSpec.program(payloadDir: "/x", manifest: manifest(), owner: "a;rm -rf /", steps: [],
                                                            tokenFile: nil, migrate: false, runID: "r")) {
            XCTAssertEqual($0 as? AdminInstallerError, .invalidOwner("a;rm -rf /"))
        }
    }

    func testManifestParseAndVerify() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var files: [String: String] = [:]
        for n in AdminInstallerSpec.payloadFiles {
            let d = Data("content of \(n)".utf8)
            try d.write(to: dir.appendingPathComponent(n)); files[n] = AdminManifest.sha256Hex(of: d)
        }
        let json = try JSONSerialization.data(withJSONObject: ["version": 1, "files": files])
        let m = try AdminManifest(parsing: json)
        XCTAssertNoThrow(try m.verify(directory: dir))
        try Data("evil".utf8).write(to: dir.appendingPathComponent("agentbar-host"))
        XCTAssertThrowsError(try m.verify(directory: dir)) { XCTAssertEqual($0 as? AdminInstallerError, .payloadTampered("agentbar-host")) }
        // symlink replacement is refused
        try FileManager.default.removeItem(at: dir.appendingPathComponent("agentbar"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("agentbar"), withDestinationURL: URL(fileURLWithPath: "/bin/ls"))
        XCTAssertThrowsError(try m.verify(directory: dir)) { XCTAssertEqual($0 as? AdminInstallerError, .payloadMissing("agentbar")) }
    }

    func testManifestRejectsBadInput() throws {
        XCTAssertThrowsError(try AdminManifest(parsing: Data("nope".utf8)))
        XCTAssertThrowsError(try AdminManifest(parsing: Data(#"{"version":2,"files":{}}"#.utf8)))
        XCTAssertThrowsError(try AdminManifest(parsing: Data(#"{"version":1,"files":{"agentbar":"zz"}}"#.utf8)))
    }

    func testSha256KnownVector() {
        XCTAssertEqual(AdminManifest.sha256Hex(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testStatusLinesFilterRunAndSkipGarbage() {
        let text = """
        {"seq":1,"run":"A","step":"agentUser","state":"running","msg":"role account"}
        garbage
        {"seq":1,"run":"B","step":"cli","state":"done","msg":"old run"}
        {"seq":2,"run":"A","step":"hostBinary","state":"failed","msg":"say \\"hi\\""}
        {"seq":3,"run":"A","step":"hostBinary"
        """
        let l = AdminStatusLine.lines(in: text, run: "A")
        XCTAssertEqual(l.map(\.seq), [1, 2])
        XCTAssertEqual(l[1].msg, "say \"hi\""); XCTAssertTrue(l[1].isFailure); XCTAssertEqual(l[1].setupStep, .hostBinary)
    }

    func testErrorClassification() {
        XCTAssertEqual(AdminInstallerError.classify(code: -128, message: "User canceled.", lastFailure: nil), .cancelled)
        XCTAssertEqual(AdminInstallerError.classify(code: 20, message: "", lastFailure: "uid 502"), .legacyAccount("uid 502"))
        XCTAssertEqual(AdminInstallerError.classify(code: 72, message: "SHA-256 mismatch", lastFailure: nil), .stagingFailed("SHA-256 mismatch"))
        XCTAssertEqual(AdminInstallerError.classify(code: 1, message: "", lastFailure: nil), .failed("exit 1"))
    }
}
