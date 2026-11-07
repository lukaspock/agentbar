import XCTest
@testable import AgentBarCore

final class ApprovalBubbleTests: XCTestCase {
    private func req(_ id: String, text: String = "Allow Bash?\ncommand: ls", at: TimeInterval = 0,
                     timeout: Int? = 120, def: String? = nil) -> AgentRequest {
        AgentRequest(requestId: id, type: .approval, text: text, options: [], timeoutSeconds: timeout,
                     defaultOptionId: def, createdAt: Date(timeIntervalSince1970: at))
    }
    private func sess(_ id: String, _ reqs: [AgentRequest]) -> AgentSession {
        AgentSession(id: id, name: id, kind: .claudeCode, state: reqs.isEmpty ? .working : .needsInput, pendingRequests: reqs)
    }

    // MARK: placement (bubble vs card)

    func testSelectedSessionRequestGoesToBubbleOthersStayCards() {
        let s = [sess("a", [req("r1", at: 1)]), sess("b", [req("r2", at: 2)])]
        let items = RequestPlacement.place(sessions: s, bubbleSessionId: "b")
        XCTAssertEqual(items.map(\.request.requestId), ["r1", "r2"])      // queue order unchanged
        XCTAssertEqual(items.map(\.inBubble), [false, true])
        XCTAssertEqual(items.filter { !$0.inBubble }.map(\.sessionId), ["a"])
    }

    func testNoSelectionOrConversationHiddenMeansAllCards() {
        let s = [sess("a", [req("r1")]), sess("b", [req("r2", at: 1)])]
        XCTAssertTrue(RequestPlacement.place(sessions: s, bubbleSessionId: nil).allSatisfy { !$0.inBubble })
        XCTAssertTrue(RequestPlacement.place(sessions: s, bubbleSessionId: "zzz").allSatisfy { !$0.inBubble })
    }

    func testExtraWaitingCountsFurtherRequestsOfSameSession() {
        let s = [sess("a", [req("r1", at: 1), req("r1b", at: 2), req("r1c", at: 3)])]
        let items = RequestPlacement.place(sessions: s, bubbleSessionId: "a")
        XCTAssertEqual(items.count, 1)                       // one entry per session: the oldest request
        XCTAssertEqual(items[0].request.requestId, "r1")
        XCTAssertEqual(items[0].extra, 2)
    }

    func testRequestAppearsExactlyOnce() {
        let s = [sess("a", [req("r1", at: 1)]), sess("b", [req("r2", at: 2)]), sess("c", [])]
        for sel in [nil, "a", "b", "c"] as [String?] {
            let items = RequestPlacement.place(sessions: s, bubbleSessionId: sel)
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items.filter(\.inBubble).count, sel == "a" || sel == "b" ? 1 : 0)
        }
    }

    func testGuardKeyChangesWhenPlacementChanges() {
        let s = [sess("a", [req("r1")])]
        let card = RequestPlacement.place(sessions: s, bubbleSessionId: nil)[0]
        let bubble = RequestPlacement.place(sessions: s, bubbleSessionId: "a")[0]
        XCTAssertNotEqual(card.guardKey, bubble.guardKey)
        // moving card -> bubble restarts the click guard window: not armed right after the move
        var g = ApprovalClickGuard()
        let t0 = Date(timeIntervalSince1970: 100)
        g.observe(order: [card.guardKey], now: t0)
        g.layoutChanged(now: t0)
        XCTAssertTrue(g.isArmed(card.guardKey, currentOrder: [card.guardKey], now: t0.addingTimeInterval(1)))
        g.observe(order: [bubble.guardKey], now: t0.addingTimeInterval(1))
        XCTAssertFalse(g.isArmed(bubble.guardKey, currentOrder: [bubble.guardKey], now: t0.addingTimeInterval(1.1)))
        XCTAssertFalse(g.isArmed(card.guardKey, currentOrder: [bubble.guardKey], now: t0.addingTimeInterval(5)))
        XCTAssertTrue(g.isArmed(bubble.guardKey, currentOrder: [bubble.guardKey], now: t0.addingTimeInterval(1.7)))
    }

    // MARK: timeout note

    func testTimeoutNoteOnlyWhenProvable() {
        let now = Date(timeIntervalSince1970: 1000)
        let r = req("r", at: 1000 - 15, timeout: 120)
        XCTAssertEqual(RequestTimeout.remainingSeconds(r, now: now), 105)
        XCTAssertEqual(RequestTimeout.note(r, now: now), "terminal prompt takes over in 1:45")
        XCTAssertEqual(RequestTimeout.note(req("r", at: 1000 - 15, timeout: 120, def: "deny"), now: now), "auto-declines in 1:45")
        XCTAssertNil(RequestTimeout.note(req("r", timeout: nil), now: now))
        XCTAssertNil(RequestTimeout.note(req("r", timeout: 0), now: now))
        XCTAssertNil(RequestTimeout.note(req("r", at: 1000, timeout: 60, def: "allow"), now: now))   // never claim an allow
        XCTAssertEqual(RequestTimeout.remainingSeconds(req("r", at: 0, timeout: 10), now: now), 0)
    }

    func testAdapterTimeoutIsTheStoreTimeoutAndHasNoDefault() throws {
        // The app side timeout of a Claude Code approval: 120 s, resolved WITHOUT a decision (terminal dialog takes over).
        XCTAssertEqual(ClaudeCodeAdapter.approvalTimeoutSeconds, 120)
    }

    // MARK: transcript

    func testPendingRequestNoteIsHiddenWhileBubbleShows() {
        let r = req("r1", text: "Allow Bash?\ncommand: rm x")
        let h = [HistoryEntry(kind: .action, text: "Read a"), HistoryEntry(kind: .request, text: r.text)]
        XCTAssertEqual(ApprovalTranscript.display(history: h, bubble: r).map(\.text), ["Read a"])
        XCTAssertEqual(ApprovalTranscript.display(history: h, bubble: nil).count, 2)   // other sessions: unchanged
    }

    func testAnswerNotesReadAllowedAndDeniedWithReason() {
        func d(_ t: String) -> String { ApprovalTranscript.display(history: [HistoryEntry(kind: .answer, text: t)], bubble: nil)[0].text }
        XCTAssertEqual(d("answered: Allow"), "Allowed")
        XCTAssertEqual(d("answered: Deny"), "Denied")
        XCTAssertEqual(d("answered: Deny: too risky: wrong dir"), "Denied: too risky: wrong dir")
        XCTAssertEqual(d("answered: Always allow"), "Always allowed")
        XCTAssertEqual(d("timeout"), "Timed out, answer in the terminal")
        XCTAssertEqual(d("cancelled"), "Cancelled")
        XCTAssertEqual(d("answered: Postgres"), "Answered: Postgres")
        XCTAssertEqual(d("You: hi"), "You: hi")
        // user chat line is untouched (kind answer + "You: ")
        let you = ApprovalTranscript.display(history: [HistoryEntry(kind: .answer, text: "You: Allow")], bubble: nil)[0]
        XCTAssertEqual(ChatLine.parse(you), .user("Allow"))
    }

    @MainActor func testStoreKeepsDenyReasonInHistoryOneLine() {
        let store = SessionStore()
        let r = AgentRequest(requestId: "r1", type: .approval, text: "Allow Bash?",
                             options: [RequestOption(id: "allow", label: "Allow"), RequestOption(id: "deny", label: "Deny"),
                                       RequestOption(id: "always", label: "Always allow", detail: "Bash(ls:*) · this session only")])
        XCTAssertEqual(store.submit(sessionId: "s", request: r, waiter: nil), .accepted)
        XCTAssertEqual(store.sessions[0].pendingRequests[0].options[2].detail, "Bash(ls:*) · this session only")   // detail survives
        store.respond(AgentResponse(requestId: "r1", optionId: "deny", text: "no\nrm\u{1B}[31m -rf"), sessionId: "s")
        let last = store.sessions[0].history.last!
        XCTAssertEqual(last.text, "answered: Deny: no rm [31m -rf")
        XCTAssertFalse(last.text.contains("\n"))
    }
}
