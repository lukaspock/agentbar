import Foundation

/// Pure decision "show the onboarding window at app start?". No side effects.
public enum OnboardingTrigger {
    /// Steps whose absence justifies re-showing the onboarding after an update. Hooks for Codex, autostart and
    /// notifications are optional and never re-trigger it.
    public static let requiredSteps: [SetupStep] = [.claudeCLI, .agentUser, .hostBinary, .cli, .claudeToken, .claudeHooks]

    /// Numeric dotted comparison ("0.10" > "0.9"); missing components count as 0, non-numeric parts as 0.
    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) {
            let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func missingRequiredSteps(in state: SetupState) -> [SetupStep] {
        requiredSteps.filter { state.status(of: $0).isOpen && !state.options.skippedSteps.contains($0) }
    }

    /// - force: `--onboarding-force`, ignores completion and snooze.
    /// - snoozedUntil: set by "Later"; suppresses the automatic start until then.
    public static func shouldShow(completedVersion: String?, currentVersion: String, state: SetupState,
                                  force: Bool = false, snoozedUntil: Date? = nil, now: Date = Date()) -> Bool {
        if force { return true }
        if let snoozedUntil, snoozedUntil > now { return false }
        guard let completedVersion else { return true }
        guard compareVersions(completedVersion, currentVersion) == .orderedAscending else { return false }
        return !missingRequiredSteps(in: state).isEmpty
    }
}
