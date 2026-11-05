import XCTest
@testable import AgentBarCore

final class OnboardingTriggerTests: XCTestCase {
    private func state(_ over: [SetupStep: StepStatus] = [:], local: Bool = false, skipped: Set<SetupStep> = []) -> SetupState {
        var s = Dictionary(uniqueKeysWithValues: SetupStep.allCases.map { ($0, StepStatus.done) })
        for (k, v) in over { s[k] = v }
        return SetupState(statuses: s, options: SetupOptions(useAgentUser: !local, skippedSteps: skipped))
    }

    func testVersionCompare() {
        XCTAssertEqual(OnboardingTrigger.compareVersions("0.9", "0.10"), .orderedAscending)
        XCTAssertEqual(OnboardingTrigger.compareVersions("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(OnboardingTrigger.compareVersions("2.0.1", "2.0"), .orderedDescending)
    }

    func testNeverCompletedShows() {
        XCTAssertTrue(OnboardingTrigger.shouldShow(completedVersion: nil, currentVersion: "0.1", state: state()))
    }

    func testCompletedCurrentDoesNotShowEvenIfMissing() {
        XCTAssertFalse(OnboardingTrigger.shouldShow(completedVersion: "0.1", currentVersion: "0.1", state: state([.cli: .missing])))
    }

    func testOlderVersionShowsOnlyForRequiredStep() {
        XCTAssertTrue(OnboardingTrigger.shouldShow(completedVersion: "0.1", currentVersion: "0.2", state: state([.claudeHooks: .missing])))
        XCTAssertFalse(OnboardingTrigger.shouldShow(completedVersion: "0.1", currentVersion: "0.2", state: state([.autostart: .missing, .codexHooks: .missing])))
        XCTAssertFalse(OnboardingTrigger.shouldShow(completedVersion: "0.1", currentVersion: "0.2", state: state()))
    }

    func testSkippedAndLocalModeAreNotMissing() {
        XCTAssertFalse(OnboardingTrigger.shouldShow(completedVersion: "0.1", currentVersion: "0.2",
                                                    state: state([.claudeToken: .missing], skipped: [.claudeToken])))
        XCTAssertFalse(OnboardingTrigger.shouldShow(completedVersion: "0.1", currentVersion: "0.2",
                                                    state: state([.agentUser: .missing, .hostBinary: .missing], local: true)))
    }

    func testForceAndSnooze() {
        let now = Date()
        XCTAssertTrue(OnboardingTrigger.shouldShow(completedVersion: "0.2", currentVersion: "0.2", state: state(), force: true))
        XCTAssertFalse(OnboardingTrigger.shouldShow(completedVersion: nil, currentVersion: "0.2", state: state(),
                                                    snoozedUntil: now.addingTimeInterval(60), now: now))
        XCTAssertTrue(OnboardingTrigger.shouldShow(completedVersion: nil, currentVersion: "0.2", state: state(),
                                                   snoozedUntil: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(OnboardingTrigger.shouldShow(completedVersion: nil, currentVersion: "0.2", state: state(),
                                                   force: true, snoozedUntil: now.addingTimeInterval(60), now: now))
    }
}
