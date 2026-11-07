import Foundation

/// One onboarding/setup step. Raw values are stable (persisted in `onboarding.skippedSteps`).
public enum SetupStep: String, CaseIterable, Codable, Sendable {
    case agentUser, hostBinary, cli, claudeCLI, claudeToken, claudeHooks, codexHooks, autostart, notifications

    /// Steps that are carried out by the single privileged (admin) block.
    public var isAdminStep: Bool { self == .agentUser || self == .hostBinary || self == .cli }

    /// Nice-to-have steps: they never end `failed` and never block "Continue" (a denied or unavailable permission is just "off").
    public var isOptional: Bool { self == .notifications }
}

public enum StepStatus: Equatable, Sendable {
    case done
    case missing
    case notApplicable(String)
    case failed(String)
    case running

    /// The token probe could not ask the host (not "no token"): the file may well be there.
    public var isTokenStateUnknown: Bool {
        if case .failed(let m) = self { return m.hasPrefix("token state unknown") }
        return false
    }

    /// True when the step still needs work (missing or failed). `running` and `notApplicable` are not open.
    public var isOpen: Bool {
        switch self {
        case .missing, .failed: return true
        case .done, .notApplicable, .running: return false
        }
    }
}

/// Read-only state check. Must not change anything and must be cheap enough to run repeatedly.
public protocol SetupProbe: Sendable {
    var step: SetupStep { get }
    func check() async -> StepStatus
}

/// Unprivileged action for one step (hooks, claude CLI, autostart, ...). Idempotent callers run `check()` first.
public protocol SetupAction: Sendable {
    var step: SetupStep { get }
    func run(progress: @Sendable (String) -> Void) async throws
}

/// The one privileged block: performs the given admin steps (a subset of agentUser, hostBinary, cli and, when its
/// token was acquired before, claudeToken) with a single admin prompt. Implemented by the app (osascript + script).
public protocol SetupAdminBlock: Sendable {
    func run(steps: [SetupStep], progress: @Sendable (String) -> Void) async throws
}

/// Phase 1 of the token step: obtain the Claude OAuth token BEFORE the admin block (it needs the owner's `claude`
/// login and a browser, so it must not happen inside a privileged script). The implementation stages the token in a
/// private (0600) location; phase 2 (`install`) happens inside the admin block, which moves it into the agent home.
/// The runner and this model never see the token's content.
public protocol SetupTokenAcquirer: Sendable {
    func acquire(progress: @Sendable (String) -> Void) async throws
}

public struct SetupOptions: Equatable, Sendable {
    /// false = local mode: agent runs as the owner, no agent user / host binary / token needed.
    public var useAgentUser: Bool
    /// Steps the user chose to skip; they never appear in the plan.
    public var skippedSteps: Set<SetupStep>
    public init(useAgentUser: Bool = true, skippedSteps: Set<SetupStep> = []) {
        self.useAgentUser = useAgentUser; self.skippedSteps = skippedSteps
    }
}

public enum SetupPhase: String, Equatable, Sendable {
    case run       // unprivileged action
    case acquire   // token phase 1, before the admin block
    case admin     // part of the single admin block (token phase 2 included)
}

public struct SetupPlanItem: Equatable, Sendable {
    public let step: SetupStep
    public let phase: SetupPhase
    public init(step: SetupStep, phase: SetupPhase) { self.step = step; self.phase = phase }
}

public struct SetupState: Equatable, Sendable {
    /// Statuses with the options applied (local mode turns agent-only steps into `notApplicable`).
    public let statuses: [SetupStep: StepStatus]
    public let options: SetupOptions
    /// Open work in fixed order: claudeCLI, claudeToken(acquire), [agentUser, hostBinary, cli, claudeToken(install)]
    /// as ONE admin block, claudeHooks, codexHooks, autostart, notifications.
    public let plan: [SetupPlanItem]

    public init(statuses: [SetupStep: StepStatus], options: SetupOptions = SetupOptions()) {
        let eff = Self.effectiveStatuses(statuses, options: options)
        self.statuses = eff
        self.options = options
        self.plan = Self.plan(from: eff, options: options)
    }

    public func status(of step: SetupStep) -> StepStatus { statuses[step] ?? .missing }
    public var isComplete: Bool { SetupStep.allCases.allSatisfy { !status(of: $0).isOpen } }
    public var hasAdminWork: Bool { plan.contains { $0.phase == .admin } }

    /// Steps only meaningful with an agent user.
    static let agentOnly: [SetupStep] = [.agentUser, .hostBinary, .claudeToken]

    public static func effectiveStatuses(_ s: [SetupStep: StepStatus], options: SetupOptions) -> [SetupStep: StepStatus] {
        var out = s
        for step in SetupStep.allCases where out[step] == nil { out[step] = .missing }
        if !options.useAgentUser {
            for step in agentOnly { out[step] = .notApplicable("local mode") }
        }
        return out
    }

    /// Pure planner. Open = `missing` or `failed`. Skipped and not-applicable steps are left out.
    public static func plan(from statuses: [SetupStep: StepStatus], options: SetupOptions) -> [SetupPlanItem] {
        let st = effectiveStatuses(statuses, options: options)
        func open(_ s: SetupStep) -> Bool { st[s]?.isOpen == true && !options.skippedSteps.contains(s) }
        var items: [SetupPlanItem] = []
        if open(.claudeCLI) { items.append(.init(step: .claudeCLI, phase: .run)) }
        // Token: acquired before the admin prompt, installed inside the admin block (after agentUser).
        if open(.claudeToken) { items.append(.init(step: .claudeToken, phase: .acquire)) }
        for s in [SetupStep.agentUser, .hostBinary, .cli] where open(s) { items.append(.init(step: s, phase: .admin)) }
        if open(.claudeToken) { items.append(.init(step: .claudeToken, phase: .admin)) }
        for s in [SetupStep.claudeHooks, .codexHooks, .autostart, .notifications] where open(s) {
            items.append(.init(step: s, phase: .run))
        }
        return items
    }

    /// Steps that must be `done` before a step can succeed.
    public static func dependencies(of step: SetupStep) -> [SetupStep] {
        step == .claudeToken ? [.agentUser, .claudeCLI] : []
    }
}

public enum SetupEvent: Equatable, Sendable {
    case started(SetupStep)
    case message(SetupStep, String)
    case finished(SetupStep, StepStatus)
}

/// Interface the UI talks to. `SetupRunner` is the real implementation, `FakeSetupRunner` serves previews.
public protocol SetupRunning: Sendable {
    func state() async -> SetupState
    func refresh() async -> SetupState
    func runAll(progress: @escaping @Sendable (SetupEvent) -> Void) async -> SetupState
    func run(step: SetupStep, progress: @escaping @Sendable (SetupEvent) -> Void) async -> SetupState
}
