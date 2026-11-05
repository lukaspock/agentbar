import XCTest
@testable import AgentBarCore

final class TokenStatusTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws {
        let raw = URL(fileURLWithPath: "/tmp/abt-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        dir = URL(fileURLWithPath: String(cString: realpath(raw.path, nil)))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ content: String, mode: mode_t) -> URL {
        let u = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: u.path, contents: Data(content.utf8))
        chmod(u.path, mode)
        return u
    }
    private let tok = "sk-ant-oat01-" + String(repeating: "A", count: 90)

    func testAbsentFile() {
        let s = HostTokenStatus.inspect(file: dir.appendingPathComponent("nope"), uid: geteuid())
        XCTAssertFalse(s.present); XCTAssertFalse(s.isHealthy); XCTAssertNil(s.mode)
    }

    func testHealthyFile() {
        let s = HostTokenStatus.inspect(file: write("t", tok + "\n", mode: 0o600), uid: geteuid())
        XCTAssertTrue(s.present); XCTAssertEqual(s.mode, 0o600); XCTAssertTrue(s.ownerOK)
        XCTAssertTrue(s.plausibleLength); XCTAssertTrue(s.isHealthy); XCTAssertEqual(s.size, tok.utf8.count + 1)
    }

    func testWrongModeOwnerLengthAndSymlink() throws {
        XCTAssertFalse(HostTokenStatus.inspect(file: write("w", tok, mode: 0o644), uid: geteuid()).isHealthy)
        XCTAssertFalse(HostTokenStatus.inspect(file: write("g", tok, mode: 0o640), uid: geteuid()).isHealthy)
        XCTAssertFalse(HostTokenStatus.inspect(file: write("o", tok, mode: 0o600), uid: geteuid() &+ 1).isHealthy)
        XCTAssertFalse(HostTokenStatus.inspect(file: write("short", "abc", mode: 0o600), uid: geteuid()).plausibleLength)
        XCTAssertFalse(HostTokenStatus.inspect(file: write("long", String(repeating: "x", count: 5000), mode: 0o600), uid: geteuid()).plausibleLength)
        let target = write("real", tok, mode: 0o600)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let s = HostTokenStatus.inspect(file: link, uid: geteuid())
        XCTAssertTrue(s.present); XCTAssertFalse(s.ownerOK); XCTAssertFalse(s.isHealthy)
    }

    func testStatusNeverContainsContent() throws {
        let s = HostTokenStatus.inspect(file: write("t", tok, mode: 0o600), uid: geteuid())
        let json = String(decoding: try HostProtocol.encode(HostEvent.tokenstatus(rid: "r1", status: s)), as: UTF8.self)
        XCTAssertFalse(json.contains("sk-ant"))
        XCTAssertTrue(json.contains("\"ev\":\"tokenstatus\""))
    }

    func testFrameRoundTrip() throws {
        let c = try HostProtocol.decodeCommand(try HostProtocol.encode(HostCommand.tokenstatus(rid: "r9")))
        XCTAssertEqual(c, .tokenstatus(rid: "r9"))
        let st = HostTokenStatus(present: true, mode: 0o600, ownerOK: true, size: 109, plausibleLength: true, mtime: 5)
        let e = try HostProtocol.decodeEvent(try HostProtocol.encode(HostEvent.tokenstatus(rid: "r9", status: st)))
        XCTAssertEqual(e, .tokenstatus(rid: "r9", status: st))
    }

    func testServiceAnswersTokenStatus() throws {
        let f = try HostFixture()
        let file = f.home.appendingPathComponent(HostEnvironment.tokenFileRelativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data(tok.utf8)); chmod(file.path, 0o600)
        let svc = HostService(config: HostService.Config(home: f.home, user: "x", uid: geteuid()))
        let st = HostTokenStatus.inspect(file: svc.config.oauthTokenFile!, uid: svc.config.uid)
        XCTAssertTrue(st.isHealthy)
    }
}

final class ClaudeTokenParserTests: XCTestCase {
    private let body = String((0..<95).map { _ in "abcXYZ019_-".randomElement()! })
    private var token: String { "sk-ant-oat01-" + body }

    func testPlainLine() {
        XCTAssertEqual(ClaudeTokenParser.extract(from: "Your token:\n\n\(token)\n\nStore it.\n"), token)
    }

    func testANSIAndCarriageReturns() {
        let raw = "\u{1B}[2J\u{1B}[H\u{1B}[1mOAuth\u{1B}[0m token\r\n\u{1B}]0;title\u{07}\u{1B}[38;5;12m\(token)\u{1B}[0m\r\n\u{1B}[?25h"
        XCTAssertEqual(ClaudeTokenParser.extract(from: raw), token)
    }

    func testSpinnerNoise() {
        let raw = "\r| waiting\r/ waiting\r\u{1B}[2K\(token)\r\nDone\n"
        XCTAssertEqual(ClaudeTokenParser.extract(from: raw), token)
    }

    func testStopsAtFirstForeignCharacter() {
        XCTAssertEqual(ClaudeTokenParser.extract(from: "x \(token) (copy)\n"), token)
        XCTAssertEqual(ClaudeTokenParser.extract(from: "\"\(token)\".\n"), token)
    }

    func testRejectsShortAndWrongPrefix() {
        XCTAssertNil(ClaudeTokenParser.extract(from: "sk-ant-oat01-short\n"))
        XCTAssertNil(ClaudeTokenParser.extract(from: "sk-ant-api03-" + body + "\n"))
        XCTAssertNil(ClaudeTokenParser.extract(from: "no token here\n"))
    }

    func testHardWrapAt80Columns() {
        let full = "  " + token                       // leading indentation counts toward the width
        var lines: [String] = []; var rest = Substring(full)
        while rest.count > 80 { lines.append(String(rest.prefix(80))); rest = rest.dropFirst(80) }
        lines.append(String(rest))
        let out = "Token:\n" + lines.joined(separator: "\r\n") + "\r\n\r\nStore this securely\r\n"
        XCTAssertEqual(ClaudeTokenParser.extract(from: out, wrapWidth: 80), token)
        XCTAssertNotEqual(ClaudeTokenParser.extract(from: out), token)   // without a width: no joining (truncated)
    }

    func testWrapNotJoinedWithUnrelatedWordAfterShortLine() {
        // Token line shorter than the width of a following word line: no joining.
        XCTAssertEqual(ClaudeTokenParser.extract(from: "\(token)\nDone\n"), token)
    }

    func testStreamingWaitsForNewlineAndForPossibleContinuation() {
        let partial = Array("Token:\n\(token.prefix(60))".utf8)      // no newline yet
        XCTAssertNil(ClaudeTokenParser.extract(from: partial))
        XCTAssertEqual(ClaudeTokenParser.extract(from: Array("Token:\n\(token)\n".utf8)), token)
        let w = 13 + 80   // token fills a 93-column line exactly: may continue, so not accepted before more data
        let full = "sk-ant-oat01-" + String(repeating: "a", count: 80)
        XCTAssertEqual(full.count, w)
        XCTAssertNil(ClaudeTokenParser.extract(from: Array("\(full)\n".utf8), wrapWidth: w))
        XCTAssertEqual(ClaudeTokenParser.extract(from: Array("\(full)\n\n".utf8), wrapWidth: w), full)
        XCTAssertEqual(ClaudeTokenParser.extract(from: Array("Token:\n\(token)\n".utf8), isFinal: true), token)
        XCTAssertEqual(ClaudeTokenParser.extract(from: Array("Token:\n\(token)".utf8), isFinal: true), token)
    }

    func testManualToken() {
        XCTAssertEqual(ClaudeTokenParser.normalizedManualToken("  \(token)\n"), token)
        XCTAssertNil(ClaudeTokenParser.normalizedManualToken("\(token) extra"))
        XCTAssertNil(ClaudeTokenParser.normalizedManualToken("sk-ant-oat01-x"))
        XCTAssertNil(ClaudeTokenParser.normalizedManualToken(""))
    }
}
