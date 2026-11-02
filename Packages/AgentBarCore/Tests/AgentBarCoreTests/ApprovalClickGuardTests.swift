import XCTest
@testable import AgentBarCore

final class ApprovalClickGuardTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testNewCardIsNotArmedUntilSettled() {
        var g = ApprovalClickGuard()
        XCTAssertFalse(g.isArmed("a", currentOrder: ["a"], now: t0), "unknown card never armed")
        g.observe(order: ["a"], now: t0)
        XCTAssertFalse(g.isArmed("a", currentOrder: ["a"], now: at(0.1)))
        XCTAssertFalse(g.isArmed("a", currentOrder: ["a"], now: at(0.49)))
        XCTAssertTrue(g.isArmed("a", currentOrder: ["a"], now: at(0.5)))
    }

    func testNewRequestAppendedDoesNotDisarmOldCardButIsDisarmedItself() {
        var g = ApprovalClickGuard()
        g.observe(order: ["a"], now: t0)
        g.observe(order: ["a", "b"], now: at(1))
        XCTAssertTrue(g.isArmed("a", currentOrder: ["a", "b"], now: at(1.1)))
        XCTAssertFalse(g.isArmed("b", currentOrder: ["a", "b"], now: at(1.1)))
        XCTAssertTrue(g.isArmed("b", currentOrder: ["a", "b"], now: at(1.6)))
    }

    func testMovedCardIsDisarmed() {
        var g = ApprovalClickGuard()
        g.observe(order: ["a", "b"], now: t0)
        g.observe(order: ["b"], now: at(2))            // a answered: b moves up
        XCTAssertFalse(g.isArmed("b", currentOrder: ["b"], now: at(2.2)))
        XCTAssertTrue(g.isArmed("b", currentOrder: ["b"], now: at(2.6)))
    }

    func testClickTimeOrderMismatchRefuses() {
        var g = ApprovalClickGuard()
        g.observe(order: ["a", "b"], now: t0)
        // the view still shows b at index 1, but the model already changed: refuse even if "settled"
        XCTAssertFalse(g.isArmed("b", currentOrder: ["b"], now: at(5)))
        XCTAssertFalse(g.isArmed("b", currentOrder: ["x", "a", "b"], now: at(5)))
        XCTAssertFalse(g.isArmed("gone", currentOrder: ["a", "b"], now: at(5)))
    }

    func testLayoutChangeDisarmsEverything() {
        var g = ApprovalClickGuard()
        g.observe(order: ["a", "b"], now: t0)
        g.layoutChanged(now: at(3))
        XCTAssertFalse(g.isArmed("a", currentOrder: ["a", "b"], now: at(3.2)))
        XCTAssertTrue(g.isArmed("a", currentOrder: ["a", "b"], now: at(3.5)))
    }

    func testRemovedAndReaddedCardRestartsWindow() {
        var g = ApprovalClickGuard()
        g.observe(order: ["a"], now: t0)
        g.observe(order: [], now: at(1))
        g.observe(order: ["a"], now: at(2))
        XCTAssertFalse(g.isArmed("a", currentOrder: ["a"], now: at(2.1)))
    }

    func testStableOrderIsOldestFirstAndIgnoresSessionState() {
        func req(_ id: String, _ t: TimeInterval) -> AgentRequest {
            AgentRequest(requestId: id, type: .approval, text: "x", createdAt: Date(timeIntervalSince1970: t))
        }
        let items: [(sessionId: String, request: AgentRequest)] = [("s2", req("r3", 30)), ("s1", req("r1", 10)), ("s3", req("r2", 20)), ("s4", req("r0", 20))]
        XCTAssertEqual(RequestOrdering.stable(items).map(\.request.requestId), ["r1", "r0", "r2", "r3"])
        XCTAssertEqual(RequestOrdering.stable(items.reversed()).map(\.request.requestId), ["r1", "r0", "r2", "r3"])
    }
}
