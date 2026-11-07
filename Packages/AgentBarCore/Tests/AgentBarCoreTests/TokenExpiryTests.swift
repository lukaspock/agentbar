import XCTest
@testable import AgentBarCore

private struct FixedToken: SetupTokenInspector {
    var info: SetupTokenFileInfo?
    func tokenInfo() async throws -> SetupTokenFileInfo? { info }
}

final class TokenExpiryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func mtime(daysAgo d: Double) -> Int { Int(now.timeIntervalSince1970 - d * 86_400) }

    func testBoundaries() {
        XCTAssertEqual(TokenExpiry.status(mtime: mtime(daysAgo: 0), now: now), .ok)
        XCTAssertEqual(TokenExpiry.status(mtime: mtime(daysAgo: 329), now: now), .ok)
        XCTAssertEqual(TokenExpiry.status(mtime: mtime(daysAgo: 330), now: now), .expiresSoon(days: 35))
        XCTAssertEqual(TokenExpiry.status(mtime: mtime(daysAgo: 364), now: now), .expiresSoon(days: 1))
        XCTAssertEqual(TokenExpiry.status(mtime: mtime(daysAgo: 365), now: now), .expired)
        XCTAssertEqual(TokenExpiry.status(mtime: mtime(daysAgo: 900), now: now), .expired)
        XCTAssertEqual(TokenExpiry.status(mtime: nil, now: now), .unknown)
        XCTAssertEqual(TokenExpiry.status(mtime: mtime(daysAgo: -5), now: now), .ok, "future mtime = fresh")
    }

    func testMessagesAndDaysLeft() {
        XCTAssertEqual(TokenExpiry.expiresSoon(days: 12).message, "Token expires in 12 days — sign in again")
        XCTAssertEqual(TokenExpiry.expiresSoon(days: 1).message, "Token expires in 1 day — sign in again")
        XCTAssertEqual(TokenExpiry.expired.message, "Token expired — sign in again")
        XCTAssertNil(TokenExpiry.ok.message); XCTAssertNil(TokenExpiry.unknown.message)
        XCTAssertEqual(TokenExpiry.daysLeft(mtime: mtime(daysAgo: 300), now: now), 65)
        XCTAssertEqual(TokenExpiry.daysLeft(mtime: mtime(daysAgo: 400), now: now), 0)
        XCTAssertNil(TokenExpiry.daysLeft(mtime: nil, now: now))
    }

    func testHostTokenStatusExpiry() {
        XCTAssertNil(HostTokenStatus(present: false).expiry(now: now))
        XCTAssertEqual(HostTokenStatus(present: true, mtime: mtime(daysAgo: 366)).expiry(now: now), .expired)
        XCTAssertEqual(HostTokenStatus(present: true).expiry(now: now), .unknown)
    }

    private func probe(daysAgo: Double?) -> ClaudeTokenProbe {
        let m = daysAgo.map { mtime(daysAgo: $0) }
        return ClaudeTokenProbe(inspector: FixedToken(info: .init(mode: 0o600, size: 100, mtime: m)), now: { self.now })
    }

    func testProbeBehaviour() async {
        var s = await probe(daysAgo: 10).check(); XCTAssertEqual(s, .done)
        s = await probe(daysAgo: 340).check(); XCTAssertEqual(s, .done, "expires soon stays done")
        s = await probe(daysAgo: 365).check(); XCTAssertEqual(s, .missing, "expired is missing")
        s = await probe(daysAgo: nil).check(); XCTAssertEqual(s, .done, "unknown age does not block")
    }

    func testExpiredTokenIsPlannedAgain() {
        let st = SetupState(statuses: [.claudeToken: .missing, .agentUser: .done, .claudeCLI: .done])
        XCTAssertTrue(st.plan.contains(.init(step: .claudeToken, phase: .acquire)))
        XCTAssertTrue(st.plan.contains(.init(step: .claudeToken, phase: .admin)))
    }
}
