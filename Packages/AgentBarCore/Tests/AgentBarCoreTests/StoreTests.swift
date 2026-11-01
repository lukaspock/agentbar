import XCTest
@testable import AgentBarCore

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AgentResponse] = []
    func add(_ r: AgentResponse) { lock.lock(); items.append(r); lock.unlock() }
    var all: [AgentResponse] { lock.lock(); defer { lock.unlock() }; return items }
}

@MainActor
final class StoreTests: XCTestCase {
    func req(_ id: String, timeout: Int? = nil, def: String? = nil) -> AgentRequest {
        AgentRequest(requestId: id, type: .approval, text: "t",
                     options: [.init(id: "allow", label: "Allow"), .init(id: "deny", label: "Deny")],
                     timeoutSeconds: timeout, defaultOptionId: def)
    }

    func testSortingAndAggregate() {
        let s = SessionStore()
        XCTAssertEqual(s.aggregateState, .idle)
        s.apply(.sessionUpdate(id: "a", name: "A", kind: .claudeCode, state: .idle, action: nil, supportsStop: nil))
        s.apply(.sessionUpdate(id: "b", name: "B", kind: nil, state: .working, action: "x", supportsStop: true))
        XCTAssertEqual(s.sessions.map(\.id), ["b", "a"])
        XCTAssertEqual(s.aggregateState, .working)
        s.apply(.sessionUpdate(id: "c", name: nil, kind: nil, state: .error, action: nil, supportsStop: nil))
        XCTAssertEqual(s.aggregateState, .error)
        s.apply(.ask(sessionId: "a", request: req("r1")))
        XCTAssertEqual(s.sessions.first?.id, "a")
        XCTAssertEqual(s.aggregateState, .needsInput)
        XCTAssertEqual(s.sessions.map(\.state), [.needsInput, .working, .error])
    }

    func testRespondOnceAndDoubleIsNoop() {
        let s = SessionStore(); let c = Collector()
        XCTAssertEqual(s.submit(sessionId: "a", request: req("r"), waiter: { c.add($0) }), .accepted)
        s.respond(AgentResponse(requestId: "r", optionId: "bogus"), sessionId: "a")   // invalid option ignored
        XCTAssertEqual(c.all.count, 0)
        s.respond(AgentResponse(requestId: "r", optionId: "allow"), sessionId: "a")
        s.respond(AgentResponse(requestId: "r", optionId: "deny"), sessionId: "a")
        XCTAssertEqual(c.all.count, 1)
        XCTAssertEqual(c.all[0].optionId, "allow")
        XCTAssertTrue(s.sessions[0].pendingRequests.isEmpty)
        XCTAssertEqual(s.sessions[0].state, .working)
    }

    func testTimeoutUsesDefault() async throws {
        let s = SessionStore(); let c = Collector()
        _ = s.submit(sessionId: "a", request: req("r", timeout: 1, def: "deny"), waiter: { c.add($0) })
        try await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertEqual(c.all.map(\.reason), [.timeout])
        XCTAssertEqual(c.all.first?.optionId, "deny")
        XCTAssertTrue(s.sessions[0].pendingRequests.isEmpty)
    }

    func testTimeoutWithoutDefault() async throws {
        let s = SessionStore(); let c = Collector()
        _ = s.submit(sessionId: "a", request: req("r", timeout: 1), waiter: { c.add($0) })
        try await Task.sleep(nanoseconds: 1_600_000_000)
        XCTAssertEqual(c.all.first?.reason, .timeout)
        XCTAssertNil(c.all.first?.optionId)
    }

    func testAnswerCancelsTimer() async throws {
        let s = SessionStore(); let c = Collector()
        _ = s.submit(sessionId: "a", request: req("r", timeout: 1, def: "deny"), waiter: { c.add($0) })
        s.respond(AgentResponse(requestId: "r", optionId: "allow"), sessionId: "a")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(c.all.count, 1)
        XCTAssertEqual(c.all[0].reason, .answered)
    }

    func testCancelAndEnd() {
        let s = SessionStore(); let c = Collector()
        _ = s.submit(sessionId: "a", request: req("r1"), waiter: { c.add($0) })
        _ = s.submit(sessionId: "a", request: req("r2"), waiter: { c.add($0) })
        s.apply(.cancelRequest(sessionId: "a", requestId: "r1"))
        XCTAssertEqual(c.all.map(\.reason), [.cancelled])
        s.apply(.sessionEnd(id: "a"))
        XCTAssertEqual(c.all.map(\.reason), [.cancelled, .cancelled])
        XCTAssertEqual(s.sessions[0].state, .done)
        XCTAssertEqual(s.pendingRequestCount, 0)
    }

    func testPendingCapAndDuplicate() {
        let s = SessionStore()
        for i in 0..<100 { XCTAssertEqual(s.submit(sessionId: "s\(i % 5)", request: req("r\(i)"), waiter: nil), .accepted) }
        XCTAssertEqual(s.submit(sessionId: "s0", request: req("x"), waiter: nil), .tooManyPending)
        s.respond(AgentResponse(requestId: "r0", optionId: "allow"), sessionId: "s0")
        XCTAssertEqual(s.submit(sessionId: "s0", request: req("r1"), waiter: nil), .duplicateRequest)
        XCTAssertEqual(s.submit(sessionId: "s0", request: req("x"), waiter: nil), .accepted)
    }

    func testHistoryCapAndTextCaps() {
        let s = SessionStore()
        for i in 0..<80 { s.apply(.log(sessionId: "a", entry: HistoryEntry(kind: .status, text: "e\(i)"))) }
        XCTAssertEqual(s.sessions[0].history.count, 50)
        XCTAssertEqual(s.sessions[0].history.last?.text, "e79")
        let long = String(repeating: "x", count: 10_000)
        s.apply(.sessionUpdate(id: "a", name: long, kind: nil, state: nil, action: long, supportsStop: nil))
        XCTAssertEqual(s.sessions[0].name.count, 80)
        XCTAssertEqual(s.sessions[0].currentAction?.count, 4000)
        let opts = (0..<10).map { RequestOption(id: "o\($0)", label: long) }
        _ = s.submit(sessionId: "a", request: AgentRequest(requestId: "q", type: .question, text: long, options: opts), waiter: nil)
        let r = s.sessions[0].pendingRequests[0]
        XCTAssertEqual(r.text.count, 4000); XCTAssertEqual(r.options.count, 6); XCTAssertEqual(r.options[0].label.count, 80)
    }

    func testStopHandler() {
        let s = SessionStore(); var stopped: [String] = []
        s.stopHandler = { stopped.append($0) }
        s.apply(.sessionUpdate(id: "a", name: nil, kind: nil, state: .working, action: nil, supportsStop: true))
        s.stop(sessionId: "a"); s.stop(sessionId: "nope")
        XCTAssertEqual(stopped, ["a"])
    }

    func testFreeTextAnswer() {
        let s = SessionStore(); let c = Collector()
        _ = s.submit(sessionId: "a", request: AgentRequest(requestId: "q", type: .question, text: "name?"), waiter: { c.add($0) })
        s.respond(AgentResponse(requestId: "q", text: "Bob"), sessionId: "a")
        XCTAssertEqual(c.all.first?.text, "Bob")
    }

    // MARK: remove

    func testRemoveDeletesAndCancelsPending() {
        let s = SessionStore(); let c = Collector()
        _ = s.submit(sessionId: "a", request: req("r1", timeout: 30, def: "deny"), waiter: { c.add($0) })
        _ = s.submit(sessionId: "a", request: req("r2"), waiter: { c.add($0) })
        s.apply(.sessionUpdate(id: "b", name: "B", kind: nil, state: .idle, action: nil, supportsStop: nil))
        s.remove(sessionId: "a")
        XCTAssertEqual(s.sessions.map(\.id), ["b"])
        XCTAssertEqual(Set(c.all.map(\.requestId)), ["r1", "r2"])
        XCTAssertTrue(c.all.allSatisfy { $0.reason == .cancelled && $0.optionId == nil })
        XCTAssertEqual(s.pendingRequestCount, 0)
        // Late respond for a removed request is ignored.
        s.respond(AgentResponse(requestId: "r1", optionId: "allow"), sessionId: "a")
        XCTAssertEqual(c.all.count, 2)
    }

    func testRemoveIdempotentAndUnknown() {
        let s = SessionStore()
        s.remove(sessionId: "nope")
        s.apply(.sessionUpdate(id: "a", name: "A", kind: nil, state: .done, action: nil, supportsStop: nil))
        s.remove(sessionId: "a"); s.remove(sessionId: "a")
        XCTAssertTrue(s.sessions.isEmpty)
        XCTAssertEqual(s.aggregateState, .idle)
    }

    func testRemovedSessionReappearsOnNewEvent() {
        let s = SessionStore()
        s.apply(.sessionUpdate(id: "a", name: "Old", kind: .codex, state: .working, action: nil, supportsStop: nil))
        s.remove(sessionId: "a")
        s.apply(.log(sessionId: "a", entry: HistoryEntry(kind: .action, text: "again")))
        XCTAssertEqual(s.sessions.count, 1)
        XCTAssertEqual(s.sessions[0].name, "a")          // fresh entry, old name/history are gone
        XCTAssertEqual(s.sessions[0].history.map(\.text), ["again"])
    }
}
